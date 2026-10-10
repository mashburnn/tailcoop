-- tc_net: Lua side of the transport in TailCoopNative.dll (UDP over Tailscale, reliable + unreliable channels).
-- The native functions take strings and are thread-safe; this module adds defaults and message dispatch.
local U = require("tc_util")

local N = {}

N.RELIABLE = 1
N.UNRELIABLE = 0
N.SYSTEM = -1

local handlers = {}  -- message type -> function(fields, channel)
local systemHandlers = {}

function N.available()
    return TailCoop_Host ~= nil
end

local function unavailable()
    return false, "network module not installed"
end

-- Host on this PC. bind: "127.0.0.1" (lab, same PC), "tailscale" (normal: only reachable through the tailnet).
function N.host(port, bind)
    if not N.available() then return unavailable() end
    U.log("net: host on %s:%d", bind, port)
    return TailCoop_Host(tostring(port), bind, U.playerName(), U.modVersion())
end

function N.join(address, port)
    if not N.available() then return unavailable() end
    U.log("net: join %s:%d", address, port)
    return TailCoop_Join(address, tostring(port), U.playerName(), U.modVersion())
end

function N.leave()
    if N.available() then TailCoop_Leave() end
end

function N.status()
    if not N.available() then
        return { state = "unavailable", detail = "network module not installed", peer = "", rtt = -1 }
    end
    local state, detail, peer, rtt, sent, recv, resent, pending, localAddr = TailCoop_Status()
    return { state = state, detail = detail, peer = peer, rtt = rtt, sent = sent, recv = recv, resent = resent,
             pending = pending, localAddress = localAddr }
end

-- Lab: bytes sent per message type since the last report.
local traffic = {}
function N.trafficReport(seconds)
    local rows, total = {}, 0
    for t, b in pairs(traffic) do
        rows[#rows + 1] = { t = t, kb = b / 1024 / seconds }
        total = total + b
    end
    table.sort(rows, function(a, b) return a.kb > b.kb end)
    local parts = {}
    for i = 1, math.min(#rows, 8) do parts[#parts + 1] = string.format("%s %.1f", rows[i].t, rows[i].kb) end
    local poseBytes = 0
    if TailCoop_PoseStats then poseBytes = tonumber((TailCoop_PoseStats() or ""):match("%((%d+) bytes")) or 0 end
    U.log("traffic: text %.1f KB/s | %s | pose stream %.1f KB/s since start", total / 1024 / seconds,
        table.concat(parts, " | "), poseBytes / 1024 / math.max(1, (TailCoop_Clock() - (N.startedAt or TailCoop_Clock())) / 1000))
    traffic = {}
end

-- Messages are text: "<type>|<field>|<field>..." (fields must not contain "|").
function N.send(reliable, msgType, ...)
    if not N.available() then return unavailable() end
    local parts = { msgType }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local payload = table.concat(parts, "|")
    traffic[msgType] = (traffic[msgType] or 0) + #payload
    N.startedAt = N.startedAt or TailCoop_Clock()
    return TailCoop_Send(reliable and "1" or "0", payload)
end

-- Large text (e.g. a hit as Unreal text, ~5 KB) over the reliable channel: escaped and cut into pieces
-- "big|<type>|<seq>|<index>|<count>|<piece>", reassembled in order (the reliable channel is ordered).
local BIG_PIECE = 900
local bigSeq = 0
local function escape(s) return (s:gsub("%%", "%%25"):gsub("|", "%%7C"):gsub("\n", "%%0A")) end
local function unescape(s) return (s:gsub("%%0A", "\n"):gsub("%%7C", "|"):gsub("%%25", "%%")) end

function N.sendLarge(msgType, text)
    if not N.available() then return unavailable() end
    local e = escape(text)
    bigSeq = bigSeq + 1
    local count = math.max(1, math.ceil(#e / BIG_PIECE))
    for i = 1, count do
        -- Pieces are joined before unescaping, so a cut inside an escape sequence is harmless.
        local piece = e:sub((i - 1) * BIG_PIECE + 1, i * BIG_PIECE)
        local ok, err = N.send(true, "big", msgType, bigSeq, i, count, piece)
        if not ok then return false, err end
    end
    return true
end

local bigParts = {}  -- seq -> { type, count, pieces }
handlers["big"] = function(f)
    local msgType, seq, i, count = f[1], f[2], tonumber(f[3]), tonumber(f[4])
    local b = bigParts[seq]
    if not b then
        b = { pieces = {} }
        bigParts[seq] = b
    end
    b.pieces[i] = f[5] or ""
    if #b.pieces == count then
        bigParts[seq] = nil
        local h = handlers[msgType]
        if h then U.try("net " .. msgType, h, unescape(table.concat(b.pieces))) end
    end
end

function N.on(msgType, fn) handlers[msgType] = fn end
function N.onSystem(event, fn) systemHandlers[event] = fn end

-- Fields of "a|b|c" from position `from` on (no copy of the payload, no pattern matching: ~600 messages a second).
local find, sub = string.find, string.sub
local function fieldsFrom(payload, from)
    local fields, n, i = {}, 0, from
    if not i then return fields end
    while true do
        local j = find(payload, "|", i, true)
        n = n + 1
        if not j then
            fields[n] = sub(payload, i)
            return fields
        end
        fields[n] = sub(payload, i, j - 1)
        i = j + 1
    end
end
local function split(payload) return fieldsFrom(payload, 1) end

local labels = {}  -- message type -> "net <type>" (error label, built once)

-- Delivers every queued message to its handler. Returns the number handled.
function N.pump(limit)
    if not N.available() then return 0 end
    local n = 0
    while n < (limit or 1000) do
        local channel, payload = TailCoop_Poll()
        if channel == nil then break end
        n = n + 1
        local bar = find(payload, "|", 1, true)
        local name = bar and sub(payload, 1, bar - 1) or payload
        local fields = fieldsFrom(payload, bar and bar + 1)
        if channel == N.SYSTEM then
            U.log("net: %s %s", name, fields[1] or "")
            local h = systemHandlers[name] or systemHandlers["*"]
            if h then U.try("net system " .. name, h, fields[1] or "", name) end
        else
            local h = handlers[name]
            if h then
                local label = labels[name]
                if not label then
                    label = "net " .. name
                    labels[name] = label
                end
                U.try(label, h, fields, channel)
            end
        end
    end
    return n
end

-- Online Tailscale devices: { self = {name, ip}, peers = { {name, ip, online, os}, ... } }.
function N.tailnet()
    local result = { self = nil, peers = {} }
    if not (N.available() and TailCoop_Peers) then return result end
    for line in (TailCoop_Peers() or ""):gmatch("[^\n]+") do
        local f = split(line:gsub("\t", "|"))
        if f[1] == "self" then
            result.self = { name = f[2], ip = f[3] }
        elseif f[1] == "peer" then
            result.peers[#result.peers + 1] = { name = f[2], ip = f[3], online = f[4] == "1", os = f[5] }
        end
    end
    return result
end

return N
