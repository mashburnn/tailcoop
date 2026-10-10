-- tc_util: config from the command line, logging, safe calls, game-thread helpers.
local UEHelpers = require("UEHelpers")

local U = {}

U.config = {
    system = "0",       -- lab system number (1/2); "0" outside the lab
    role = "none",      -- none | host | join (dev auto-start; normal play uses the CO-OP menu)
    peer = "127.0.0.1",
    port = 7777,
    mode = "training",  -- training | arena | story
    test = "",          -- dev tests: g0, g1 ...
    userdir = nil,      -- UE -userdir (lab profile folder)
    turns = "shared",   -- enemies' attack turns: shared (across both players) | each (per player, Sifu's own)
}

local logFile = nil

local function commandLine()
    local ok, cmd = pcall(function()
        return UEHelpers.GetKismetSystemLibrary():GetCommandLine():ToString()
    end)
    if not ok then
        print(string.format("[TailCoop] GetCommandLine failed: %s\n", tostring(cmd)))
        return ""
    end
    return cmd
end

-- Folder of this mod (â€¦\ue4ss\Mods\TailCoop\), from this script's own path.
function U.modDir()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    return src:match("^(.*[\\/])Scripts[\\/]") or ""
end

-- Simple "key = value" ini reader (sections ignored).
local function readIni(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local t = {}
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and not line:match("^%s*[;#]") then t[k:lower()] = v end
    end
    f:close()
    return t
end

-- Settings come from TailCoop.ini (persistent) and launch.ini (written per launch by Lab\Run.ps1),
-- then from -TailCoop<Key>= command-line switches if the engine exposes them.
function U.loadConfig()
    local c = U.config
    local dir = U.modDir()
    for _, name in ipairs({ "TailCoop.ini", "launch.ini" }) do
        local t = readIni(dir .. name)
        if t then
            c.system = t.system or c.system
            c.role = (t.role or c.role):lower()
            c.peer = t.peer or c.peer
            c.port = tonumber(t.port or "") or c.port
            c.mode = (t.mode or c.mode):lower()
            c.test = (t.test or c.test):lower()
            c.userdir = t.userdir or c.userdir
            if t.trace then c.trace = t.trace ~= "0" end
            c.bind = t.bind or c.bind
            c.sim = t.sim or c.sim
            c.buffer = (t.buffer or c.buffer or "adaptive"):lower()  -- copies' playback lag: adaptive | fixed (100 ms)
            c.skew = tonumber(t.skew or "") or c.skew  -- lab: ms this game's clock runs ahead (as if on another PC)
            c.arenabatch, c.arenachallenge = t.arenabatch or c.arenabatch, t.arenachallenge or c.arenachallenge
            c.arenapicker = t.arenapicker or c.arenapicker  -- lab: who picks the challenge in arena tests (host | join)
            c.arenaseconds = t.arenaseconds or c.arenaseconds
            -- Enemies' attack turns: shared (one player's enemies attack at a time, as one fight) | each (per player)
            c.turns = (t.turns or c.turns):lower()
            if t.profile then c.profile = t.profile == "1" end
            c.hidetargets = t.hidetargets or c.hidetargets  -- lab: "0" leaves hidden characters targetable (compare)
            if t.autostart then c.autostart = t.autostart == "1" end
        end
    end
    local cmd = commandLine()
    local function arg(name)
        local quoted = cmd:match("%-" .. name .. "=\"([^\"]*)\"")
        if quoted then return quoted end
        return cmd:match("%-" .. name .. "=(%S+)")
    end
    c.system = arg("TailCoopSystem") or c.system
    c.role = (arg("TailCoopRole") or c.role):lower()
    c.peer = arg("TailCoopPeer") or c.peer
    c.port = tonumber(arg("TailCoopPort") or "") or c.port
    c.mode = (arg("TailCoopMode") or c.mode):lower()
    c.test = (arg("TailCoopTest") or c.test):lower()
    c.userdir = arg("userdir") or c.userdir
    c.commandLineLength = #cmd
    U.profiling = c.system ~= "0" or c.profile == true
    local path = c.userdir and (c.userdir .. "\\TailCoop.log") or (dir .. "TailCoop.log")
    -- A player's install keeps its log across sessions: over 2 MB it becomes TailCoop.log.old.
    local existing = io.open(path, "r")
    if existing then
        local size = existing:seek("end")
        existing:close()
        if size and size > 2 * 1024 * 1024 then
            os.remove(path .. ".old")
            os.rename(path, path .. ".old")
        end
    end
    logFile = io.open(path, "a")
    return c
