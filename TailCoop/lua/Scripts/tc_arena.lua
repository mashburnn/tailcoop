-- tc_arena: co-op Arena challenges (G8). Both games play the same challenge; the host's game decides the enemies and
-- the result (enemy AI still runs in the game of the player it fights, as in training).
--
-- A challenge is picked by (batch, challenge) index (UArenaSettings.m_ArenaBatches) and entered the way Sifu's
-- challenge list does it (BP_Menu_ArenaSelection_C.TravelToArena): BPF_SetCurrentArena, then the game flow's tags
-- ("Arena" + the challenge's arena tag) and BPF_GoToNextMap, which loads Arena_<Name>_main. There the startup menu
-- waits on the challenge's title screen (sub-menu 3) until the player presses Start.
-- Sync: whoever picks a challenge, the other game travels to the same one ("arena|go|batch|challenge"); whoever
-- presses Start on the challenge's title screen, the other game presses it too ("arena|start", or as soon as its title
-- screen is up). From Start on, the activity is "arena": presence, enemies and aggro run as in the Training Room.
local U = require("tc_util")
local UEHelpers = require("UEHelpers")
local N = require("tc_net")
local S = require("tc_session")
local F = require("tc_flow")

local AR = {}

local helperObj
function AR.helper()
    if not (U.valid(helperObj)) then
        helperObj = StaticFindObject("/Script/Sifu.Default__ArenaManagerBlueprintHelper")
    end
    return U.valid(helperObj) and helperObj or nil
end

function AR.gameFlow()
    local ok, gf = pcall(function()
        local gi = UEHelpers.GetGameInstance()
        return gi:BPF_GetGameFlow()
    end)
    return ok and U.valid(gf) and gf or nil
end

-- The live instance of a class (FindFirstOf can return the Blueprint's template).
function AR.live(className)
    local ok, all = pcall(FindAllOf, className)
    for _, o in ipairs(ok and all or {}) do
        local isLive = pcall(function() return U.valid(o) and not o:GetFullName():find("Default__", 1, true) end)
        if isLive and U.valid(o) and not o:GetFullName():find("Default__", 1, true) then return o end
    end
    return nil
end

-- (batch, challenge, challenge asset name, arena tag) of the current challenge, or nil.
function AR.current()
    local h = AR.helper()
    if not h then return nil end
    local ok, b, c, name, tag = pcall(function()
        local ch = h:BPF_GetCurrentChallenge()
        return h:BPF_GetLastSelectedBatchIndex(), h:BPF_GetLastSelectedChallengeIndex(),
            U.valid(ch) and ch:GetClass():GetFName():ToString() or nil, h:BPF_GetCurrentArena().TagName:ToString()
    end)
    if not ok then return nil end
    return b, c, name, tag
end

-- Enter challenge (batch, challenge) like the challenge list does. Returns ok, error.
function AR.travel(batch, challenge)
    local h, gf = AR.helper(), AR.gameFlow()
    if not (h and gf) then return false, "arena helper or game flow not found" end
    return pcall(function()
        h:BPF_SetCurrentArena(batch, challenge)
        local tag = h:BPF_GetCurrentArena().TagName:ToString()
        local gm = AR.live("ArenaGameMode")
        if gm then gm:BPF_FlagArenaForRestart() end  -- already in a challenge: what TravelToArena does too
        gf:BPF_ResetTags()
        gf:BPF_RaiseTag({ TagName = FName("Arena") })
        gf:BPF_RaiseTag({ TagName = FName(tag) })
        U.log("arena: travelling to batch %d challenge %d (%s)", batch, challenge, tag)
        gf:BPF_GoToNextMap(false, false, true)
    end)
end

-- The challenge's title screen is up and waiting for Start: the startup menu on sub-menu 3 in a challenge map.
function AR.titleMenu()
    local ok, all = pcall(FindAllOf, "BP_Menu_Startup_C")
    for _, m in ipairs(ok and all or {}) do
        local okW, waiting = pcall(function()
            return U.valid(m) and not m:GetFullName():find("Default__", 1, true) and m.CurrentSubMenu == 3
                and not m.bStarted and not m.IsLeavingMap and m:IsArenaChallengeMap()
        end)
        if okW and waiting then return m end
    end
    return nil
end

-- Press Start on the challenge's title screen the way the confirm key does (BPE_OnActionButtonPressed: on sub-menu 3
-- of a challenge map it calls PressSimpleStart, then ArenaGameMode.BPF_PlayerPressStart).
function AR.pressStart()
    local m = AR.titleMenu()
    if not m then return false end
    m:BPE_OnActionButtonPressed()
    return true
