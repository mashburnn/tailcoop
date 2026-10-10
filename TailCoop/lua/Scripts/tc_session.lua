-- tc_session: the co-op session (who hosts, who's connected, what mode) on top of tc_net.
-- Network messages are pumped every 10 ms on UE4SS's async thread; handlers that touch game objects must hop
-- to the game thread themselves (U.onGameThread).
local U = require("tc_util")
local N = require("tc_net")

local S = {}

S.mode = nil        -- training | arena | story (chosen by the host)
S.role = "none"     -- none | host | join
local listeners = {}

local function notify()
    S.refreshConnected()  -- listeners see the new state
    for _, fn in ipairs(listeners) do U.try("session listener", fn) end
end

-- fn() is called whenever the session state changes (connect, disconnect, rejection...).
function S.onChange(fn) listeners[#listeners + 1] = fn end

-- Host address: 127.0.0.1 in the lab when the partner is on this PC, otherwise this PC's Tailscale address,
-- so the game is only reachable through the tailnet. (Outside the lab peer is 127.0.0.1 by default too, which must
-- not keep a normal install from being reachable.)
function S.bindAddress()
    if U.config.bind and U.config.bind ~= "" then return U.config.bind end
    return (U.config.system ~= "0" and U.config.peer == "127.0.0.1") and "127.0.0.1" or "tailscale"
end

function S.host(mode)
    S.role, S.mode = "host", mode
    local ok, err = N.host(U.config.port, S.bindAddress())
    notify()
    return ok, err
end

function S.join(address)
    S.role = "join"
    local ok, err = N.join(address, U.config.port)
    notify()
    return ok, err
end

function S.leave()
    N.leave()
    S.role, S.mode = "none", nil
    notify()
end

function S.status() return N.status() end
-- Asked by nearly every loop, many times a frame: the session state is fetched (native call, lock, strings) at most
-- every 100 ms; connect / disconnect events (net pump) refresh it at once.
local connectedCache, connectedAt = false, -1e9
function S.connected()
    local now = TailCoop_Clock and TailCoop_Clock() or 0
    if now - connectedAt >= 100 then
        connectedCache, connectedAt = N.status().state == "connected", now
    end
    return connectedCache
end
function S.refreshConnected() connectedAt = -1e9 end

function S.start()
    -- Lab-only network impairment ("loss%,delayMs,jitterMs" from launch.ini).
    if U.config.sim and U.config.sim ~= "" and TailCoop_Simulate then
        local loss, delay, jitter = U.config.sim:match("^([%d%.]+),(%d+),(%d+)$")
        if loss then
            TailCoop_Simulate(loss, delay, jitter)
            U.log("session: simulating %s%% loss, %s ms delay, %s ms jitter on outgoing packets", loss, delay, jitter)
        end
    end
    N.onSystem("*", function(detail, event)
        U.log("session: %s %s", event, detail)
        notify()
    end)
    -- The host tells the joiner which mode it picked as soon as they connect.
    N.onSystem("connected", function(peer)
        U.log("session: connected to %s", peer)
        if S.role == "host" and S.mode then N.send(true, "mode", S.mode) end
        notify()
    end)
    N.on("mode", function(f)
        S.mode = f[1]
        U.log("session: host picked mode %s", S.mode)
        notify()
    end)
    -- Every frame, on the game thread (handlers may touch game objects directly).
    local prof = { us = 0, calls = 0, max = 0 }
    U.profile["net pump (handlers)"] = prof
    LoopInGameThreadAfterFrames(1, function()
        local t0 = TailCoop_ClockUs and TailCoop_ClockUs() or 0
        local ok, err = pcall(N.pump)
        if TailCoop_ClockUs then
            local dt = TailCoop_ClockUs() - t0
            prof.us, prof.calls = prof.us + dt, prof.calls + 1
            if dt > prof.max then prof.max = dt end
        end
        if not ok then U.log("ERROR in net pump: %s", tostring(err)) end
    end)
    -- Lab: where game-thread time and bandwidth go.
    if U.config.system ~= "0" then
        U.poll("profile report", 20000, function()
            U.profileReport(20)
            N.trafficReport(20)
            require("tc_timeline").report()
            return false
        end)
    end
end

return S
