-- tc_flow: starting a co-op session's mode on both machines, through the game's own menu functions so the
-- normal game flow (save, loading screen, setup) runs exactly as in single player.
local U = require("tc_util")
local N = require("tc_net")

local F = {}

F.MODE_LABEL = { training = "TRAINING ROOM", arena = "ARENA", story = "STORY" }

local function titleMenu()
    -- FindAllOf can fail while a map is loading; treat that as "not there yet".
    local ok, all = pcall(FindAllOf, "BP_Menu_Startup_C")
    for _, m in ipairs(ok and all or {}) do
        local live = pcall(function() return U.valid(m) and U.valid(m.MenuBox) and m.MenuBox:GetChildrenCount() > 0 end)
        if live and U.valid(m) and U.valid(m.MenuBox) and m.MenuBox:GetChildrenCount() > 0 then return m end
    end
    return nil
end

local ARENA_CLICK = "BndEvt__BP_Menu_Startup_BtnArena_K2Node_ComponentBoundEvent_3_ButtonUserWidgetClickDelegate__DelegateSignature"
local FREE_TRAINING_CLICK =
    "BndEvt__BP_Menu_TrainingModeSelection_Btn_FreeTraining_K2Node_ComponentBoundEvent_2_ButtonUserWidgetClickDelegate__DelegateSignature"

-- The Training Room is entered like a player does it: ARENAS (loads the Arena title scene), TRAINING ROOM from
-- that scene's menu, then FREE TRAINING on the Training Mode screen. Each step calls the game's own handler.
-- Arena challenges start from the same scene: ARENAS, then the challenge list (picking a challenge: tc_arena).
local pending = nil  -- { mode, step, since }

local function enter(mode)
    if mode ~= "training" and mode ~= "arena" then
        U.log("flow: mode %s is not supported yet", mode)
        return false
    end
    pending = { mode = mode, step = "arena", since = os.time() }
    return true
end

-- Lab: the step the mode entry is at (nil when done).
function F.entering() return pending and pending.step or nil end

local function advance()
    if not pending then return end
    local menu = titleMenu()
    if os.time() - pending.since > 60 then
        U.log("flow: gave up entering %s at step %s", pending.mode, pending.step)
        pending = nil
        return
    end
    if pending.step == "free" then menu = menu or true end  -- the last step doesn't need the title menu
    if not menu then return end  -- loading
    if pending.step == "arena" and pending.mode == "arena" and menu:IsArenaChallengeMap() then
        -- Already in a challenge: ARENAS there opens the challenge list over the fight. Picking another challenge
        -- (tc_arena) works from here as well.
        U.log("flow: already in an Arena challenge (%s)", tostring(F.currentMap))
        pending = nil
        F.entered = "arena"
        return
    end
    if pending.step == "arena" then
        if menu:IsArenaMenuMap() then
            pending.settle = pending.settle or os.time() + 2
            pending.step = "training"
        else
            U.log("flow: step 1/2: ARENAS (title menu %s)", ARENA_CLICK)
            menu[ARENA_CLICK](menu, menu.BtnArena, false)
            pending.step = "wait_arena"
            pending.since = os.time()
            return
        end
    end
    if pending.step == "wait_arena" then
        if not menu:IsArenaMenuMap() then
            -- Without a finished story the game first asks "We advise that you complete the Story... continue?".
            -- Confirm it the way Enter does: the menu's own confirm action, which opens the Arena scene.
            local ok, popupOpen = pcall(function() return menu.ConfirmationPopupOpened end)
            if ok and popupOpen and not pending.confirmed then
                U.log("flow: confirming the ARENAS warning (BPE_OnActionButtonPressed)")
                menu:BPE_OnActionButtonPressed()
                pending.confirmed = true
            end
            return
        end
        pending.step = "training"
        pending.settle = os.time() + 2  -- let the arena scene's menu finish appearing
        return
    end
    if pending.step == "training" and pending.mode == "arena" then
        if pending.settle and os.time() < pending.settle then return end
        U.log("flow: step 2/2: CHALLENGES (OpenArenaSelection)")
        menu:OpenArenaSelection()
        pending = nil
        F.entered = "arena"
        U.log("flow: in the Arena scene, challenge list open")
        return
    end
    if pending.step == "training" then
        if pending.settle and os.time() < pending.settle then return end
        U.log("flow: step 2/3: TRAINING ROOM (OpenTrainingRoom)")
        menu:OpenTrainingRoom()
        pending.step = "free"
        pending.since = os.time()
        return
    end
    if pending.step == "free" then
        -- The Training Mode screen (Free Training / Lessons): pick FREE TRAINING like the player would.
        -- (Sifu hosts menus in its own menu stack, so IsInViewport() is always false: use IsVisible. FindFirstOf
        -- can return the Blueprint's template, so pick the live instance.)
        -- The button widget is named "FreeTraining" (the handler's "Btn_FreeTraining" is an old name).
        local selection
        for _, m in ipairs(FindAllOf("BP_Menu_TrainingModeSelection_C") or {}) do
            local ok, live = pcall(function()
                return U.valid(m) and not m:GetFullName():find("Default__", 1, true) and U.valid(m.FreeTraining)
                    and m:IsVisible()
            end)
            if ok and live then selection = m end
        end
        if not selection then return end
        if not pending.seenSelection then
            pending.seenSelection = os.time() + 1  -- let its intro animation finish
            return
        end
        if os.time() < pending.seenSelection then return end
        U.log("flow: step 3/3: FREE TRAINING")
        selection[FREE_TRAINING_CLICK](selection, selection.FreeTraining, false)
        pending = nil
        F.activity = "training"
        U.log("flow: activity is now training")
    end
end

-- Lab test: enter a mode on this system only.
function F.enterLocal(mode) return enter(mode) end

-- Host: tell the partner, then go. The partner's "start" handler runs the same entry point.
function F.hostStart(mode)
    N.send(true, "start", mode)
    U.onGameThread("flow start", function() enter(mode) end)
end

-- Current map name ("ArenaMode_Menu", "Hideout_1_Main"...), updated by the world watcher below.
F.currentMap = nil
-- What the player is doing in it ("training" for Free Training, which runs inside the ArenaMode_Menu world).
-- nil in title scenes and menus: no partner character is shown there.
F.activity = nil
local mapListeners = {}
function F.onMapChange(fn) mapListeners[#mapListeners + 1] = fn end

function F.start()
    -- Map changes (UE4SS's LoadMap/InitGameState hooks don't fire in Sifu, so watch the world object).
    local lastKey
    U.poll("flow world watch", 500, function()
        advance()
        local world = U.world()
        if not U.valid(world) then return false end
        local key = world:GetFullName() .. "@" .. tostring(world:GetAddress())
        if key ~= lastKey then
            lastKey = key
            F.currentMap = world:GetFullName():match("([^%.]+)$")
            F.activity = nil
            if F.currentMap == "ArenaMode_Menu" then F.entered = nil end
            U.log("flow: world is now %s", F.currentMap)
            for _, fn in ipairs(mapListeners) do U.try("map listener", fn, F.currentMap) end
        end
        return false
    end)
    N.on("start", function(f)
        U.log("flow: host started %s", f[1])
        U.onGameThread("flow start", function() enter(f[1]) end)
    end)
end

return F