end

-- The challenge's objective: class, score, stars, complete.
function AR.objective()
    local h = AR.helper()
    if not h then return nil end
    local ok, o = pcall(function() return h:BPF_GetCurrentMasterObjective() end)
    return ok and U.valid(o) and o or nil
end

-- Lab probe: hook every arena function we may need and log when it runs. Native functions are hooked at once;
-- Blueprint ones when their class has loaded (retried every second).
local PROBE_HOOKS = {
    "/Script/Sifu.ArenaManagerBlueprintHelper:BPF_SetCurrentArena",
    "/Script/Sifu.WGGameFlow:BPF_GoToNextMap",
    "/Script/Sifu.WGGameFlow:BPF_RaiseTag",
    "/Script/Sifu.WGGameFlow:BPF_RestartCurrentMap",
    "/Script/Sifu.WGGameFlow:BPF_GotoMap",
    "/Script/Sifu.ArenaGameMode:BPF_PlayerPressStart",
    "/Script/Sifu.ArenaGameMode:BPF_TriggerEndArena",
    "/Script/Sifu.ArenaGameMode:ShowArenaOutro",
    "/Script/Sifu.ArenaGameMode:BPF_FlagArenaForRestart",
    "/Script/Sifu.AIWaveRefillDirector:BPF_StartWave",
    "/Script/Sifu.AIWaveRefillDirector:BPF_StartNextWave",
    "/Script/Sifu.AIWaveRefillDirector:BPF_SetRefillEnabled",
    "/Script/Sifu.AIWaveRefillDirector:BPF_SetRefillDisabled",
    "/Script/Sifu.AIWaveRefillDirector:BPF_CancelCurrentWave",
    "/Script/Sifu.AIWaveRefillDirector:OnAIDownDetected",
    "/Script/Sifu.AIWaveRefillDirector:OnSituationAIDeathDetected",
    "/Script/Sifu.AchievementUnlockCondition:BPF_UnlockAchievement",
    "/Script/Sifu.AchievementUnlockCondition:BPF_ConditionFailed",
    "/Script/Sifu.AchievementUnlockCondition:BPF_IncrementCounter",
    "/Script/Sifu.ArenaWaveObjective:OnWaveAndSituationComplete",
    "/Script/Sifu.BaseArenaObjective:OnGiveInitialControlToPlayer",
    "/Script/Sifu.BaseArenaObjective:OnPlayerDownStateChanged",
    "/Script/Sifu.PlayerFightingComponent:BPF_SetIsGameover",
    "/Script/Sifu.DeathMenu:BPF_SetIsGameover",
    "/Script/Sifu.DeathMenu:BPF_IncrementAge",
    "/Script/Sifu.FightingCharacter:ServerSuicide",
    "/Game/UI/Blueprints/Menus/Gameflow/BP_Menu_Startup.BP_Menu_Startup_C:PressSimpleStart",
    "/Game/UI/Blueprints/Menus/Gameflow/BP_Menu_Startup.BP_Menu_Startup_C:Launch",
    "/Game/UI/Blueprints/Menus/Gameflow/BP_Menu_Startup.BP_Menu_Startup_C:LaunchArenaSetup",
    "/Game/UI/Blueprints/Menus/Gameflow/BP_Menu_Startup.BP_Menu_Startup_C:OpenArenaSelection",
    "/Game/UI/Blueprints/Menus/Arena/BP_Menu_ArenaSelection.BP_Menu_ArenaSelection_C:OnChallengeButtonPressed",
    "/Game/UI/Blueprints/Menus/Arena/BP_Menu_ArenaSelection.BP_Menu_ArenaSelection_C:StartTravel",
    "/Game/UI/Blueprints/Menus/Arena/BP_Menu_ArenaSelection.BP_Menu_ArenaSelection_C:TravelToArena",
    "/Game/UI/Blueprints/Menus/Arena/BP_Arena_Outro.BP_Arena_Outro_C:EvaluateChallengeEnd",
    "/Game/UI/Blueprints/Menus/Arena/BP_Arena_After_Outro.BP_Arena_After_Outro_C:RetryButtonPressed",
    "/Game/UI/Blueprints/Menus/Arena/BP_Arena_After_Outro.BP_Arena_After_Outro_C:ReturnToChallengeButtonPressed",
    "/Game/UI/Blueprints/Menus/Arena/BP_Arena_After_Outro.BP_Arena_After_Outro_C:ReturnToMainMenuButtonPressed",
}

