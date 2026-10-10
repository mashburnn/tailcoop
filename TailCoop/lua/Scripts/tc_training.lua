-- tc_training: the Training Room's own controls work for both players.
-- Either player's Reset Situation (BP_TrainingManager:ResetTrainingRoom), Change enemy type (ChangeArchetypes) or
-- Change enemy behaviour (AIChangeBehaviour) runs in both games, so both spawn the same enemies in the same order and
-- their ids match (no stand-ins needed). Hooks see the local call; "train|..." carries it over; a call made on behalf
-- of the partner isn't sent back.
local U = require("tc_util")
local N = require("tc_net")
local S = require("tc_session")
local F = require("tc_flow")

local T = {}

local hooked, applyingRemote = false, false
local restopUntil = 0
local behaviourSendAt = nil

-- The room (re)starts its enemies' AI when it resets / spawns / switches behaviour, sometimes a little later (spawns):
-- on the joiner, keep stopping it for 2 s after any room action (the host's enemies decide).
local function holdJoinerAI()
    if S.role == "join" then restopUntil = TailCoop_Clock() + 2000 end
end

local function manager()
    for _, m in ipairs(FindAllOf("BP_TrainingManager_C") or {}) do
        if U.valid(m) and not m:GetFullName():find("Default__", 1, true) then return m end
    end
    return nil
end

-- The room's "passive" enemy behaviour (BP_TrainingManager.IsAIPassive; its SetAIBehaviour turns the enemies' attack
-- tickets, reactions and defense off). TailCoop must leave such enemies passive: its turn-taking gate re-enabled
-- their tickets every 2 s and its "nobody is coming, send one at the player" fix sent them at us - passive dummies
-- attacked (user, 2026-10-10: "it says enemy is passive while being aggressive").
local passiveCache = { at = -1e9, value = false, tm = nil }
function T.passive()
    if F.activity ~= "training" then return false end
    local now = TailCoop_Clock()
    if now - passiveCache.at >= 250 then
        passiveCache.at = now
        if not U.valid(passiveCache.tm) then passiveCache.tm = manager() end
        local ok, p = pcall(function() return passiveCache.tm.IsAIPassive end)
        passiveCache.value = ok and p == true
    end
    return passiveCache.value
end

local function send(...)
    if applyingRemote or not S.connected() then return end
    N.send(true, "train", ...)
end

local function hook()
    local tm = manager()
    if not tm then return false end
    local cls = tm:GetClass():GetFullName():match("%s(.+)$")
    local hooks = {
        ResetTrainingRoom = function() send("reset") end,
        AIChangeBehaviour = function()
            -- The hook runs after the switch (it read the new state as the old one): send the state the room ends
            -- up in, a moment later, from the game-thread loop below.
            if not applyingRemote then behaviourSendAt = TailCoop_Clock() + 150 end
        end,
        ChangeArchetypes = function(_, selected)
            local ok, s = pcall(function() return selected:get() end)
            if not ok then return end
            send("change", s.Archetype_19_47788A9644DD1B1E37918F9A65EA4E1B, s.Version_20_AADD7E0943207135D0DCBCB65DB234FD,
                s.Number_18_87140A9843C0BD65E3FEC68CF6B25DA9)
        end,
    }
    for name, fn in pairs(hooks) do
        local ok, err = pcall(RegisterHook, cls .. ":" .. name, function(...)
            local args = { ... }
            holdJoinerAI()
            U.try("training hook " .. name, function() fn(table.unpack(args)) end)
        end)
        if not ok then U.log("training: can't hook %s: %s", name, tostring(err)) end
    end
    U.log("training: room controls shared with the partner")
    return true
end

local function onTrain(f)
    local tm = manager()
    if not tm then
        U.log("training: partner used %s, but this game has no training room", tostring(f[1]))
        return
    end
    applyingRemote = true
    local ok, err = pcall(function()
        if f[1] == "reset" then
            tm:ResetTrainingRoom()
        elseif f[1] == "behaviour" then
            local wantPassive = f[2] == "passive"
            if tm.IsAIPassive ~= wantPassive then tm:AIChangeBehaviour() end
        elseif f[1] == "change" then
            tm:ChangeArchetypes({ Archetype_19_47788A9644DD1B1E37918F9A65EA4E1B = tonumber(f[2]) or 0,
                                  Version_20_AADD7E0943207135D0DCBCB65DB234FD = tonumber(f[3]) or 0,
                                  Number_18_87140A9843C0BD65E3FEC68CF6B25DA9 = tonumber(f[4]) or 1 })
        end
    end)
    applyingRemote = false
    U.log("training: partner's %s %s here (%s)", tostring(f[1]), table.concat(f, " ", 2), ok and "done" or tostring(err))
    holdJoinerAI()
end

function T.start()
    N.on("train", onTrain)
    U.poll("training hooks", 1000, function()
        if F.activity == "training" and not hooked then hooked = hook() end
        return false
    end)
    U.poll("training hold AI", 100, function()
        local now = TailCoop_Clock()
        if S.role == "join" and now < restopUntil then require("tc_enemies").restopAll() end
        if behaviourSendAt and now >= behaviourSendAt then
            behaviourSendAt = nil
            local m = manager()
            if m then send("behaviour", m.IsAIPassive and "passive" or "active") end
        end
        return false
    end)
end

return T