end

function U.log(fmt, ...)
    local msg = tostring(fmt)
    if select("#", ...) > 0 then
        -- A bad format (e.g. %d given 12.5) must not abort the code that logs: log the raw values instead.
        local ok, formatted = pcall(string.format, fmt, ...)
        if ok then
            msg = formatted
        else
            local parts = { msg, "[log format error]" }
            for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            msg = table.concat(parts, " ")
        end
    end
    local line = string.format("[TailCoop:%s] %s", U.config.system, msg)
    print(line .. "\n")
    if logFile then
        logFile:write(os.date("%H:%M:%S "), line, "\n")
        logFile:flush()
    end
end

-- Runs fn with error logging instead of letting a Lua error escape into a hook.
function U.try(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        U.log("ERROR in %s: %s", label, tostring(err))
    end
    return ok, err
end

function U.onGameThread(label, fn)
    ExecuteInGameThread(function() U.try(label, fn) end)
end

-- Game-thread work stays off until startup asset loading has settled: touching objects during the
-- first frames can trip Sifu's "object still needing load" fatal error.
U.STARTUP_GRACE_S = 15
local startedAt = os.time()

local function startupSettled()
    return os.time() - startedAt >= U.STARTUP_GRACE_S
end

-- Polls every intervalMs ON THE GAME THREAD until fn returns true.
-- Uses UE4SS's game-thread delayed actions (LoopInGameThreadWithDelay). Not LoopAsync: it runs Lua on a second
-- OS thread in the same Lua state, unsynchronized with hooks on the game thread (UE4SS issue #1445). In our lab that
-- race silently stopped every TailCoop loop on one system after ~70 s.
-- Per-loop cost on the game thread (lab profiling): label -> { us, calls, max }; reported by U.profileReport.
U.profile = {}

-- Times a section inside a loop: local t = U.tick(); ...; U.tock("label", t). Shown as "  label" in the report.
-- Lab systems only (or "profile = 1" in TailCoop.ini): thousands of sections a second cost game time themselves.
U.profiling = true  -- set by U.loadConfig
local sections = {}  -- label -> counters (also in U.profile under "  label")
function U.tick() return U.profiling and TailCoop_ClockUs and TailCoop_ClockUs() or 0 end
function U.tock(label, t0)
    if not (U.profiling and TailCoop_ClockUs) then return end
    local dt = TailCoop_ClockUs() - t0
    local p = sections[label]
    if not p then
        p = { us = 0, calls = 0, max = 0 }
        sections[label] = p
        U.profile["  " .. label] = p
    end
    p.us, p.calls = p.us + dt, p.calls + 1
    if dt > p.max then p.max = dt end
end

function U.poll(label, intervalMs, fn)
    local handle
    local p = { us = 0, calls = 0, max = 0 }
    U.profile[label] = p
    handle = LoopInGameThreadWithDelay(intervalMs, function()
        if not startupSettled() then return end
        local t0 = TailCoop_ClockUs and TailCoop_ClockUs() or 0
        local ok, result = pcall(fn)
        if TailCoop_ClockUs then
            local dt = TailCoop_ClockUs() - t0
            p.us, p.calls = p.us + dt, p.calls + 1
            if dt > p.max then p.max = dt end
        end
        if not ok then
            U.log("ERROR in %s: %s", label, tostring(result))
        elseif result == true then
            CancelDelayedAction(handle)
        end
    end)
    return handle
end

-- One log line: game-thread milliseconds per second each loop used since the last report (and its worst single
-- call), most expensive first; resets the counters.
function U.profileReport(seconds)
    local rows, total = {}, 0
    for label, p in pairs(U.profile) do
        if p.calls > 0 then
            rows[#rows + 1] = { label = label, ms = p.us / 1000 / seconds, max = p.max / 1000, calls = p.calls }
            if label:sub(1, 2) ~= "  " then total = total + p.us / 1000 / seconds end  -- sections are inside loops
        end
        p.us, p.calls, p.max = 0, 0, 0
    end
    table.sort(rows, function(a, b) return a.ms > b.ms end)
    local parts, hitches = {}, {}
    for i, r in ipairs(rows) do
        local text = string.format("%s %.2f (max %.1f, %d/s)", r.label, r.ms, r.max, math.floor(r.calls / seconds))
        if i <= 30 then
            parts[#parts + 1] = text
        elseif r.max >= 10 then
            hitches[#hitches + 1] = text  -- rare but long (a frame hitch): listed whatever its average
        end
    end
    U.log("profile: %.2f ms/s total | %s%s", total, table.concat(parts, " | "),
        #hitches > 0 and (" || hitches: " .. table.concat(hitches, " | ")) or "")
end

-- Loads native\TailCoopNative.dll, which registers the TailCoop_* Lua functions (network transport, Tailscale)
-- and checks that UE4SS found Sifu's real ProcessEvent (needs VTableLayout.ini). Returns true when both are fine.
function U.loadNative()
    local dir = U.modDir():gsub("/", "\\")
    local dll = dir .. "native\\TailCoopNative.dll"
    if not (package and package.loadlib) then
        U.log("native: package.loadlib is not available in this Lua")
        return false
    end
    local open, err = package.loadlib(dll, "luaopen_tailcoopnative")
    if not open then
        U.log("native: could not load %s: %s", dll, tostring(err))
        return false
    end
    open()
    -- Lab: two games on one PC share one clock, two PCs never do. A skew makes this game's clock differ, so whatever
    -- compares the two clocks is tested like on two PCs. Every clock the mod uses or sends goes through here.
    local skew = U.config.skew
    if skew and skew ~= 0 and TailCoop_Clock then
        local real = TailCoop_Clock
        TailCoop_Clock = function() return real() + skew end
        U.log("lab: this game's clock runs %d ms ahead of the PC's (as if on another PC)", skew)
    end
    if TailCoop_Live then
        -- Self-check of the object liveness test: a live object yes, a made-up address no. Without both, fall back to
        -- UE4SS's IsValid.
        local okA, liveYes = pcall(function()
            local cdo = StaticFindObject("/Script/Engine.Default__Actor")
            return cdo and TailCoop_Live(tostring(cdo:GetAddress()))
        end)
        local liveNo = TailCoop_Live("268439552")  -- 0x10001000
        U.log("native: object array %d slots, liveness check %s (live %s, made-up %s)", TailCoop_ObjectCount(),
            (okA and liveYes and not liveNo) and "ok" or "WRONG (UE4SS IsValid used instead)", tostring(liveYes),
            tostring(liveNo))
        if not (okA and liveYes and not liveNo) then TailCoop_Live = nil end
    end
    local diag = TailCoop_Diagnostics and TailCoop_Diagnostics() or "no diagnostics"
    U.log("native: %s", diag)
    return diag:find("processevent=ok", 1, true) ~= nil
end

-- Version of the TailCoop scripts (both players must run identical ones): FNV-1a over every script file. (Not the
-- development-only tc_trace / tc_devtests, which the released mod doesn't include.)
local SCRIPT_FILES = { "main", "tc_util", "tc_net", "tc_session", "tc_flow", "tc_anim", "tc_presence", "tc_moves",
    "tc_enemies", "tc_hits", "tc_pose", "tc_gear", "tc_aggro", "tc_training", "tc_menu", "tc_timeline", "tc_arena",
    "tc_turns" }

function U.modVersion()
    if U._modVersion then return U._modVersion end
    local hash = 2166136261
    for _, name in ipairs(SCRIPT_FILES) do
        local f = io.open(U.modDir() .. "Scripts/" .. name .. ".lua", "rb")
        if f then
            local data = f:read("a")
            f:close()
            for i = 1, #data do
                hash = ((hash ~ data:byte(i)) * 16777619) & 0xFFFFFFFF
            end
        end
    end
    U._modVersion = string.format("tc-%08x", hash)
    return U._modVersion
end

-- Display name sent to the partner: the lab system number, else the Windows computer name.
function U.playerName()
    if U.config.system ~= "0" then return "System " .. U.config.system end
    return os.getenv("COMPUTERNAME") or "player"
end

-- A game object we may call: still alive. Native check when available (TailCoop_Live): UE4SS's own IsValid reads
-- the object's memory and crashes on one the engine has already destroyed and freed (Lua keeps references across
-- frames: caches, watchers, copies).
function U.valid(obj)
    if obj == nil or obj.IsValid == nil then return false end
    if TailCoop_Live then
        local ok, addr = pcall(obj.GetAddress, obj)
        return ok and addr ~= nil and addr ~= 0 and TailCoop_Live(tostring(addr))
    end
    return obj:IsValid()
end

-- The local player's controller: the PlayerController whose Player (ULocalPlayer) is set.
-- Not UEHelpers.GetPlayerController(): it calls Controller.IsPlayerController, which in Sifu's Arena scene is a
-- number variable on a Blueprint controller ("attempt to call a number value").
local pcCache, pcCheckedAt = nil, 0
function U.playerController()
    if pcCache then
        -- Called many times per frame: the full check (it still has a local player) once a second.
        local now = TailCoop_Clock and TailCoop_Clock() or 0
        local ok, good = pcall(function()
            if now - pcCheckedAt < 1000 then return U.valid(pcCache) end
            return U.valid(pcCache) and U.valid(pcCache.Player)
        end)
        if ok and good then
            if now - pcCheckedAt >= 1000 then pcCheckedAt = now end
            return pcCache
        end
        pcCache = nil
    end
    local ok, list = pcall(FindAllOf, "PlayerController")
    for _, pc in ipairs(ok and list or {}) do
        local okPc, good = pcall(function()
            return U.valid(pc) and not pc:GetFullName():find("Default__", 1, true) and U.valid(pc.Player)
        end)
        if okPc and good then
            pcCache = pc
            return pc
        end
    end
    return nil
end

-- The current world, looked up again every 250 ms (several loops ask every frame; a world change is noticed
-- that much later at most, and a world that went away is never returned).
local worldCache, worldAt = nil, -1e9
function U.world()
    local now = TailCoop_Clock and TailCoop_Clock() or 0
    if worldCache and now - worldAt < 250 then
        local ok, valid = pcall(function() return U.valid(worldCache) end)
        if ok and valid then return worldCache end
    end
    worldCache, worldAt = nil, now
    local pc = U.playerController()
    if pc then
        local ok, w = pcall(function() return pc:GetWorld() end)
        if ok and U.valid(w) then worldCache = w end
    end
    if not worldCache then
        local gi = UEHelpers.GetGameInstance()
        if U.valid(gi) then worldCache = gi:GetWorld() end
    end
    return worldCache
end

-- Short, readable name for logs: "BP_Btn_TitleBtn_C /Game/UI/..." -> "BP_Btn_TitleBtn_C:BtnStory".
function U.shortName(obj)
    if not U.valid(obj) then return "nil" end
    local ok, full = pcall(function() return obj:GetFullName() end)
    if not ok or not full then return "?" end
    local class, path = full:match("^(%S+)%s+(.*)$")
    local leaf = path and path:match("([^%.:]+)$") or full
    return (class or "?") .. ":" .. leaf
end

-- Converts a hook parameter to a short printable string.
function U.paramString(p)
    local ok, v = pcall(function() return p:get() end)
    if not ok then return "?" end
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
    if v == nil then return "nil" end
    local okName, name = pcall(function() return v:ToString() end)
    if okName and type(name) == "string" then return name end
    if U.valid(v) then return U.shortName(v) end
    return t
end

return U