function AR.probeHooks()
    local pending = {}
    for _, p in ipairs(PROBE_HOOKS) do pending[p] = true end
    U.poll("arena probe hooks", 1000, function()
        local left = 0
        for path in pairs(pending) do
            local fnName = path:match(":(.+)$")
            -- A missing Blueprint class costs a slow lookup: only try once its class is loaded.
            local class = path:match("^(.-):")
            local loaded = class:find("^/Script/") or StaticFindObject(class)
            if loaded then
                local ok, err = pcall(RegisterHook, path, function(ctx, ...)
                    local args = {}
                    for i, p in ipairs({ ... }) do
                        if i > 3 then break end
                        args[#args + 1] = U.paramString(p)
                    end
                    U.log("ARENAPROBE called %s on %s (%s)", fnName, U.shortName(ctx:get()), table.concat(args, ", "))
                end)
                U.log("ARENAPROBE hook %s: %s", fnName, ok and "ok" or tostring(err))
                pending[path] = nil
            else
                left = left + 1
            end
        end
        return left == 0
    end)
end

-- SYNC --------------------------------------------------------------------------------------------------------

local applying = false             -- running the partner's pick / Start: our hooks don't send it back
local picked = nil                 -- { batch, challenge, at } from the last BPF_SetCurrentArena seen here
local sentGo = nil                 -- { batch, challenge, at } of our last pick sent
local pendingGo, pendingStart = nil, false
local ready, partnerReady, started = false, nil, false
local applyCounter  -- joiner: the host's HUD waves counter shown here (WAVES below)
local applyEnd  -- (RESULT section)
local endSent, endApplied = false, false  -- host: told the partner its challenge ended / joiner: ended ours too

function AR.started() return started end

local function inChallengeMap() return F.currentMap ~= nil and F.currentMap:find("^Arena_.*_main$") ~= nil end

-- Where a pick can be travelled from: the Arena scene (after the session's mode entry) or a challenge.
local function canTravel()
    return not F.entering() and (F.currentMap == "ArenaMode_Menu" or inChallengeMap())
end

local function go(batch, challenge, why)
    applying = true
    local ok, err = AR.travel(batch, challenge)
    applying = false
    U.log("arena: %s -> batch %d challenge %d: %s", why, batch, challenge, ok and "travelling" or tostring(err))
end

local function press(why)
    applying = true
    local ok = AR.pressStart()
    applying = false
    U.log("arena: Start pressed here (%s, clock %d): %s", why, TailCoop_Clock(), ok and "ok" or "no title screen")
    return ok
end

local function onStarted()
    if started then return end
    started, ready, partnerReady, pendingStart = true, false, nil, false
    F.activity = "arena"
    local b, c, name = AR.current()
    U.log("flow: activity is now arena (%s, batch %s challenge %s)", tostring(name), tostring(b), tostring(c))
    if S.role == "join" then AR.offsetAt = TailCoop_Clock() + 4000 end  -- after the intro camera hands over control
end

-- Retry / back to the challenge list / Arena main menu, from the result screen or the pause menu: the partner goes too
-- ("arena|nav|retry|back|menu"). Retry = the same challenge travelled to again (what picking it does).
local navAt = -1e9
local pendingNav = nil  -- { what, tries, nextAt } carried out here until this game leaves the map (navTick)
local function nav(what)
    if applying or not S.connected() then return end
    navAt = TailCoop_Clock()
    N.send(true, "arena", "nav", what)
    U.log("arena: we chose %s, partner follows", what)
    -- Our own button normally does it; if this game is still here in 4 s (seen: Retry pressed while the result
    -- screen was settling did nothing), it's done the partner's way.
    pendingNav = { what = what, tries = 0, nextAt = navAt + 4000, own = true }
end

local function gameFlowLibrary()
    return StaticFindObject("/Game/UI/Blueprints/Menus/Gameflow/BP_GameFlow_Library.Default__BP_GameFlow_Library_C")
end

-- The partner's choice is carried out the way the result screen's own buttons do it (BP_GameFlow_Library RestartMap /
-- OpenArenaMenuMap), and again every 3 s until this game actually leaves the map: while its own result screen is
-- still coming up, the game flow ignores it.
local function applyNav(what)
    if TailCoop_Clock() - navAt < 3000 then
        U.log("arena: partner chose %s while we were leaving too: ours stands", what)
        return
    end
    pendingNav = { what = what, tries = 0, nextAt = 0 }
end

local function navTick(now)
    local p = pendingNav
    if not p or now < p.nextAt then return end
    if p.tries >= 10 then
        U.log("arena: partner chose %s, but this game didn't leave after %d tries", p.what, p.tries)
        pendingNav = nil
        return
    end
    p.tries, p.nextAt = p.tries + 1, now + 3000
    applying = true
    local ok, err = pcall(function()
        local lib, gf, pc = gameFlowLibrary(), AR.gameFlow(), U.playerController()
        if not (U.valid(lib) and gf and pc) then error("game flow not found") end
        if p.what == "retry" then
            lib:RestartMap(gf, pc)
        else
            -- OpenArenaMenuMap(SaveMapChange, GotoChallengeSelection, bShowArenaMenu, WandToReloadFirstSave, context)
            lib:OpenArenaMenuMap(false, p.what == "back", false, true, pc)
        end
    end)
    applying = false
    U.log("arena: %s -> done here (try %d): %s", p.own and ("our " .. p.what .. " didn't leave the map by itself")
        or ("partner chose " .. p.what), p.tries, ok and "ok" or tostring(err))
end

-- The result screen's and the pause menu's buttons are hooked from a live instance, by each function's own full name
-- (hooking them by the widget class path fails: "no UFunction with the specified name"). Looked for only when they
-- can be up: after a challenge ended / while the game is paused.
local NAV_HOOKS = {
    BP_Arena_After_Outro_C = { RetryButtonPressed = "retry", ReturnToChallengeButtonPressed = "back",
                               ReturnToMainMenuButtonPressed = "menu" },
    BP_Menu_Pause_Arena_C = { RestartMap = "retry", ChallengeSelection = "back", ReturnToMainMenu = "menu" },
}
local navHooked = {}

local function hookNav(className)
    if navHooked[className] then return end
    local inst = AR.live(className)
    if not inst then return end
    navHooked[className] = true
    for fnName, what in pairs(NAV_HOOKS[className]) do
        local ok, err = pcall(function()
            local path = inst[fnName]:GetFullName():match("^%S+%s+(.+)$")
            RegisterHook(path, function() U.try("arena nav hook", function() nav(what) end) end)
        end)
        U.log("arena: %s:%s %s", className, fnName, ok and "hooked" or ("NOT hooked: " .. tostring(err)))
    end
end

-- (The pause menu exists from the challenge's start: hooked as soon as it's there. Was: only "while paused" - when
-- none of the mod's loops run, so never.)
local function navHookTick()
    if not inChallengeMap() then return end
    if (endSent or endApplied) and not navHooked.BP_Arena_After_Outro_C then hookNav("BP_Arena_After_Outro_C") end
    if not navHooked.BP_Menu_Pause_Arena_C then hookNav("BP_Menu_Pause_Arena_C") end
end

-- Hooks on our own pick / Start (the challenge list and the title screen are Blueprints: hooked once loaded).
local HOOKS = {
    ["/Script/Sifu.ArenaManagerBlueprintHelper:BPF_SetCurrentArena"] = function(_, batch, challenge)
        local okB, b = pcall(function() return batch:get() end)
        local okC, c = pcall(function() return challenge:get() end)
        if okB and okC then picked = { batch = b, challenge = c, at = TailCoop_Clock() } end
    end,
    ["/Game/UI/Blueprints/Menus/Arena/BP_Menu_ArenaSelection.BP_Menu_ArenaSelection_C:TravelToArena"] = function()
        if applying or not picked or not S.connected() then return end
        -- Only the host's pick counts: the joiner follows it (and is taken to the host's challenge if it went its own
        -- way).
        if S.role ~= "host" then
            U.log("arena: we picked batch %d challenge %d, but the host picks: following the host's pick", picked.batch,
                picked.challenge)
            return
        end
        sentGo = { batch = picked.batch, challenge = picked.challenge, at = TailCoop_Clock() }
        N.send(true, "arena", "go", picked.batch, picked.challenge)
        U.log("arena: we picked batch %d challenge %d, partner follows", picked.batch, picked.challenge)
    end,
    ["/Game/UI/Blueprints/Menus/Gameflow/BP_Menu_Startup.BP_Menu_Startup_C:PressSimpleStart"] = function()
        if applying then return end
        if S.connected() then N.send(true, "arena", "start") end
        U.log("arena: we pressed Start (clock %d)", TailCoop_Clock())
        onStarted()
    end,
}

-- Hooked once the Blueprint is loaded, and retried every second until it takes: on a player's PC the challenge list's
-- class was already loaded at the title screen but its TravelToArena not found yet ("no UFunction with the specified
-- name") - hooked never, so the host's pick never reached the partner (user's two-PC session, 2026-10-10). A live
-- instance's own function (its full name) is tried as well, the way the result screen's buttons are hooked.
local function hookAll()
    local pending, failures = {}, {}
    for path, fn in pairs(HOOKS) do pending[path] = fn end
    U.poll("arena hooks", 1000, function()
        local left = 0
        for path, fn in pairs(pending) do
            local class, fnName = path:match("^(.-):(.+)$")
            local target = nil
            if class:find("^/Script/") or StaticFindObject(class) then target = path end
            if not target then
                -- (A live widget of the class: its function's own path.)
                local short = class:match("%.([%w_]+)$")
                local inst = short and AR.live(short)
                if inst then
                    pcall(function() target = inst[fnName]:GetFullName():match("^%S+%s+(.+)$") end)
                end
            end
            local ok, err = false, "not loaded yet"
            if target then
                ok, err = pcall(RegisterHook, target, function(...)
                    local args = { ... }
                    U.try("arena hook", function() fn(table.unpack(args)) end)
                end)
            end
            if ok then
                pending[path] = nil
                if failures[path] then U.log("arena: hooked %s (after %d tries)", fnName, failures[path]) end
            else
                left = left + 1
                if target then
                    failures[path] = (failures[path] or 0) + 1
                    if failures[path] == 1 then U.log("arena: can't hook %s yet (%s): trying again", fnName, tostring(err)) end
                end
            end
        end
        return left == 0
    end)
end

local function onArena(f)
    local what = f[1]
    if what == "go" then
        local b, c = tonumber(f[2]), tonumber(f[3])
        if not (b and c) then return end
        -- (The host picks: a joiner's pick - an older version - isn't followed.)
        if S.role == "host" then
            U.log("arena: the joiner picked batch %d challenge %d: ignored, the host picks", b, c)
            return
        end
        -- Both picked at once: the host's pick wins.
        if sentGo and TailCoop_Clock() - sentGo.at < 3000 and S.role == "host" then
            U.log("arena: partner picked batch %d challenge %d at the same time as us: ours stands", b, c)
            return
        end
        pendingGo = { batch = b, challenge = c }
        U.log("arena: partner picked batch %d challenge %d", b, c)
    elseif what == "ready" then
        partnerReady = { batch = tonumber(f[2]), challenge = tonumber(f[3]) }
        U.log("arena: partner is on the title screen (batch %s challenge %s)", tostring(f[2]), tostring(f[3]))
    elseif what == "start" then
        U.log("arena: partner pressed Start")
        if not started then pendingStart = true end
    elseif what == "end" then
        applyEnd(f)
    elseif what == "nav" then
        applyNav(f[2])
    elseif what == "out" then
        AR.onPartnerOut()
    elseif what == "counter" then
        applyCounter(f)
    end
end

-- RESULT --------------------------------------------------------------------------------------------------------
-- The host's game decides (its waves count every kill, whoever made it). When its objective is complete, the joiner's
-- objective - whose own waves don't run - is completed the same way, so its game plays its own result screen and
-- saves its own stars. An Age score stays each player's own (independent aging); other scores are shared.
local SCORING_AGE = 1  -- EScoringType: CombatPoints, Age, BestTime

local function objectiveState(o)
    local ok, s = pcall(function()
        local okT, t = pcall(function() return o.m_eScoringType end)
        return { complete = o.m_bIsArenaObjectiveComplete, score = o.m_iScore, stars = o.m_iStarCount,
                 scoring = okT and t or -1 }
    end)
    return ok and s or nil
end

local function hostResultTick()
    if endSent or not started or S.role ~= "host" or not S.connected() then return end
    local o = AR.objective()
    local s = o and objectiveState(o)
    if s and s.complete then
        endSent = true
        N.send(true, "arena", "end", "ok", s.score, s.stars, s.scoring)
        U.log("arena: challenge complete here (score %d, %d stars): partner's ends too", s.score, s.stars)
    end
end

function applyEnd(f)
    if endApplied then return end
    local o = AR.objective()
    if not o then
        U.log("arena: host's challenge ended (%s), but there's no objective here", tostring(f[2]))
        return
    end
    endApplied = true
    local result, score, scoring = f[2], tonumber(f[3]), tonumber(f[5])
    local ok, err = pcall(function()
        if score and scoring ~= SCORING_AGE then o.m_iScore = score end
        if result == "ok" then o:BPF_UnlockAchievement(true) else o:BPF_ConditionFailed() end
    end)
    local s = objectiveState(o) or {}
    U.log("arena: host's challenge %s -> ours %s (score %s, %s stars, complete %s)",
        result == "ok" and "complete" or "failed", ok and "ended the same way" or ("NOT ended: " .. tostring(err)),
        tostring(s.score), tostring(s.stars), tostring(s.complete))
end

-- OUT -----------------------------------------------------------------------------------------------------------
-- The challenge fails only when both players are out. Sifu ends a challenge itself when the player dies past the age
-- limit (UStatsComponent m_iMaxAge, 70), natively, at the death itself (clearing the game-over flag or raising
-- m_iMaxAge doesn't stop it). Each death ages the player by the new death count, so the next death's age is known: on
-- the last life, while the partner is still in, our character can't die by damage (HealthComponent
-- BPF_SetCanDieByDamage), and the blow that would have killed us puts us out instead: hidden, untouchable, no input,
-- camera on the partner's character; enemies leave us alone (tc_aggro) and the partner's game stops showing us
-- (tc_presence). Once the partner is out, we can die again and the last player's game over plays as in single player;
-- the partner's game fails with it ("arena|end|fail").
local STAT_DEATH_COUNTER = 12  -- ECharacterStat
local out = { me = false, partner = false }
local outApplyAt = nil
local lastLife = false  -- our character can't die by damage right now

local function myStats()
    local pc = U.playerController()
    local pawn = pc and pc.Pawn
    if not U.valid(pawn) then return nil end
    local ok, sc = pcall(function() return pawn:BPF_GetStatsComponent() end)
    return ok and U.valid(sc) and sc or nil
end

local function setCanDie(pawn, can)
    pcall(function() pawn.m_HealthComponent:BPF_SetCanDieByDamage(can) end)
end

function AR.isOut(role)
    if role == S.role then return out.me end
    return out.partner
end

local function myPawn()
    local pc = U.playerController()
    local pawn = pc and pc.Pawn
    return U.valid(pawn) and pawn or nil, pc
end

local function fail(why)
    local o = AR.objective()
    if not o or endApplied or endSent then return end
    endSent = true
    local s = objectiveState(o) or {}
    N.send(true, "arena", "end", "fail", s.score or -1, s.stars or 0, s.scoring or -1)
    U.log("arena: %s: the challenge fails for both", why)
end

-- Out: hidden, untouchable, no input, watching the partner (re-applied every second: the game re-shows players).
local function applyOut()
    local pawn, pc = myPawn()
    if not pawn then return end
    pcall(function()
        pawn:SetActorHiddenInGame(true)
        pawn:SetActorEnableCollision(false)
        pawn:BPF_SetInvincibility(true)
    end)
    pcall(function() pawn:DisableInput(pc) end)
    local partner = require("tc_presence").puppetActor()
    if U.valid(partner) and not AR.watching then
        local ok = pcall(function() pc:SetViewTargetWithBlend(partner, 1.0, 0, 0, false) end)
        if ok then
            AR.watching = true
            U.log("arena: we're out: watching the partner")
        end
    end
end

local function outTick(now)
    if not (started and S.connected() and F.activity == "arena") then return end
    if out.me then
        if outApplyAt and now >= outApplyAt then applyOut() end
        return
    end
    local pawn = myPawn()
    if not pawn then return end
    if out.partner then
        -- The last one standing: the game's own game over plays here; the partner's game fails with it.
        local okG, over = pcall(function() return pawn.m_PlayerComponent:BPF_IsGameOver() end)
        if okG and over then fail("both players are out") end
        return
    end
    local sc = myStats()
    local okA, age, counter, limit = pcall(function()
        return sc:BPF_GetCharacterAge(), sc:BPF_GetStat(STAT_DEATH_COUNTER), sc.m_iMaxAge
    end)
    if not (okA and age and counter and limit) then return end
    local onLastLife = age + counter + 1 >= limit
    if onLastLife ~= lastLife then
        lastLife = onLastLife
        setCanDie(pawn, not onLastLife)
        U.log("arena: %s (age %d, death count %d, limit %d)", onLastLife
            and "last life: a fatal blow puts us out instead (partner still in)" or "not on the last life any more",
            age, counter, limit)
    end
    if not lastLife then return end
    local okH, hp = pcall(function() return pawn.m_HealthComponent.m_fHealth end)
    if not (okH and hp and hp <= 1) then return end
    out.me, outApplyAt = true, now  -- nothing to wait for: no death screen
    N.send(true, "arena", "out")
    U.log("arena: fatal blow on our last life while the partner is still in: we sit it out (age %d)", age)
end

function AR.onPartnerOut()
    if out.partner then return end
    out.partner = true
    require("tc_presence").partnerOut = true
    U.log("arena: the partner is out of the challenge")
    if out.me then
        -- Both out at once (each went out before hearing of the other): both fail.
        local o = AR.objective()
        if o then pcall(function() o:BPF_ConditionFailed() end) end
        fail("the partner went out as well")
    elseif lastLife then
        -- We're the last one in: our next death is a real one.
        lastLife = false
        local pawn = myPawn()
        if pawn then setCanDie(pawn, true) end
        U.log("arena: we're the last one in: our next fatal blow ends the challenge")
    end
end

-- WAVES ---------------------------------------------------------------------------------------------------------
-- Only the host's waves run. The joiner's wave director would send out its own (another random variant, at another
-- spawner, at another time): those were all put aside - the joiner's copies of the host's enemies come from its
-- spawners (tc_enemies makeCopy) - and it moved on only as they died, so its waves drifted from the host's (its screen
-- showed the first wave for the whole challenge). So the joiner's director is stopped as soon as a wave of its own
-- starts (refill off, wave cancelled: no enemies of its own, none to hide), and its HUD's waves counter shows the
-- host's. (Replaying the host's HUD wave events instead - "On Wave Started" - moved the joiner's HUD on by its own
-- count, which its stopped director had already changed: "Last Wave" during the second.)
local director, hud = nil, nil

-- (Two instances exist: the one on screen is the one with its widgets.)
local function liveHud()
    if U.valid(hud) then return hud end
    hud = nil
    local ok, all = pcall(FindAllOf, "BP_HUD_Arena_C")
    for _, h in ipairs(ok and all or {}) do
        local okW, has = pcall(function()
            return U.valid(h) and not h:GetFullName():find("Default__", 1, true) and U.valid(h.ProgressionCurrentNumber)
        end)
        if okW and has then
            hud = h
            break
        end
    end
    return hud
end

-- The waves counter on the HUD ("3 | Waves", "Last Wave": ProgressionCurrentNumber, an int stat text, and the label
-- TextBlock_Progression) is drawn by the HUD's UpdateProgression, which its nativized code calls for its own director
-- only: the joiner's showed the first wave's count all challenge. The host's counter is copied over as it changes.
local hudText = { key = nil, at = -1e9 }
local textLib
-- (The number is set as text: its int Stat stays 0.)
local function counter(inst)
    local ok, s = pcall(function()
        local n, p = inst.ProgressionCurrentNumber, inst.TextBlock_Progression
        return { ntext = n:GetText():ToString(), nvis = n:GetVisibility(), ptext = p:GetText():ToString(),
                 pvis = p:GetVisibility(), wave = inst.ActualWave }
    end)
    return ok and s or nil
end

local function sendCounter(now)
    local inst = liveHud()
    local c = inst and counter(inst)
    if not c then return end
    local key = string.format("%s|%d|%d|%s|%d", c.ntext, c.nvis, c.pvis, c.ptext, c.wave)
    if key == hudText.key and now - hudText.at < 5000 then return end
    hudText.key, hudText.at = key, now
    N.send(true, "arena", "counter", (c.ntext:gsub("|", "/")), c.nvis, c.pvis, (c.ptext:gsub("|", "/")), c.wave)
end

applyCounter = function(f)
    local inst = liveHud()
    local ntext, nvis, pvis, ptext, wave = f[2] or "", tonumber(f[3]), tonumber(f[4]), f[5] or "", tonumber(f[6])
    if not (inst and nvis and pvis) then return end
    local c = counter(inst)
    if c and c.ntext == ntext and c.nvis == nvis and c.pvis == pvis and c.ptext == ptext and (not wave or c.wave == wave) then
        return
    end
    textLib = U.valid(textLib) and textLib or StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    local ok, err = pcall(function()
        local n, p = inst.ProgressionCurrentNumber, inst.TextBlock_Progression
        if wave then inst.ActualWave = wave end
        n:SetText(textLib:Conv_StringToText(ntext))
        n:SetVisibility(nvis)
        p:SetText(textLib:Conv_StringToText(ptext))
        p:SetVisibility(pvis)
    end)
    U.log("arena: the host's waves counter (%s | %s) -> ours: %s", ntext, ptext, ok and "ok" or tostring(err))
end

local function waveTick(now)
    if not (started and S.connected() and F.activity == "arena") then return end
    if S.role == "host" then sendCounter(now) end
    if S.role ~= "join" then return end
    if not U.valid(director) then director = AR.live("AIWaveRefillDirector") end
    if not director then return end
    -- From the start: its first wave's enemies then never come out (they were visible a second or two before being
    -- put aside - lab GHOST lines at every first wave).
    if not AR.refillOff then
        AR.refillOff = pcall(function() director:BPF_SetRefillDisabled() end)
        U.log("arena: our wave director's refill off (the host's waves are the ones): %s", tostring(AR.refillOff))
    end
    local ok, on = pcall(function() return director:BPF_IsWaveInProgress() end)
    if not (ok and on) then return end
    local okC, err = pcall(function()
        director:BPF_SetRefillDisabled()
        director:BPF_CancelCurrentWave()
    end)
    U.log("arena: our wave director started a wave of its own: stopped (the host's waves are the ones): %s",
        okC and "ok" or tostring(err))
end

-- Lab / tests: press Start here and on the partner's side.
function AR.startBoth()
    if press("test") then
        if S.connected() then N.send(true, "arena", "start") end
        onStarted()
        return true
    end
    return false
end

function AR.start()
    hookAll()
    N.on("arena", function(f) U.onGameThread("arena message", function() onArena(f) end) end)
    F.onMapChange(function()
        ready, partnerReady, started, pendingStart = false, nil, false, false
        endSent, endApplied, pendingNav = false, false, nil
        out.me, out.partner, outApplyAt, AR.watching, lastLife = false, false, nil, nil, false
        director, hud, hudText, AR.refillOff = nil, nil, { key = nil, at = -1e9 }, nil
        require("tc_presence").partnerOut = false
    end)
    S.onChange(function()
        if not S.connected() then pendingGo, pendingStart, partnerReady = nil, false, nil end
    end)
    U.poll("arena sync", 250, function()
        if pendingGo and canTravel() then
            local g = pendingGo
            pendingGo = nil
            go(g.batch, g.challenge, "partner's pick")
        end
        if not started and inChallengeMap() and AR.titleMenu() then
            if not ready then
                ready = true
                local b, c = AR.current()
                if S.connected() then N.send(true, "arena", "ready", b or -1, c or -1) end
                U.log("arena: on the title screen (batch %s challenge %s)", tostring(b), tostring(c))
            end
            if pendingStart then
                if press("partner pressed Start") then onStarted() end
            end
        end
        hostResultTick()
        local now = TailCoop_Clock()
        navTick(now)
        if now - (AR.outCheckAt or 0) >= (out.me and 1000 or 100) then
            AR.outCheckAt = now
            outTick(now)
        end
        if now - (AR.navCheckAt or 0) >= 1000 then
            AR.navCheckAt = now
            navHookTick()
        end
        if now - (AR.waveCheckAt or 0) >= 500 then
            AR.waveCheckAt = now
            waveTick(now)
        end
        -- Joiner: stand beside the host at the player start instead of on the same spot.
        if AR.offsetAt and TailCoop_Clock() >= AR.offsetAt then
            AR.offsetAt = nil
            U.try("arena offset", function()
                local pc = U.playerController()
                local pawn = pc and pc.Pawn
                if not U.valid(pawn) then return end
                local l, r = pawn:K2_GetActorLocation(), pawn:GetActorRightVector()
                local rot = pawn:K2_GetActorRotation()
                pawn:K2_SetActorLocationAndRotation({ X = l.X + r.X * 150, Y = l.Y + r.Y * 150, Z = l.Z }, rot, false, {}, true)
                U.log("arena: joiner moved 150 cm beside the start")
            end)
        end
        return false
    end)
end

return AR
