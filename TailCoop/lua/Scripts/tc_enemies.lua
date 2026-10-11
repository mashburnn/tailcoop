-- tc_enemies: shared enemies (G5). The HOST runs every enemy's AI; the JOINER's copies follow the host.
--
-- Identity: an enemy's spawner (a level actor, same name in both games) + the order it spawned there.
-- Host -> joiner, 20 Hz unreliable: "e|id|clock|x|y|z|yaw|health|maxHealth|class"; reliable "eact"/"eactend"
--   when an enemy starts/stops an action animation (attacks, hit reactions, deaths...).
-- Joiner: for each matched enemy, stops its AI (behaviour tree), turns off its movement physics, places it from the
--   host's snapshots (100 ms interpolation), plays the host's action animations on it, and keeps its health equal to
--   the host's. Damage the joiner deals to its copy is measured and reported ("edmg"); the host applies it to the
--   real enemy, so both players' hits come off one shared health bar.
local U = require("tc_util")
local N = require("tc_net")
local S = require("tc_session")
local F = require("tc_flow")
local A = require("tc_anim")
local Hits = require("tc_hits")
local Pose = require("tc_pose")
local Gear = require("tc_gear")
local TL = require("tc_timeline")

local E = {}

local SEND_MS = 50       -- roster / takeover checks
local SNAPSHOT_MS = 33   -- owner: each enemy's position and exact pose, together (same timestamp)

-- Per world: enemy address -> { id, actor }; spawner name -> count of enemies seen from it.
local known, spawnCounts, worldKey = {}, {}, nil
local retiredActors = {}  -- per world: address -> true for characters of ours we've retired (never an enemy again)
local madeIds = {}        -- per world (joiner): host id -> the copy one of our spawners sent out for it (makeCopy)
local keepWaveStep        -- (below, with makeCopy)
-- Follower side: id -> { snaps = {...}, health, maxHealth, class, actor, controlled, lastLocalHealth, lastDamageAt }
local remote = {}

-- Ownership: each enemy's AI runs in one game, its "owner" ("host" by default, "join" while it fights the joiner);
-- the owner sends its state, the other game follows with a stand-in (twin). The host decides who owns what
-- (tc_aggro), and an enemy only changes hands between its actions (handover section below).
local owner = {}
local handovers = {}   -- id -> { to, since } waiting for a quiet moment (we own it)
local requested = {}   -- host: id -> owner asked of the joiner (it owns the enemy)
local targetOf = {}    -- id -> "host"|"join": the player it should fight (set by the host's tc_aggro)
-- Enemies the partner was given but had no copy of: not handed to them again for a while (they're fought from here,
-- through the partner's character).
local refused = {}     -- id -> clock
local REFUSED_MS = 4000  -- (its stand-in here is usually ~1 s away)
-- Enemies we just gave back because our copy was dead or in a takedown / grab (becomeOwner): not asked for again yet.
local busyUntil = {}   -- id -> clock
local function ownerOf(id) return owner[id] or "host" end
local function mine(id) return ownerOf(id) == S.role end
local function otherRole() return S.role == "host" and "join" or "host" end
E.ownerOf, E.mine = ownerOf, mine
local stats = { sent = 0, received = 0, damageSent = 0, damageApplied = 0, actions = 0 }

local function clock() return TailCoop_Clock() end

-- Arena challenges keep a pool of ~100 spawned characters waiting (at the world origin), and put dead ones back:
-- not enemies until a spawner sends one out (ASCCharacter: m_bIsPooled, m_bPooledActorActive). Not by place: live
-- enemies cross the origin too, and briefly report it while their fight starts.
local function pooled(c)
    local ok, yes = pcall(function() return c.m_bIsPooled and not c.m_bPooledActorActive end)
    return ok and yes == true
end

-- (Checked for every character twice a second - in an arena ~100, most of them pooled: the cheap checks come first,
-- and whether it's a class default object is remembered.)
local defaults = {}  -- address -> true if a class default object (per world)
local playerControllerClass
local function isEnemyCheck(c)
    local addr = c:GetAddress()
    local k = known[addr]
    if k and k.proxy then return true end  -- our stand-in for a host enemy this game doesn't have
    if retiredActors[addr] then return false end  -- a stand-in of ours we've retired (tc_enemies.retire)
    if c.m_bIsPooled and not c.m_bPooledActorActive then return false end
    local d = defaults[addr]
    if d == nil then
        d = c:GetFullName():find("Default__", 1, true) ~= nil
        defaults[addr] = d
    end
    if d then return false end
    local ai = c.m_AIComponent
    if not U.valid(ai) then return false end
    local ctrl = c.Controller
    if not U.valid(ctrl) then return false end
    if not U.valid(playerControllerClass) then playerControllerClass = StaticFindObject("/Script/Engine.PlayerController") end
    return not ctrl:IsA(playerControllerClass)
end

local function isEnemy(c)
    local ok, yes = pcall(isEnemyCheck, c)
    return ok and yes
end

-- Sifu's player auto-aim (each attack turns the player toward its target: UAttackComponent BPF_GetTargetForInput)
-- takes hidden characters too. Those TailCoop hides but keeps alive with collision off - enemies put aside, parked
-- twins - stood where they were left: a player who walked onto one's spot attacked a target at their own feet and
-- turned in place, punching the air, until a hit knocked them off it (user: "spins when I press buttons", "spun until
-- an enemy moved me"; lab: aimed at parked twins 2-5 cm away). Their targetable flag (m_TargetLocation
-- m_bIsValidTarget) isn't what the aim checks, so they're lifted out of reach while hidden, like the partner's parked
-- character, and put back where they were when they're needed again.
-- ("hidetargets = 0" in TailCoop.ini leaves them where they are, for lab comparison.)
local LIFT = 20000
local liftedFrom = {}  -- actor address -> { x, y, z } it was lifted from
local function outOfReach(c)
    if U.config.hidetargets == "0" or not U.valid(c) then return end
    local key = c:GetAddress()
    pcall(function()
        local l = c:K2_GetActorLocation()
        if liftedFrom[key] and l.Z > liftedFrom[key].z + LIFT / 2 then return end  -- up there already
        liftedFrom[key] = { x = l.X, y = l.Y, z = l.Z }
        c:K2_SetActorLocation({ X = l.X, Y = l.Y, Z = l.Z + LIFT }, false, {}, true)
    end)
end

-- Back down where it was lifted from (true if it was up there).
local function bringBack(c)
    if not U.valid(c) then return false end
    local from = liftedFrom[c:GetAddress()]
    if not from then return false end
    liftedFrom[c:GetAddress()] = nil
    pcall(function() c:K2_SetActorLocation({ X = from.x, Y = from.y, Z = from.z }, false, {}, true) end)
    return true
end

-- All enemies in the current world, with stable ids. FindAllOf walks every object in the game (~0.5 ms, up to 10+
-- during loads), so it runs at most every SCAN_MS and everything else uses that list (scan()).
local SCAN_MS = 500
local function scanNow()
    local tScan = U.tick()
    local w = U.world()
    local wk = U.valid(w) and w:GetAddress() or nil
    if wk ~= worldKey then
        worldKey, known, spawnCounts, remote, defaults, liftedFrom, retiredActors = wk, {}, {}, {}, {}, {}, {}
        madeIds = {}
    end
    local list = {}
    local ok, all = pcall(FindAllOf, "FightingCharacter")
    for _, c in ipairs(ok and all or {}) do
        if U.valid(c) and isEnemy(c) then
            local addr = c:GetAddress()
            local entry = known[addr]
            if not entry then
                local spawnerName, fromWave = "none", false
                pcall(function()
                    local sp = c.m_AIComponent.m_Spawner
                    if U.valid(sp) then
                        spawnerName = sp:GetFName():ToString()
                        fromWave = sp:GetFullName():find("WaveSpawner", 1, true) ~= nil
                    end
                end)
                spawnCounts[spawnerName] = (spawnCounts[spawnerName] or 0) + 1
                local id = spawnerName .. "#" .. spawnCounts[spawnerName]
                if spawnerName == "none" then
                    local l = c:K2_GetActorLocation()
                    id = c:GetClass():GetFName():ToString() .. "@" .. math.floor(l.X / 100) .. "," .. math.floor(l.Y / 100)
                end
                -- The level's own enemy for an id we already had a spawner make a copy for (makeCopy): an extra,
                -- put aside (joinerTick).
                local extra = madeIds[id] and U.valid(madeIds[id]) and madeIds[id]:GetAddress() ~= addr
                if extra then id = id .. "+" end
                entry = { id = id, actor = c, foundAt = TailCoop_Clock(), extra = extra or nil, fromWave = fromWave }
                known[addr] = entry
                U.log("enemies: found %s (%s)", id, U.shortName(c))
                -- Its hit function, looked up now (it appeared: the game hitches anyway) rather than at its first
                -- handover mid-fight (tc_hits caches it per class).
                Hits.functionFor(c, "Hitted")
            end
            list[#list + 1] = entry
        elseif U.valid(c) and known[c:GetAddress()] and pooled(c) then
            -- Back in the arena pool (dead): when it is sent out again it's a new enemy with a new id. (Only then: an
            -- enemy that fails the check for a moment, e.g. between controllers, keeps its id.)
            local addr = c:GetAddress()
            do
                U.log("enemies: %s left (back in the pool)", known[addr].id)
                known[addr] = nil
            end
        end
    end
    U.tock("scan (FindAllOf FightingCharacter)", tScan)
    return list
end

local scanCache = { at = -1e9, list = {} }
local function scan()
    local now = TailCoop_Clock()
    if now - scanCache.at >= SCAN_MS then
        scanCache.list, scanCache.at = scanNow(), now
    end
    return scanCache.list
end

-- The list is up to SCAN_MS old: a stand-in destroyed since is still in it, and touching a destroyed actor crashes
-- inside UE4SS (pcall doesn't catch it). Whoever uses the actors without checking each one takes this list.
local function liveScan()
    local out = {}
    for _, e in ipairs(scan()) do
        if U.valid(e.actor) then out[#out + 1] = e end
    end
    return out
end

local function health(c)
    local ok, h, m = pcall(function() return c.m_HealthComponent.m_fHealth, c.m_HealthComponent.m_fMaxHealth end)
    if ok then return h, m end
    return nil, nil
end

-- Sifu's synchronized moves: the order an enemy runs as the victim of a takedown, grab, push, environment attack or
-- synchronized attack (EOrderType 9, 16, 26, 35, 41). A player's takedown runs only in that player's game, on whatever
-- character is there - for an enemy the partner runs, our hidden copy of it.
local VICTIM_ORDERS = { [9] = true, [16] = true, [26] = true, [35] = true, [41] = true }
local function inSyncMove(c)
    local ok, yes = pcall(function()
        local oc = c:BPF_GetOrderComponent()
        local ids = oc:BPF_GetRunningAndPendingActionOrders(false)
        local found = false
        local function one(v)
            local orderId = type(v) == "number" and v or v:get()
            if VICTIM_ORDERS[oc:BPF_GetOrderTypeFromOrderID(orderId)] then found = true end
        end
        if type(ids) == "table" then
            for _, v in ipairs(ids) do one(v) end
        elseif ids and ids.ForEach then
            ids:ForEach(function(_, el) one(el) end)
        end
        return found
    end)
    return ok and yes
end

-- An enemy whose AI starts again here with nobody to fight (the partner left or went quiet) comes for our player;
-- left alone it stood idle for the rest of the fight.
local function aimAtMe(c)
    local pc = U.playerController()
    local me = pc and U.valid(pc.Pawn) and pc.Pawn or nil
    if me then pcall(function() c.m_AIComponent:BPF_ForceEnemy(me, 3) end) end  -- EGlobalBehaviors::Alerted
end

-- Per enemy id: tc_anim watcher over its action tracks (same reader as the player's: enemies use UPlayerAnim too;
-- an enemy whose anim isn't one is logged once).
local watchers = {}

local function actionEvent(e, now)
    local w = watchers[e.id]
    if not w then
        -- (The watcher keeps the anim instance itself: looked up here only once.)
        local inst = A.animInstance(e.actor)
        if not inst then return nil end
        w = A.watcher()
        watchers[e.id] = w
        if not A.readRaw(inst) then
            U.log("enemies: can't read actions of %s (anim %s)", e.id, U.shortName(inst))
        end
    end
    return w:update(e.actor, now)
end

local function recentScan() return scan() end

-- HOST ---------------------------------------------------------------------------------------------------


-- Owner side (both games, for the enemies they own): one enemy's position snapshot, stamped `now` (the same time as
-- the pose sent with it, so the other game shows both from one timeline).
-- h, m: its health and max health, read once per pass by the caller. Stance and fighting quadrant (they change a few
-- times a fight; the copy's walk cycle follows them) are read 5 times a second, not 30.
local function sendSnapshot(e, now, h, m)
    local c = e.actor
    local okL, l = pcall(function() return c:K2_GetActorLocation() end)
    if not okL then return end
    local yaw = c:K2_GetActorRotation().Yaw
    -- What rarely changes (class, max health, AI archetype) goes reliably on its own, at first and every 3 s.
    if not e.infoAt or now - e.infoAt > 3000 then
        e.infoAt = now
        e.classPath = e.classPath or A.path(c:GetClass()) or ""
        if not e.archPath then
            pcall(function()
                local arch = c.m_AIComponent.m_CurrentAIArchetype
                if U.valid(arch) then e.archPath = arch:GetFullName():match("^%S+%s+(.+)$") end
            end)
        end
        N.send(true, "einfo", e.id, e.classPath, string.format("%.0f", m or -1), e.archPath or "")
    end
    if not e.stanceAt or now - e.stanceAt >= 200 then
        e.stanceAt = now
        if not (U.valid(e.inst)) then e.inst = A.animInstance(c) end
        e.stance, e.quadrant = tostring(A.moveStatus(c) or 1), tostring(A.quadrant(e.inst) or "")
    end
    N.send(false, "e", e.id, now, string.format("%.0f", l.X), string.format("%.0f", l.Y),
        string.format("%.0f", l.Z), string.format("%.1f", yaw), string.format("%.1f", h or -1), e.stance, e.quadrant)
    stats.sent = stats.sent + 1
end

-- Every frame: enemy action starts/ends ("eact|id|path|mirror|rate|startRatio|cursor|clock|track"), and every 33 ms
-- each enemy's position and exact pose (tc_pose, under its id).
local lastPoseAt, gearStates = {}, {}
local lastActions = {}  -- host: id -> { path, at } of the enemy's latest action
function E.lastActionOf(id) return lastActions[id] end
-- Every enemy's action right now as this game sees it: ours from the watchers, the partner's from "eact" / "eactend"
-- (turn-taking and the lab's crowd test read it).
local actNow = {}   -- id -> { path, at }
function E.actionNow(id) return actNow[id] end
-- Deaths: the owner tells the other game, which kills its copy the game's own way (ServerSuicide: the arena's wave
-- director counts it, unlike a health of 0). A dead enemy never changes hands.
local deadIds = {}   -- id -> clock of its death
local function noteDeath(e, h)
    if deadIds[e.id] then return end
    if not h or h > 0 then return end
    deadIds[e.id] = clock()
    N.send(true, "edead", e.id)
    U.log("enemies: our %s died, partner told", e.id)
    -- One a spawner of ours made for the host's wave enemy: no director here counts it. Our own wave enemy for the same
    -- id (another variant, put aside) dies with it, else another put-aside one (keepWaveStep).
    if e.made then
        local counted = false
        for _, o in ipairs(liveScan()) do
            if (o.id == e.id or o.id == e.id .. "+") and o ~= e and (o.dormant or o.wrongKind) then
                local oh = health(o.actor)
                if oh and oh > 0 then pcall(function() o.actor:ServerSuicide(false) end) end
                counted = counted or o.fromWave
            end
        end
        if not counted then keepWaveStep(e.id) end
    end
end

-- Everything an enemy's owner sends happens at the snapshot rate (30 Hz), one enemy per pass: the other game shows
-- the enemy from its exact pose stream, so reading its actions every frame (was: ~600 reads a second in an arena
-- wave) only added game time.
local function hostActionTick()
    local now = clock()
    for _, e in ipairs(scan()) do
        -- (Not one of ours put aside for the same id - another variant than the host's: its stand-in speaks for it.)
        if not mine(e.id) or e.wrongKind or e.dormant then goto continue end
        if now - (lastPoseAt[e.id] or 0) < SNAPSHOT_MS then goto continue end
        if not U.valid(e.actor) then goto continue end
        lastPoseAt[e.id] = now
        do
            local h, m = health(e.actor)
            noteDeath(e, h)
            -- Its death shown for 3 s, then no more reports (it lies there until the arena pool takes it back).
            if deadIds[e.id] and now - deadIds[e.id] > 3000 then goto continue end
            gearStates[e.id] = gearStates[e.id] or {}
            local tg = U.tick()
            Gear.publish(e.actor, e.id, gearStates[e.id], now)
            U.tock("enemy gear publish", tg)
            local ts = U.tick()
            sendSnapshot(e, now, h, m)
            U.tock("enemy snapshot send", ts)
            -- Per sender: each game's clock is its own, so a stream never mixes the two.
            if e.poseIdRole ~= S.role then e.poseId, e.poseIdRole = e.id .. "@" .. S.role, S.role end
            local tp = U.tick()
            local bytes, err = Pose.send(e.actor, e.poseId, now, e)
            U.tock("enemy pose send", tp)
            if not bytes and err ~= stats.poseErr then
                stats.poseErr = err
                U.log("enemies: pose of %s not sent: %s", e.id, tostring(err))
            end
        end
        local ta = U.tick()
        local ev = actionEvent(e, now)
        U.tock("enemy action read", ta)
        if ev and ev.kind == "end" then
            actNow[e.id] = nil
            N.send(true, "eactend", e.id)
        elseif ev and ev.path then
            lastActions[e.id] = { path = ev.path, at = now }
            actNow[e.id] = lastActions[e.id]
            N.send(true, "eact", e.id, ev.path, ev.mirror and 1 or 0, string.format("%.3f", ev.rate),
                string.format("%.3f", ev.start), string.format("%.3f", ev.cursor), now, ev.track)
            stats.actions = stats.actions + 1
            if stats.actions <= 60 or stats.actions % 50 == 0 then
                U.log("enemies: %s %s %s rate %.2f start %.2f", e.id, ev.track, ev.path, ev.rate, ev.start)
            end
        end
        ::continue::
    end
end

local function onDamage(f)
    local id, amount = f[1], tonumber(f[2])
    if not amount or amount <= 0 then return end
    for _, e in ipairs(scan()) do
        if e.id == id then
            local before = health(e.actor)
            pcall(function() e.actor.m_HealthComponent:BPF_ApplyDamage(amount) end)
            if before and health(e.actor) and math.abs(health(e.actor) - before) < 0.01 then
                -- ApplyDamage is ignored in some contexts (seen in Free Training): subtract health directly.
                pcall(function() e.actor.m_HealthComponent:BPF_ServerAddHealth(-amount) end)
            end
            stats.damageApplied = stats.damageApplied + 1
            U.log("enemies: partner hit %s for %.1f (health %.1f -> %.1f)", id, amount, before or -1, health(e.actor) or -1)
            return
        end
    end
    U.log("enemies: partner hit unknown enemy %s", id)
end

-- JOINER -------------------------------------------------------------------------------------------------

local function onInfo(f)
    if mine(f[1]) then return end
    local r = remote[f[1]]
    if not r then
        r = { snaps = {}, id = f[1] }
        remote[f[1]] = r
    end
    r.class, r.maxHealth = f[2], tonumber(f[3])
    if f[4] and f[4] ~= "" then r.archetype = f[4] end
end

-- Joiner: our copy of a host enemy is the host's kind of enemy, not only its class. A copy one of our spawners sent out
-- (makeCopy) took that spawner's AI archetype - the settings of whatever it was placed for: an arena miniboss came out
-- as a common grunt or servant, with their max health (330 here, 60 or 100 there) and none of the miniboss's bars.
-- Health came from the host, so it sat at or above the copy's max: its health bar counted as full and stayed hidden,
-- or showed the wrong fill (user: "I'm not able to see the health of certain enemies"; lab: 11 of the joiner's 12
-- spawned copies). Given the host's archetype and max health here; once per copy, then whenever the host's differ.
-- (Archetypes are class default objects of the arena's DB classes, loaded in both games: looked up by path, each path
-- once - a lookup of a path that isn't there costs ~35 ms.)
local archetypes = {}  -- path -> object or false
local function archetypeObject(path)
    local a = archetypes[path]
    if a == nil then
        local o = StaticFindObject(path)
        a = U.valid(o) and o or false
        archetypes[path] = a
    elseif a and not U.valid(a) then
        archetypes[path] = nil
        return archetypeObject(path)
    end
    return a or nil
end

local function matchHost(r, c)
    if S.role ~= "join" then return end
    if r.archetype and r.archApplied ~= r.archetype .. "@" .. tostring(c:GetAddress()) then
        r.archApplied = r.archetype .. "@" .. tostring(c:GetAddress())
        local arch = archetypeObject(r.archetype)
        local ok, before = pcall(function()
            local ai = c.m_AIComponent
            local cur = ai.m_CurrentAIArchetype
            local name = U.valid(cur) and cur:GetFName():ToString() or "-"
            if arch and not (U.valid(cur) and cur:GetAddress() == arch:GetAddress()) then
                ai.m_CurrentAIArchetype = arch
                return name
            end
            return nil
        end)
        if ok and before then
            U.log("enemies: our copy of %s was a %s: now the host's %s", r.id or "?", before, arch:GetFName():ToString())
        elseif not arch then
            U.log("enemies: the host's archetype for %s isn't loaded here (%s)", r.id or "?", r.archetype)
        end
    end
    local _, m = health(c)
    if r.maxHealth and r.maxHealth > 0 and m and math.abs(m - r.maxHealth) > 0.5 then
        pcall(function() c.m_HealthComponent.m_fMaxHealth = r.maxHealth end)
        if not r.maxLogged then
            r.maxLogged = true
            U.log("enemies: our copy of %s had max health %.0f: now the host's %.0f", r.id or "?", m, r.maxHealth)
        end
    end
end

local function onSnapshot(f)
    local id, t = f[1], tonumber(f[2])
    if mine(id) then return end  -- late, from before we took it over
    local r = remote[id]
    if not r then
        r = { snaps = {}, id = id }
        remote[id] = r
    end
    if not t then return end
    TL.observe("e:" .. id, t, clock())
    if #r.snaps > 0 and t <= r.snaps[#r.snaps].t then return end
    r.snaps[#r.snaps + 1] = { t = t, x = tonumber(f[3]), y = tonumber(f[4]), z = tonumber(f[5]), yaw = tonumber(f[6]) }
    if #r.snaps > 30 then table.remove(r.snaps, 1) end
    -- "e|id|clock|x|y|z|yaw|health|stance|quadrant" (class / max health come in "einfo")
    r.health, r.lastHeard = tonumber(f[7]), clock()
    r.stance = tonumber(f[8]) or 1
    r.quadrant = tonumber(f[9])
    stats.received = stats.received + 1
end

-- Where the enemy was at the partner's clock time renderT (tc_timeline: the same time its pose is shown at).
local function sample(r, renderT)
    if #r.snaps == 0 or not renderT then return nil end
    local newest = r.snaps[#r.snaps]
    if renderT >= newest.t then return newest end
    for i = #r.snaps - 1, 1, -1 do
        local a, b = r.snaps[i], r.snaps[i + 1]
        if renderT >= a.t then
            local k = (renderT - a.t) / math.max(1, b.t - a.t)
            local d = (b.yaw - a.yaw + 540) % 360 - 180
            return { x = a.x + (b.x - a.x) * k, y = a.y + (b.y - a.y) * k, z = a.z + (b.z - a.z) * k, yaw = a.yaw + d * k }
        end
    end
    return r.snaps[1]
end

-- Hands one of our enemies over to the host. The real enemy stays as Sifu built it (so our hits, targeting and Sifu's
-- own logic keep working) but invisible, with its AI and movement physics off; a visual twin of the same class with no
-- AI controller stands in its place and shows what the host's enemy does. Replacing the real enemy's animation instance
-- instead crashed the game (Sifu's order code reads it: -Test hittest), the twin doesn't (-Test enemytwin).
-- Characters of ours that Sifu may still point at (the player's auto-aim and finishers take any character in reach,
-- enemies keep their targets) are never destroyed mid-world: destroying the twin of an enemy that had just died
-- crashed the game inside Sifu a second later (lab 2026-10-10, read of a freed object). They're retired instead:
-- hidden, no collision, no AI, no pose stream, lifted out of reach; the world's end takes them.
local function retire(actor, motion)
    if not U.valid(actor) then return end
    retiredActors[actor:GetAddress()] = true
    if motion then Pose.park(actor, motion) end
    pcall(function() actor.Controller.BrainComponent:StopLogic("TailCoop: retired") end)
    pcall(function() actor.m_AIComponent:BPF_ForgetEnemy() end)
    pcall(function() actor.CharacterMovement:SetMovementMode(0, 0) end)
    pcall(function()
        actor:SetActorHiddenInGame(true)
        actor:SetActorEnableCollision(false)
    end)
    for _, w in ipairs(Gear.heldWeapons(actor)) do pcall(function() w:SetActorHiddenInGame(true) end) end
    outOfReach(actor)
end

local function destroyTwin(r)
    for _, t in ipairs({ { r.twin, r.motion }, r.parked or {} }) do
        if t[1] and U.valid(t[1]) then retire(t[1], t[2]) end
    end
    r.twin, r.parked = nil, nil
end

-- Control of an enemy goes back and forth between the games (tc_aggro): when it comes to us, its twin is hidden and
-- kept rather than destroyed, and shown again when the enemy goes back to the partner. Spawning a twin (and giving it
-- its poseable mesh) stalled the game ~35 ms at every handover.
local function parkTwin(r)
    if not (r.twin and U.valid(r.twin)) then
        r.twin = nil
        return
    end
    Pose.park(r.twin, r.motion)
    pcall(function() r.twin:SetActorHiddenInGame(true) end)
    outOfReach(r.twin)
    r.parked, r.twin = { r.twin, r.motion }, nil
end

local function unparkTwin(r, c)
    local p = r.parked
    r.parked = nil
    if not (p and U.valid(p[1])) then return nil end
    local ok = pcall(function()
        if p[1]:GetClass():GetAddress() ~= c:GetClass():GetAddress() then error("class changed") end
        p[1]:SetActorHiddenInGame(false)
    end)
    -- (Its place comes from the partner's snapshots on the next frame: forget where it was lifted from.)
    if ok then liftedFrom[p[1]:GetAddress()] = nil end
    if not ok then
        retire(p[1], p[2])
        return nil
    end
    -- Same twin, fresh motion state; the poseable mesh and the weapon it already has are kept.
    local m = p[2]
    Pose.unpark(m)
    return p[1], { poseable = m.poseable, poseMode = m.poseMode, gearComps = m.gearComps, gearDesc = m.gearDesc }
end

-- Sifu's attack tickets (an enemy attacks only while it holds one; tc_turns): a copy whose AI is stopped here must not
-- keep one - stopping the behaviour tree and forgetting the enemy don't give it back, and the ticket stayed held for the
-- rest of the fight: this game's other enemies then never attacked that player (lab: -Test arenacrowd, "stale
-- tickets"). Given back here and refused until the enemy is ours again (allowTickets).
-- It also has to stay out of Sifu's fight here (perception off, its enemy forgotten - checked again every second):
-- left registered as one of our player's attackers, Sifu gave the few "direct opponent" places to such copies -
-- which can't attack - and made every enemy really running here a non-opponent: nobody attacked any more, in both
-- games (lab -Test arenacrowd -Swap: "Sifu attackers 7" with 3 enemies running, all non-opponents, for 2 minutes).
-- (Not BPF_SwitchToIdle: an enemy switched to idle didn't come back into the fight when it was ours again.)
local aiHelpers
local function helpers()
    aiHelpers = U.valid(aiHelpers) and aiHelpers or StaticFindObject("/Script/Sifu.Default__AIHelpers")
    return aiHelpers
end

local function dropTickets(c)
    pcall(function()
        local ai = c.m_AIComponent
        ai:BPF_SetCanTakeAttackTicket(false)
        helpers():BPF_ReleaseOwnedAttackTicket(ai)
        ai:BPF_SetPerceptionEnabled(false)
    end)
    local k = known[c:GetAddress()]
    if k then k.turnGate = false end
end

local function allowTickets(c)
    -- (Not for Training Room enemies set to passive: the room turned their tickets off - tc_training.passive.)
    local passive = require("tc_training").passive()
    pcall(function()
        local ai = c.m_AIComponent
        ai:BPF_SetPerceptionEnabled(true)
        ai:BPF_SetCanTakeAttackTicket(not passive)
    end)
    local k = known[c:GetAddress()]
    if k then k.turnGate = nil end  -- tc_turns sets it again for this enemy
end

-- A copy here registered as attacking our player again (a hit can alert it): back out of the fight. And one whose
-- AI the game started again (arena situations, alerts passed between enemies): stopped again - running with its
-- movement off, it turned on the spot and swung at whoever was near ("stuck, attacks sped up, turns 360 in place").
local function benchIfFighting(c, me)
    local okB, running = pcall(function() return c.Controller.BrainComponent:IsRunning() end)
    if okB and running then
        pcall(function() c.Controller.BrainComponent:StopLogic("TailCoop: the partner runs this enemy") end)
        pcall(function() c.m_AIComponent:BPF_ForgetEnemy() end)
        dropTickets(c)
        stats.restopped = (stats.restopped or 0) + 1
        if stats.restopped <= 20 then
            U.log("enemies: the game started %s's AI again while the partner runs it: stopped", U.shortName(c))
        end
    end
    local ok, yes = pcall(function() return helpers():BPF_IsAttackerRegisteredInCombatForTarget(c, me) end)
    if ok and yes then
        pcall(function() c.m_AIComponent:BPF_ForgetEnemy() end)
        dropTickets(c)
        stats.benched = (stats.benched or 0) + 1
        if stats.benched <= 10 then U.log("enemies: %s was fighting us again while the partner runs it: out", U.shortName(c)) end
    end
end

local function takeControl(r, c)
    local t = U.tick()
    pcall(function()
        local brain = c.Controller.BrainComponent
        if U.valid(brain) then brain:StopLogic("TailCoop: driven by the host") end
    end)
    U.tock("take control: stop AI", t)
    t = U.tick()
    pcall(function() c.m_AIComponent:BPF_ForgetEnemy() end)
    dropTickets(c)
    U.tock("take control: forget enemy", t)
    t = U.tick()
    A.makeDriven(c)
    A.hideReal(c, true)
    U.tock("take control: hide real", t)
    t = U.tick()
    local twin, motion = unparkTwin(r, c)
    U.tock("take control: twin", t)
    if twin then
        r.twin = twin
    else
        destroyTwin(r)
        local l = c:K2_GetActorLocation()
        local ok, spawned = pcall(require("tc_presence").spawnCharacter, c:GetClass(), { x = l.X, y = l.Y, z = l.Z })
        if ok and spawned then
            A.makeDriven(spawned)
            pcall(function() spawned:SetActorEnableCollision(false) end)
            r.twin = spawned
        else
            U.log("enemies: no twin for %s (%s): showing the real one", U.shortName(c), tostring(spawned))
        end
    end
    -- With its AI off, anything the real (hidden) enemy plays is its reaction to OUR hits: shown on the twin at once.
    r.actor, r.controlled, r.motion, r.hiddenAt, r.realWatcher = c, true, motion or {}, 0, A.watcher()
    r.realPlace = nil  -- placed from the owner's snapshots at once (not "still there" from an earlier turn)
    -- What it was doing under its own AI a moment ago (an attack, a dash) finishes first: not a reaction to us.
    r.reactFrom = clock() + 500
    r.lastLocalHealth = health(c)
    r.localPlayed = {}
    -- Our hits on it are captured (FightingCharacter:Hitted, the most-derived override) and sent to the host.
    t = U.tick()
    local fn = Hits.functionFor(c, "Hitted")
    if fn then
        local okW, err = TailCoop_WatchParam(tostring(fn:GetAddress()), tostring(Hits.SIZE.description))
        if not okW then U.log("enemies: can't watch hits on %s: %s", U.shortName(c), tostring(err)) end
    end
    U.tock("take control: watch hits", t)
    U.log("enemies: %s now follows the host (AI stopped, twin %s)", U.shortName(c), U.shortName(r.twin))
end

-- Every captured hit (TailCoopNative's Hitted watch) goes one place: our hit on an enemy the partner owns (its hidden
-- real copy here) -> its owner ("ehit": enemy id + the hit as text, our character's and the enemy's paths as
-- $I$ / $T$ so the owner puts in its own actors); a hit on the partner's character -> tc_aggro.
local function routeCaptures()
    local pc = U.playerController()
    local me = pc and U.valid(pc.Pawn) and pc.Pawn or nil
    local myPath = nil
    while true do
        local ctx, _, text = TailCoop_PollCaptured()
        if not ctx then break end
        local handled = false
        for id, r in pairs(remote) do
            if r.controlled and U.valid(r.actor) and r.actor:GetAddress() == ctx then
                handled = true
                r.ourHitAt = clock()  -- its reaction is read every frame for a moment (placeOne)
                myPath = myPath or (me and Hits.pathOf(me))
                if myPath and text:find(myPath, 1, true) then
                    local t = Hits.replace(Hits.replace(text, Hits.pathOf(r.actor), "$T$"), myPath, "$I$")
                    local ok, err = N.sendLarge("ehit", id .. "\n" .. t)
                    stats.hitsSent = (stats.hitsSent or 0) + 1
                    if not ok then U.log("enemies: sending our hit failed: %s", tostring(err)) end
                    if S.role == "host" then require("tc_aggro").provoke(id, "host") end
                end
                break
            end
        end
        if not handled then require("tc_aggro").onCaptured(ctx, text) end
    end
end

-- Host: the partner hit one of our enemies. Rebuilt with the partner's character on this PC as the instigator and run
-- through the enemy's own hit pipeline (HitComponent:BPF_GenerateForeignImpact), so it reacts, takes damage and
-- defends exactly as if hit here.
local foreignImpactFn
local function onPartnerHit(payload)
    local id, text = payload:match("^([^\n]*)\n(.*)$")
    if not id then return end
    if not mine(id) then
        U.log("enemies: partner hit %s while it was changing hands: dropped", id)
        return
    end
    local target
    for _, e in ipairs(scan()) do
        if e.id == id and U.valid(e.actor) then target = e.actor end
    end
    local puppet = require("tc_presence").puppetActor()
    if not (target and U.valid(puppet)) then
        U.log("enemies: partner hit %s, but %s", id, target and "their character isn't here" or "no such enemy here")
        return
    end
    text = Hits.replace(Hits.replace(text, "$T$", Hits.pathOf(target)), "$I$", Hits.pathOf(puppet))
    local m = Hits.members(text)
    if not (m.m_Request and m.m_Result) then
        U.log("enemies: partner hit %s: unreadable hit text", id)
        return
    end
    foreignImpactFn = foreignImpactFn or StaticFindObject("/Script/Sifu.HitComponent:BPF_GenerateForeignImpact")
    -- It goes after whoever hit it (the host decides; on the joiner's side the host learns it from its own ehit).
    if S.role == "host" then require("tc_aggro").provoke(id, "partner") end
    local before = health(target)
    local ok, err, warnings = TailCoop_CallImported(tostring(target.m_HitComponent:GetAddress()),
        tostring(foreignImpactFn:GetAddress()), m.m_Result, tostring(Hits.SIZE.result), m.m_Request,
        tostring(Hits.SIZE.request))
    stats.hitsApplied = (stats.hitsApplied or 0) + 1
    if not ok or warnings > 0 or stats.hitsApplied <= 20 then
        U.log("enemies: partner hit %s: %s%s, %d warnings, health %.0f -> %.0f", id, ok and "applied" or "FAILED ",
            ok and "" or tostring(err), warnings or -1, before or -1, health(target) or -1)
    end
end

-- The host decides which enemies exist ------------------------------------------------------------------------
-- A host enemy this game doesn't have (e.g. after "Change enemy type", waves...) gets a stand-in: a real enemy of the
-- same class spawned here (so our hits register on it), then taken over like any other. An enemy of ours the host
-- doesn't have (any more) is put aside: hidden, AI off, no collision ("dormant") until the session ends.
local PROXY_AFTER_MS, STALE_MS, DORMANT_AFTER_MS = 2500, 2000, 8000  -- the host may enter the activity later
local connectedAt

local function loadClass(path)
    local cls = StaticFindObject(path)
    if not U.valid(cls) then
        pcall(LoadAsset, (path:gsub("_C$", "")))
        cls = StaticFindObject(path)
    end
    return U.valid(cls) and cls or nil
end

-- Arena waves pick a random variant per spawn, and the two games' wave directors pick other spawners at other times:
-- most of the host's wave enemies had no copy of the same kind here. A stand-in spawned from the class can't fight (no
-- behaviour tree, never in Sifu's fight), so the host kept running all of those - the joiner fought them through its
-- character there, a round trip on every attack. Instead the copy is sent out the game's own way: a level spawner
-- that's free is moved to the host's enemy, given its class (BPF_SetSpawningClass), asked to spawn (BPF_WantsSpawn),
-- and put back. That enemy is real (lab -Test factory: alerted, takes combat roles), so the joiner can run it. (A
-- spawner spawned at runtime sends nothing out; wave spawners only answer their director.)
-- Spawners that already sent their enemy out (and it's gone) come first: one that hasn't may still be wanted by the
-- level (a boss, a later group).
local spawners = { world = nil, at = -1e9, level = {}, byName = {} }
local function refreshSpawners()
    local now = clock()
    if spawners.world ~= worldKey or now - spawners.at > 10000 then
        spawners.world, spawners.at, spawners.level, spawners.byName = worldKey, now, {}, {}
        local ok, all = pcall(FindAllOf, "AISpawner")
        for _, sp in ipairs(ok and all or {}) do
            pcall(function()
                local n = sp:GetFullName()
                if not n:find(":PersistentLevel.", 1, true) then return end
                spawners.byName[sp:GetFName():ToString()] = sp
                if not n:find("Wave", 1, true) then spawners.level[#spawners.level + 1] = sp end
            end)
        end
    end
end

-- A wave spawner's enemy (by its id: the spawner of that name here)?
local function waveId(id)
    refreshSpawners()
    local sp = spawners.byName[id:match("^(.-)#%d+$") or ""]
    local ok, yes = pcall(function() return sp:GetFullName():find("WaveSpawner", 1, true) ~= nil end)
    return ok and yes
end

-- Joiner: the host's wave enemy `id` died, and our wave director's enemy for it came out elsewhere (another spawner,
-- another time: put aside, the host doesn't have it) - our copy was made by a spawner of ours, which no director
-- counts. One of those put-aside wave enemies dies instead, oldest first, so our director keeps step: the wave count
-- shown, the next wave. (Was: stuck on the first wave for the whole challenge on the joiner.)
local function killPutAsideWave(why)
    local pick
    for _, e in ipairs(liveScan()) do
        if e.dormant and not e.wrongKind and e.fromWave and not remote[e.id] and not deadIds[e.id]
            and (health(e.actor) or 0) > 0 and (not pick or (e.foundAt or 0) < (pick.foundAt or 0)) then
            pick = e
        end
    end
    if not pick then return nil end
    pcall(function() pick.actor:ServerSuicide(false) end)
    deadIds[pick.id] = deadIds[pick.id] or clock()
    U.log("enemies: %s: our own %s (put aside) dies for it", why, pick.id)
    return pick.id
end

keepWaveStep = function(id)
    if S.role ~= "join" or not waveId(id) then return end
    killPutAsideWave("the host's wave enemy " .. id .. " died")
end

local function freeLevelSpawner()
    refreshSpawners()
    local fresh
    for _, sp in ipairs(spawners.level) do
        if U.valid(sp) then
            local ok, free = pcall(function() return not sp:BPF_HasSpawnedAI() and not sp:IsSpawnerBusy() end)
            if ok and free then
                if spawnCounts[sp:GetFName():ToString()] then return sp end
                fresh = fresh or sp
            end
        end
    end
    return fresh
end

local function makeCopy(r, id, cls, at)
    local sp = freeLevelSpawner()
    if not sp then return nil, "no free level spawner" end
    local t = U.tick()
    local spName = sp:GetFName():ToString()
    local ok, ai = pcall(function()
        local home, homeRot = sp:K2_GetActorLocation(), sp:K2_GetActorRotation()
        -- (The behaviour scenario of the spawner the host's enemy came from - ours of the same name - if it has one.)
        local scen, src = sp.m_PhaseScenario, spawners.byName[id:match("^(.-)#%d+$") or ""]
        local srcScen = U.valid(src) and src.m_PhaseScenario or nil
        if U.valid(srcScen) then sp.m_PhaseScenario = srcScen end
        sp:K2_SetActorLocationAndRotation({ X = at.x, Y = at.y, Z = at.z }, { Pitch = 0, Yaw = at.yaw or 0, Roll = 0 },
            false, {}, true)
        sp:BPF_SetSpawningClass(cls)
        sp:BPF_WantsSpawn()
        local a = sp:BPF_GetSpawnedAI()
        sp:K2_SetActorLocationAndRotation(home, homeRot, false, {}, true)
        if U.valid(srcScen) and U.valid(scen) then sp.m_PhaseScenario = scen end
        return a
    end)
    U.tock("make copy (spawner)", t)
    if not ok then return nil, tostring(ai) end
    if not U.valid(ai) then return nil, "nothing sent out by " .. spName end
    if ai:GetClass():GetAddress() ~= cls:GetAddress() then
        return nil, "sent out a " .. ai:GetClass():GetFName():ToString()
    end
    known[ai:GetAddress()] = { id = id, actor = ai, made = true, foundAt = clock() }
    madeIds[id] = ai
    stats.made = (stats.made or 0) + 1
    U.log("enemies: the host has %s, this game doesn't: sent out by our spawner %s (%s)", id, spName, U.shortName(ai))
    return ai
end

local function spawnProxy(r, id)
    local now = clock()
    if now < (r.proxyRetryAt or 0) then return end
    local cls = r.class and loadClass(r.class)
    local at = r.snaps[#r.snaps]
    if not (cls and at) then
        -- Tried again a few times, a second apart: its class or first position may still be on the way (a handover
        -- empties the snapshots). (Was: given up at once - the enemy stayed invisible here for good.) Not every frame:
        -- looking up a class that isn't there costs ~35 ms.
        r.proxyTries = (r.proxyTries or 0) + 1
        r.proxyRetryAt = now + 1000
        if r.proxyTries >= 5 then r.proxyTried = true end
        U.log("enemies: no copy yet for the host's %s (%s), try %d", id, cls and "no position yet" or ("class " .. tostring(r.class)),
            r.proxyTries)
        return
    end
    r.proxyTried = true
    if F.activity == "arena" then
        local ai, why = makeCopy(r, id, cls, at)
        if ai then return end
        stats.makeFailed = (stats.makeFailed or 0) + 1
        U.log("enemies: no spawner could send out %s (%s): a stand-in", id, tostring(why))
    end
    local ok, actor = pcall(function()
        local gs = require("UEHelpers").GetGameplayStatics()
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = at.x, Y = at.y, Z = at.z },
                     Scale3D = { X = 1, Y = 1, Z = 1 } }
        local a = gs:BeginDeferredActorSpawnFromClass(U.world(), cls, xf, 1, nil)
        gs:FinishSpawningActor(a, xf)
        return a
    end)
    if not (ok and U.valid(actor)) then
        U.log("enemies: spawning a stand-in for %s failed: %s", id, tostring(actor))
        return
    end
    known[actor:GetAddress()] = { id = id, actor = actor, proxy = true }
    r.proxy = actor
    U.log("enemies: the host has %s, this game doesn't: stand-in %s", id, U.shortName(actor))
end

local function makeDormant(e)
    e.dormant = true
    pcall(function() e.actor.Controller.BrainComponent:StopLogic("TailCoop: not in the host's game") end)
    pcall(function() e.actor.m_AIComponent:BPF_ForgetEnemy() end)
    dropTickets(e.actor)
    A.makeDriven(e.actor)
    A.hideReal(e.actor, true)
    Gear.hideHeld(e.actor)
    pcall(function() e.actor:SetActorEnableCollision(false) end)
    outOfReach(e.actor)
    U.log("enemies: %s isn't in the host's game: put aside", e.id)
end

local function wake(e)
    e.dormant = nil
    bringBack(e.actor)
    pcall(function() e.actor:SetActorEnableCollision(true) end)
end

-- On the joiner, no enemy of ours runs its own AI during a session (the host's enemies decide): stopped as soon as
-- it's seen, and again whenever the game restarts it (the training room's behaviour switch, a reset...).
local function holdAI(e)
    pcall(function() e.actor.Controller.BrainComponent:StopLogic("TailCoop: the host's enemies decide") end)
    pcall(function() e.actor.m_AIComponent:BPF_ForgetEnemy() end)
    dropTickets(e.actor)
end

function E.restopAll()
    for _, e in pairs(known) do
        if U.valid(e.actor) and not mine(e.id) then holdAI(e) end
    end
end

-- Follower side, both games: enemies we don't own are taken over (hidden, AI off, a twin follows the owner). The
-- joiner also keeps its own copy of the host's roster (stand-ins / put aside).
-- Our enemy for a host id must be the same kind: arena waves pick a random variant per spawn, so this game's enemy
-- from the same spawner can be another one (its pose wouldn't fit, its twin would look wrong). Then it doesn't count
-- as the host's: a stand-in of the right class comes instead.
local function wrongKind(e, r)
    if e.proxy or (known[e.actor:GetAddress()] or {}).proxy or not (r and r.class and r.class ~= "") then return false end
    e.classPath = e.classPath or A.path(e.actor:GetClass()) or ""
    return e.classPath ~= r.class
end

local function joinerTick()
    local list = liveScan()
    local byId = {}
    local joiner = S.role == "join"
    for _, e in ipairs(list) do
        if joiner and not e.held and not mine(e.id) then
            e.held = true
            holdAI(e)
        end
        -- The level's own enemy for an id one of our spawners already made a copy for: put aside (it still dies with
        -- the host's enemy, onDead, so our wave director counts it).
        if joiner and e.extra then
            if not e.dormant then makeDormant(e) end
            goto nextEntry
        end
        -- Ours is another variant than the host's: out of the roster for good - also once this game runs that enemy.
        -- (Was: only while the host ran it. Handed to us, ours counted again, replaced the stand-in - which was
        -- removed - and nothing ran the enemy: invisible here, while the host took it back and handed it over every
        -- 3 s, restarting its AI each time - "enemies not visible hitting my partner", "violently spins in place".)
        if joiner and (e.wrongKind or wrongKind(e, remote[e.id])) then
            if not e.wrongKind then
                e.wrongKind = true
                U.log("enemies: our %s is a %s, the host's a %s: ours put aside, a stand-in comes", e.id,
                    tostring(e.classPath):match("([^%.]+)$"), tostring(remote[e.id].class):match("([^%.]+)$"))
                if not e.dormant then makeDormant(e) end
                -- We were running it with ours: the host takes it back until a stand-in is here.
                if mine(e.id) then handovers[e.id] = { to = "host", since = 0 } end
            end
            goto nextEntry
        end
        do
            -- A stand-in and one of ours with the same id (our game spawned it a bit later): ours wins.
            local prev = byId[e.id]
            if not prev or prev.proxy or (known[prev.actor:GetAddress()] or {}).proxy then byId[e.id] = e end
        end
        ::nextEntry::
    end
    local now = clock()
    connectedAt = connectedAt or now
    for id, r in pairs(remote) do
        local e = byId[id]
        if e and r.proxy and U.valid(r.proxy) and e.actor:GetAddress() ~= r.proxy:GetAddress() then
            known[r.proxy:GetAddress()] = nil
            retire(r.proxy)
            U.log("enemies: this game now has %s too: stand-in removed", id)
            r.proxy, r.controlled = nil, false
        end
    end
    for id, r in pairs(remote) do
        local e = byId[id]
        local fresh = r.lastHeard and now - r.lastHeard < STALE_MS
        r.firstHeard = r.firstHeard or now
        if mine(id) then goto continue end
        -- Host: an enemy the joiner ran has gone quiet for 3 s (the joiner left the fight: another map, a menu, a
        -- crash): ours again, AI running here.
        if not joiner and r.controlled and U.valid(r.actor) and r.lastHeard and now - r.lastHeard > 3000
            and not deadIds[id] then
            destroyTwin(r)
            local c = r.actor
            pcall(function()
                c:SetActorHiddenInGame(false)
                c.Mesh:SetVisibility(true, true)
                c:SetActorEnableCollision(true)
                c.CharacterMovement:SetMovementMode(1, 0)
                c.Controller.BrainComponent:RestartLogic()
            end)
            allowTickets(c)
            aimAtMe(c)
            for _, w in ipairs(Gear.heldWeapons(c)) do pcall(function() w:SetActorHiddenInGame(false) end) end
            r.controlled, owner[id] = false, "host"
            U.log("enemies: the joiner's %s went quiet: ours again", id)
            goto continue
        end
        -- (Never again for a dead one whose copy went: it would come back for the 2 s the last reports stay fresh.)
        if e and fresh and (not r.controlled or r.actor ~= e.actor) and not (deadIds[id] and r.deadRemoved) then
            if e.dormant then wake(e) end
            takeControl(r, e.actor)
        end
        -- (Arena challenges start together on both: their waves get stand-ins sooner - a wave spawner's enemy at once,
        -- our own wave director is off: no enemy of ours to wait for. It came a second behind the host's.)
        if joiner and not e and fresh and not r.proxyTried and not deadIds[id] then
            r.proxyAfter = r.proxyAfter or (F.activity == "arena" and (waveId(id) and 150 or 800) or PROXY_AFTER_MS)
            if now - r.firstHeard > r.proxyAfter then spawnProxy(r, id) end
        end
        -- Dead in the owner's game and no longer reported (its owner stops 3 s after the death): its twin goes, here
        -- on the host too. (Was: kept on the host - once the pose stream stopped, the twin went back to its own idle
        -- animation and a dead enemy stood up again on the host's screen only: a lifeless "ghost" no hit could reach.)
        if r.controlled and deadIds[id] and r.lastHeard and now - r.lastHeard > 400 and r.twin then
            destroyTwin(r)
            r.controlled, r.deadRemoved = false, true
            if r.proxy and U.valid(r.proxy) then
                known[r.proxy:GetAddress()] = nil
                retire(r.proxy)
                r.proxy = nil
            end
            U.log("enemies: %s is dead and no longer reported: its copy removed", id)
        end
        if r.controlled and (not U.valid(r.actor) or not fresh) and (joiner or not U.valid(r.actor)) then
            -- Gone from the host (or from here): drop the twin; a stand-in goes, an enemy of ours is put aside.
            destroyTwin(r)
            r.controlled = false
            if r.proxy and U.valid(r.proxy) then
                known[r.proxy:GetAddress()] = nil
                retire(r.proxy)
                U.log("enemies: the host's %s is gone: stand-in removed", id)
            elseif e and not e.dormant and not deadIds[id] then
                makeDormant(e)
            end
            r.proxy, r.proxyTried, r.proxyTries, r.proxyRetryAt = nil, nil, nil, nil
        end
        ::continue::
    end
    for _, e in ipairs(list) do
        local r = remote[e.id]
        -- Ours to run, or reported by the partner who runs it: it exists in the shared fight.
        local exists = mine(e.id) or (r and r.lastHeard and now - r.lastHeard < STALE_MS)
        -- (Not one that just appeared - the host's report of it may be on its way - nor a body: the game clears it.)
        -- (U.valid again: a stand-in removed a few lines up is still in this list.)
        if joiner and not exists and not e.dormant and not e.proxy and U.valid(e.actor)
            and not (known[e.actor:GetAddress()] or {}).proxy
            and now - connectedAt > DORMANT_AFTER_MS and now - (e.foundAt or 0) > 2000 and not deadIds[e.id] then
            makeDormant(e)
        end
    end
    local pc = U.playerController()
    local me = pc and U.valid(pc.Pawn) and pc.Pawn or nil
    -- Ours put aside (not in the host's game / another variant): their AI stays stopped too (see benchIfFighting).
    for _, e in ipairs(list) do
        if (e.dormant or e.wrongKind) and U.valid(e.actor) and now - (e.benchAt or 0) >= 1000 then
            e.benchAt = now
            outOfReach(e.actor)  -- (again if the game moved it back: respawn logic, a reset)
            local okB, running = pcall(function() return e.actor.Controller.BrainComponent:IsRunning() end)
            if okB and running then
                pcall(function() e.actor.Controller.BrainComponent:StopLogic("TailCoop: put aside") end)
                dropTickets(e.actor)
                stats.restopped = (stats.restopped or 0) + 1
                if stats.restopped <= 20 then U.log("enemies: the game started our put-aside %s's AI again: stopped", e.id) end
            end
        end
    end
    for id, r in pairs(remote) do
        local e = byId[id]
        local c = r.controlled and U.valid(r.actor) and r.actor or nil
        if c and me and now - (r.benchAt or 0) >= 1000 then
            r.benchAt = now
            benchIfFighting(c, me)
        end
        if r.parked and r.parked[1] and now - (r.parkCheckAt or 0) >= 1000 and U.valid(r.parked[1]) then
            r.parkCheckAt = now
            outOfReach(r.parked[1])
        end
        if c then
            matchHost(r, c)
            -- Our hits reach the host's enemy as real hits (sendOurHits), so the host's health is the truth: our copy
            -- adopts it, after a moment's grace when our own hit just took some off (no flicker back up).
            -- Except what a synchronized move of our player's takes (a takedown, a grab): those aren't hits we send. A
            -- takedown here killed our copy while the owner's enemy lived on, and the copy was brought back to life
            -- from the owner's health - a dead character Sifu had done with: given to this game next, it was frozen
            -- out of sight, the wave never ended (user: "killed all the enemies, stuck at wave 3, no enemy"; lab: a
            -- takedown on the hidden copy took it to 0, back to the owner's health a second later). Its damage goes to
            -- the owner instead, and a copy dead here is never revived: the owner's enemy dies too ("ekill").
            local h = health(c)
            if h and r.lastLocalHealth and h < r.lastLocalHealth - 0.01 then
                stats.damageSent = stats.damageSent + 1
                r.lastDamageAt = now
                if h > 0 and inSyncMove(c) then
                    N.send(true, "edmg", id, string.format("%.1f", r.lastLocalHealth - h))
                    U.log("enemies: our player's move on %s took %.0f here: sent to its owner", id, r.lastLocalHealth - h)
                end
            end
            if h and h <= 0 and not deadIds[id] and now - (r.killSentAt or -1e9) > 2000 then
                r.killSentAt = now
                N.send(true, "ekill", id)
                U.log("enemies: our player finished %s here (a takedown or finisher on its copy): the %s's dies too", id,
                    ownerOf(id) == "host" and "host" or "joiner")
            end
            if r.health and r.health > 0 and h and h > 0 and (not r.lastDamageAt or now - r.lastDamageAt > 600)
                and math.abs(r.health - h) > 0.5 then
                pcall(function() c.m_HealthComponent:BPF_ServerSetHealth(r.health) end)
                h = health(c)
            end
            r.lastLocalHealth = h
        end
    end
end

-- Every frame: place the real enemy (our hit target) and its twin from the host's snapshots; the twin's walk/run/idle
-- follows that motion. Sifu turns the real one visible again at times, so it's re-hidden here.
-- The hidden real enemy's own actions (its AI is off: only reactions to our hits) are read every frame for a moment
-- after one of our hits lands on it, otherwise 10 times a second.
local REACT_WINDOW_MS, IDLE_READ_MS = 1500, 100
local function placeOne(r, c, at, now, renderT)
    -- The hidden real enemy is only a hit target: placed 30 times a second (the visible twin every frame). (Not a
    -- dead one's stand-in: out of reach until it's retired, see onDead.)
    if not r.copyOut and now - (r.placedAt or 0) >= 33 then
        r.placedAt = now
        r.realPlace = r.realPlace or {}
        A.place(c, r.realPlace, at.x, at.y, at.z, at.yaw, now)
    end
    -- Sifu turns it visible again at times: checked 10 times a second, every part every 0.5 s.
    local full = now - (r.hiddenAt or 0) > 500
    if full then r.hiddenAt = now end
    if r.twin and U.valid(r.twin) then
        if full or now - (r.hideCheckAt or 0) >= 100 then
            r.hideCheckAt = now
            A.hideReal(c, full)
        end
        if full then Gear.hideHeld(c) end
        local tg = U.tick()
        Gear.apply(r.twin, r.motion, r.id)
        U.tock("twin gear apply", tg)
        local ev = nil
        if r.realWatcher and (now - (r.ourHitAt or -1e9) < REACT_WINDOW_MS or now - (r.realReadAt or 0) >= IDLE_READ_MS) then
            r.realReadAt = now
            local tw = U.tick()
            ev = r.realWatcher:update(c, now)
            U.tock("hidden enemy action read", tw)
        end
        do
                    -- (Reactions only: an attack here would be the hidden copy's own AI, started again by the game -
                    -- benchIfFighting stops it; the owner's pose shows what the enemy really does.)
                    if ev and ev.kind == "start" and ev.path and now >= (r.reactFrom or 0)
                        and not require("tc_turns").isAttackPath(ev.path) then
                        local asset = A.sequence(ev.path)
                        if asset then
                            -- Shown at once (our hit lands now), not ~RTT + 100 ms later through the host's pose:
                            -- the twin leaves the pose stream for the length of this reaction.
                            Pose.release(r.twin, r.motion)
                            A.copyAction(r.twin, r.motion, asset, ev.rate, A.startTime(asset, ev.cursor, ev.start, 0, ev.rate),
                                ev.mirror, now)
                            r.localUntil = r.motion.actionUntil
                            -- The host's enemy will play its reaction a moment later; don't restart it then.
                            r.localReactionAt = now
                            stats.localReactions = (stats.localReactions or 0) + 1
                            if stats.localReactions <= 30 then
                                U.log("enemies: our hit on %s -> %s", r.id or "?", ev.path)
                            end
                        end
                    end
                    local td = U.tick()
                    A.drive(r.twin, r.motion, at.x, at.y, at.z, at.yaw, now)
                    U.tock("twin drive", td)
                    local driven = false
                    if now >= (r.localUntil or 0) then
                        local tp = U.tick()
                        local from = otherRole()
                        if r.poseFrom ~= from then r.poseKey, r.poseFrom = r.id .. "@" .. from, from end
                        driven = Pose.apply(r.twin, r.motion, r.poseKey, renderT)
                        TL.noteShown("enemy", driven and r.motion.poseAge or (renderT - r.snaps[#r.snaps].t))
                        U.tock("twin pose apply", tp)
                    end
                    -- (A dead one keeps its last pose: back in its idle it would stand up again.)
                    if not driven and not deadIds[r.id] then
                        A.copyLocomotion(r.twin, r.motion, r.stance ~= 0, now, r.quadrant)
                    end
        end
    end
end

local function joinerPlaceTick()
    local now = clock()
    local renderT = nil
    for _, r in pairs(remote) do
        local c = r.controlled and U.valid(r.actor) and r.actor or nil
        if c then
            renderT = renderT or TL.renderClock(now)
            local at = sample(r, renderT)
            if at then
                local ok, err = pcall(placeOne, r, c, at, now, renderT)
                if not ok and not r.animError then
                    r.animError = true
                    U.log("enemies: animating %s failed: %s", U.shortName(c), tostring(err))
                end
            end
        end
    end
end

-- Session over: our enemies become ours again (visible, AI running), twins go away.
local function releaseAll()
    for _, r in pairs(remote) do
        destroyTwin(r)
        local c = r.controlled and U.valid(r.actor) and r.actor or nil
        if c then
            pcall(function()
                c:SetActorHiddenInGame(false)
                c.Mesh:SetVisibility(true, true)
                c.CharacterMovement:SetMovementMode(1, 0)
                c.Controller.BrainComponent:RestartLogic()
            end)
            allowTickets(c)
            aimAtMe(c)
            U.log("enemies: %s released (AI running again)", U.shortName(c))
        end
        r.controlled = false
    end
    for addr, e in pairs(known) do
        if e.proxy then
            retire(e.actor)
            known[addr] = nil
        elseif e.dormant and U.valid(e.actor) then
            -- Put aside during the session: ours again.
            pcall(function()
                e.actor:SetActorHiddenInGame(false)
                e.actor.Mesh:SetVisibility(true, true)
                e.actor:SetActorEnableCollision(true)
                e.actor.CharacterMovement:SetMovementMode(1, 0)
                e.actor.Controller.BrainComponent:RestartLogic()
            end)
            bringBack(e.actor)
            allowTickets(e.actor)
            aimAtMe(e.actor)
            for _, w in ipairs(Gear.heldWeapons(e.actor)) do pcall(function() w:SetActorHiddenInGame(false) end) end
            e.dormant = nil
            U.log("enemies: %s back (session over)", e.id)
        elseif e.held and U.valid(e.actor) then
            pcall(function() e.actor.Controller.BrainComponent:RestartLogic() end)
            allowTickets(e.actor)
            aimAtMe(e.actor)
        elseif U.valid(e.actor) and e.turnGate ~= nil then
            allowTickets(e.actor)  -- one of ours tc_turns held back
        end
        e.held = nil
    end
    remote, connectedAt, owner = {}, nil, {}
end
E.releaseAll = releaseAll

local function onAction(f)
    if not mine(f[1]) then actNow[f[1]] = { path = f[2], at = clock() } end
    local r = remote[f[1]]
    local twin = r and r.controlled and r.twin and U.valid(r.twin) and r.twin or nil
    if not twin then return end
    if r.motion and r.motion.poseDriven then
        stats.actions = stats.actions + 1  -- shown by the exact pose stream already
        return
    end
    local asset = require("tc_moves").resolve(f[2])
    if not asset then
        U.log("enemies: animation not found %s", tostring(f[2]))
        return
    end
    local now = clock()
    -- The host's reaction to our own hit (its direction can differ slightly) while ours already shows: skip it, a
    -- second start would make the reaction stutter.
    local isReaction = f[2]:find("HitReaction", 1, true) or f[2]:find("hitted", 1, true)
    if isReaction and r.localReactionAt and now - r.localReactionAt < 700 then
        r.localReactionAt = nil
        stats.echoes = (stats.echoes or 0) + 1
        return
    end
    local P = require("tc_presence")
    local rate = tonumber(f[4]) or 1
    local startAt = A.startTime(asset, tonumber(f[6]), tonumber(f[5]), P.oneWayDelayMs(tonumber(f[7])), rate)
    A.copyAction(twin, r.motion, asset, rate, startAt, f[3] == "1", now)
    stats.actions = stats.actions + 1
    if stats.actions <= 40 then
        U.log("enemies: host's %s plays %s (rate %.2f, from %.2fs)", f[1], f[2]:match("[^/]+$") or f[2], rate, startAt)
    end
end

local function onActionEnd(f)
    if not mine(f[1]) then actNow[f[1]] = nil end
    local r = remote[f[1]]
    if r and r.controlled and r.motion then A.copyActionEnd(r.motion) end
end

-- Wiring -------------------------------------------------------------------------------------------------

-- Handover ---------------------------------------------------------------------------------------------------
-- The current owner hands an enemy over once it's between actions (no attack/reaction running for 300 ms, or after
-- 3 s at the latest): it becomes a follower here and sends "eown|id|newOwner|x|y|z|yaw|health"; the new owner's
-- copy steps in at exactly that state with its AI running, aimed at the player it was given to fight.

-- Our enemy for an id (not one of another kind than the host's: its stand-in is the one).
local function entryFor(id)
    for _, e in ipairs(scan()) do
        if e.id == id and U.valid(e.actor) and not e.wrongKind
            and not (S.role == "join" and wrongKind(e, remote[id])) then
            return e
        end
    end
    return nil
end

local function aimAt(actor, who)
    local target = who == S.role and (U.playerController() and U.playerController().Pawn)
        or require("tc_presence").puppetActor()
    if U.valid(target) then
        pcall(function() actor.m_AIComponent:BPF_ForceEnemy(target, 3) end)  -- EGlobalBehaviors::Alerted
    end
end

local function becomeOwner(id, f)
    local t0 = U.tick()
    local e = entryFor(id)
    -- A stand-in (spawned here for a host enemy this game didn't have) can't fight: Sifu never takes it into combat,
    -- whatever it's told (combat role None). Given one to run, the joiner kept it standing idle for minutes - a
    -- lifeless "ghost" on both screens (lab ArenaFight -Swap). The host keeps those enemies: back at once, for good
    -- ("-" instead of a position); our copy goes on following the host's.
    if e and S.role == "join" and (e.proxy or (known[e.actor:GetAddress()] or {}).proxy) then
        owner[id] = "host"
        N.send(true, "eown", id, "host", "-", "", "", "", "", targetOf[id] or S.role)
        U.log("enemies: given %s, but ours is a stand-in (it can't fight): the host keeps it", id)
        return
    end
    -- Our copy dead here (our player finished it: its owner was told, "ekill") or inside a synchronized move (our
    -- player's takedown or grab on it): run from here now, it came back to life wherever the move left it - once frozen
    -- out of sight for the rest of the fight. Back to the partner until the move is over. (Not when the partner is
    -- giving it back - no position: then it's ours whatever its state.)
    if e and f[3] ~= "" and f[3] ~= "-" then
        local h = health(e.actor)
        local dead = h and h <= 0
        if dead or inSyncMove(e.actor) then
            owner[id] = otherRole()
            busyUntil[id] = clock() + 1500
            N.send(true, "eown", id, otherRole(), "", "", "", "", "", targetOf[id] or S.role)
            U.log("enemies: given %s, but our copy is %s: back to the %s", id,
                dead and "dead here" or "in a takedown or grab", otherRole() == "host" and "host" or "joiner")
            return
        end
    end
    owner[id] = S.role
    local r = remote[id]
    if r then
        parkTwin(r)  -- shown again if the enemy goes back to the partner
        r.controlled, r.snaps = false, {}
    end
    if not e then
        -- Nothing here to run it with: straight back to the partner, who keeps it a while (onOwn: "refused").
        -- (Unless the partner just gave it back for the same reason: then it's gone from both - stays here.)
        if f[3] ~= "" and f[3] ~= "-" then
            owner[id] = otherRole()
            N.send(true, "eown", id, otherRole(), "", "", "", "", "", targetOf[id] or S.role)
        end
        U.log("enemies: given %s, but this game has no copy of it%s", id,
            (f[3] ~= "" and f[3] ~= "-") and (": back to the " .. (otherRole() == "host" and "host" or "joiner")) or "")
        return
    end
    local c = e.actor
    -- One we had put aside: back down from out of reach, in the fight again.
    if bringBack(c) then e.dormant = nil end
    pcall(function()
        c:SetActorHiddenInGame(false)
        c.Mesh:SetVisibility(true, true)
        c:SetActorEnableCollision(true)
        -- (No position: the partner had no copy to take it from - ours stays where it is.)
        if tonumber(f[3]) then
            c:K2_SetActorLocationAndRotation({ X = tonumber(f[3]), Y = tonumber(f[4]), Z = tonumber(f[5]) },
                { Pitch = 0, Yaw = tonumber(f[6]) or 0, Roll = 0 }, false, {}, true)
        end
        local h = tonumber(f[7])
        if h and h >= 0 then c.m_HealthComponent:BPF_ServerSetHealth(h) end
        c.CharacterMovement:SetMovementMode(1, 0)
        c.Controller.BrainComponent:RestartLogic()
    end)
    allowTickets(c)
    for _, w in ipairs(Gear.heldWeapons(c)) do pcall(function() w:SetActorHiddenInGame(false) end) end
    e.held = nil
    aimAt(c, targetOf[id] or S.role)
    U.tock("handover: take it", t0)
    U.log("enemies: %s is ours now (AI here, fighting %s)", id, (targetOf[id] or S.role) == S.role and "us" or "the partner")
end

local function handOver(id, to, now)
    local t0 = U.tick()
    local e = entryFor(id)
    local l, yaw, h = { X = 0, Y = 0, Z = 0 }, 0, -1
    if e then
        pcall(function()
            l, yaw = e.actor:K2_GetActorLocation(), e.actor:K2_GetActorRotation().Yaw
            h = health(e.actor) or -1
        end)
    end
    owner[id] = to
    -- (With whom it fights: the new owner's own idea of that could be old - it fought someone else last time.)
    -- No copy of ours to say where it is: no position (the new owner's copy stays where it is).
    if e then
        N.send(true, "eown", id, to, string.format("%.1f", l.X), string.format("%.1f", l.Y), string.format("%.1f", l.Z),
            string.format("%.1f", yaw), string.format("%.1f", h), targetOf[id] or to)
    else
        N.send(true, "eown", id, to, "", "", "", "", "", targetOf[id] or to)
    end
    if e then
        local r = remote[id] or { snaps = {}, id = id }
        remote[id] = r
        r.snaps, r.lastHeard, r.firstHeard = {}, now, now
        takeControl(r, e.actor)
    end
    U.tock("handover: give it", t0)
    U.log("enemies: %s handed over to the %s", id, to == "host" and "host" or "joiner")
end

-- Quiet = no action started in the last 300 ms and none running (the "last action" source has no end: ignored).
local function quiet(id, now)
    local w = watchers[id]
    local last = lastActions[id]
    return (not w or not w.current or w.current == "last") and (not last or now - last.at > 300)
end

-- Not in the middle of a synchronized move either (our player's takedown or grab on it, here): handed over then, it
-- froze where the move had it (the 3 s limit cut takedowns short). Those wait up to SYNC_WAIT_MS.
local SYNC_WAIT_MS = 15000
local function handoverTick(now)
    for id, h in pairs(handovers) do
        if not mine(id) or deadIds[id] then
            handovers[id] = nil
        elseif quiet(id, now) or now - h.since > 3000 then
            local e = now - h.since < SYNC_WAIT_MS and entryFor(id) or nil
            if not (e and inSyncMove(e.actor)) then
                handovers[id] = nil
                handOver(id, h.to, now)
            elseif not h.waitLogged then
                h.waitLogged = true
                U.log("enemies: %s goes to the %s once the takedown / grab on it is over", id,
                    h.to == "host" and "host" or "joiner")
            end
        end
    end
end

-- The owner's enemy died: kill our copy (if it isn't dead here already).
local function onDead(f)
    local id = f[1]
    deadIds[id] = deadIds[id] or clock()
    handovers[id], requested[id] = nil, nil
    local r = remote[id]
    -- Its body here (the twin: to Sifu a live character) is no target any more: health 0 written straight in, no
    -- death of its own (the owner's pose stream shows that one). Left alive, our attacks went for the body - punching
    -- a corpse's spot, turning to it (lab arenakill: with the stand-in fix below, every remaining aim at a dead enemy
    -- was its twin, 1-4 m away).
    if r and r.twin and U.valid(r.twin) then pcall(function() r.twin.m_HealthComponent.m_fHealth = 0 end) end
    -- Our own enemy for this id put aside (another variant than the host's): it dies too, so this game's wave
    -- director counts the death like the host's does.
    local ownWaveDied = false
    for _, e in ipairs(liveScan()) do
        if (e.id == id or e.id == id .. "+") and (e.dormant or e.wrongKind) then
            local h = health(e.actor)
            if h and h > 0 then pcall(function() e.actor:ServerSuicide(false) end) end
            ownWaveDied = ownWaveDied or e.fromWave
        end
    end
    -- Our copy is one of our own wave enemies: its death below counts.
    do
        local k = r and r.controlled and U.valid(r.actor) and known[r.actor:GetAddress()]
        if k and k.fromWave then ownWaveDied = true end
    end
    if not ownWaveDied then keepWaveStep(id) end
    -- A stand-in isn't killed: a dead character goes into the arena's pool and the challenge sends it out again
    -- as a new enemy - one only this game had, never synced (lab: a "dead" stand-in walked about at full health).
    -- Its twin shows the death; the stand-in is retired once the host stops reporting the enemy - but it goes out of
    -- reach at once: alive and hidden under the body for the 3 s the owner still reports the death, it stayed the
    -- target of our attacks (Sifu's auto-aim), and the player turned in place punching the body's spot (user: "still
    -- spins sometimes", right after a kill; lab arenakill: 22% of the joiner's aim checks went to such a copy).
    if r and r.proxy and U.valid(r.proxy) and r.actor == r.proxy then
        r.copyOut = true
        pcall(function() r.proxy:SetActorEnableCollision(false) end)
        outOfReach(r.proxy)
        U.log("enemies: the partner's %s died: its stand-in here is out of reach (retired with it later)", id)
        return
    end
    local c = r and r.controlled and U.valid(r.actor) and r.actor or nil
    if not c then
        local e = entryFor(id)
        c = e and e.actor
    end
    if not c then
        U.log("enemies: the partner's %s died (no copy here)", id)
        return
    end
    local h = health(c)
    local ok, err = true, nil
    -- What our copy held (hidden with it while the partner ran the enemy): dropped as it dies, it would stay hidden -
    -- and fall through the floor if its collision was off (a weapon hidden as the partner's).
    local held = Gear.heldWeapons(c)
    local from = nil
    pcall(function()
        local l = c:K2_GetActorLocation()
        from = { x = l.X, y = l.Y, z = l.Z }
    end)
    for _, w in ipairs(held) do pcall(function() w:SetActorEnableCollision(true) end) end
    if h and h > 0 then ok, err = pcall(function() c:ServerSuicide(false) end) end
    U.log("enemies: the partner's %s died: our copy %s", id,
        not (h and h > 0) and "was dead already" or (ok and "killed" or ("NOT killed: " .. tostring(err))))
    if #held > 0 then
        -- Shown and usable once it has let go of them (the partner's game says where theirs came to rest, tc_gear;
        -- one only this game has - spawned with our copy - lies where ours dropped it).
        local tries = 0
        U.poll("dropped weapons", 250, function()
            tries = tries + 1
            local left = 0
            for i, w in pairs(held) do
                if not U.valid(w) then
                    held[i] = nil
                else
                    local okP, parent = pcall(function() return w:GetAttachParentActor() end)
                    if okP and parent ~= nil and U.valid(parent) then
                        left = left + 1
                    else
                        pcall(function()
                            w:SetActorHiddenInGame(false)
                            w:SetActorEnableCollision(true)
                        end)
                        Gear.rescue(w, from)
                        Gear.setUsable(w, true)
                        held[i] = nil
                        U.log("enemies: %s dropped %s here as it died: shown, can be picked up", id, U.shortName(w))
                    end
                end
            end
            return left == 0 or tries >= 20
        end)
    end
end

-- The partner's player finished one of our enemies on their copy of it (a takedown or finisher there): ours dies too,
-- the game's own way (the arena's wave director counts it; "edead" goes back as for any death).
local function onKill(f)
    local id = f[1]
    if deadIds[id] then return end
    if not mine(id) then
        U.log("enemies: the partner finished %s, but this game doesn't run it", id)
        return
    end
    local e = entryFor(id)
    if not e then
        U.log("enemies: the partner finished %s, but this game has no copy of it", id)
        return
    end
    local h = health(e.actor)
    local ok, err = true, nil
    if h and h > 0 then ok, err = pcall(function() e.actor:ServerSuicide(false) end) end
    U.log("enemies: the partner's player finished %s there: ours %s", id,
        not (h and h > 0) and "was dead already" or (ok and "killed" or ("NOT killed: " .. tostring(err))))
end

-- Focus -----------------------------------------------------------------------------------------------------------
-- Sifu's Focus (F) copies the pose of the enemy whose vital point is aimed at onto its vital-points effect
-- (BP_FightingPlayer UpdatePoseVitalPointsFX_PO: PoseableMesh:CopyPoseFromSkeletalComponent(FocusCurrentActorSelected
-- .Mesh)). A twin's mesh follows a master pose (tc_pose): it has no pose of its own, and the copy read an empty bone
-- array - the game crashed the moment the player focused on an enemy the partner runs (user: "when I pressed F the
-- game crashed"; lab crash: read of address 0 under CopyPoseFromSkeletalComponent, via that function). The focus
-- target is our hidden copy of the enemy instead: same place, its own pose, and what our player does to it goes to
-- the enemy's owner. Anything else of ours following a master pose (the partner's character, put-away twins) is never
-- copied from: the function sees our own player for that one call.
local FOCUS_SET = "SetFocusCurrentActorSelected"
local FOCUS_FX = "UpdatePoseVitalPointsFX_PO"

-- For an actor Sifu's focus picked: our hidden copy behind it (a twin), false (one of ours with no pose of its own,
-- nothing to put instead), or nil (not one of ours: left alone).
local function focusSubstitute(actor)
    if not U.valid(actor) then return nil end
    local addr = actor:GetAddress()
    for _, r in pairs(remote) do
        if r.twin and U.valid(r.twin) and r.twin:GetAddress() == addr then
            return r.controlled and U.valid(r.actor) and r.actor or false
        end
        if r.parked and r.parked[1] and U.valid(r.parked[1]) and r.parked[1]:GetAddress() == addr then return false end
    end
    local p = require("tc_presence").puppetActor()
    if (U.valid(p) and p:GetAddress() == addr) or retiredActors[addr] then return false end
    return nil
end

local focusStats = { swapped = 0, blocked = 0 }
local function noteFocus(kind, actor)
    focusStats[kind] = focusStats[kind] + 1
    if focusStats[kind] <= 10 then
        U.log("enemies: focus on %s: %s", U.shortName(actor),
            kind == "swapped" and "our hidden copy of it is the target (its twin has no pose of its own)"
            or "not ours to copy a pose from: skipped")
    end
end

local focusSaved = nil  -- the selection put back after UpdatePoseVitalPointsFX_PO (one of ours with nothing instead)
local function onFocusSet(ctx, actorParam)
    local okA, a = pcall(function() return actorParam:get() end)
    if not okA then return end
    local sub = focusSubstitute(a)
    if sub then
        if pcall(function() actorParam:set(sub) end) then noteFocus("swapped", a) end
    end
end

local function onFocusFxPre(ctx)
    focusSaved = nil
    local self = ctx:get()
    local okS, sel = pcall(function() return self.FocusCurrentActorSelected end)
    if not (okS and sel and U.valid(sel)) then return end
    local sub = focusSubstitute(sel)
    if sub then
        self.FocusCurrentActorSelected = sub
        noteFocus("swapped", sel)
    elseif sub == false then
        -- (Our own player, for this call only: a mesh with its own pose. Put back right after.)
        focusSaved = sel
        self.FocusCurrentActorSelected = self
        noteFocus("blocked", sel)
    end
end

local function onFocusFxPost(ctx)
    if not focusSaved then return end
    local saved = focusSaved
    focusSaved = nil
    pcall(function() ctx:get().FocusCurrentActorSelected = saved end)
end

-- Hooked from our player's own functions once one is in the world (its class loads with the first fight).
local focusHooked = {}
local function hookFocus()
    if focusHooked[FOCUS_SET] and focusHooked[FOCUS_FX] then return true end
    local pc = U.playerController()
    local pawn = pc and U.valid(pc.Pawn) and pc.Pawn or nil
    if not pawn then return false end
    for _, fnName in ipairs({ FOCUS_SET, FOCUS_FX }) do
        if not focusHooked[fnName] then
            local okP, path = pcall(function() return pawn[fnName]:GetFullName():match("^%S+%s+(.+)$") end)
            if okP and path then
                local pre = fnName == FOCUS_SET and function(c, a) U.try("focus target", function() onFocusSet(c, a) end) end
                    or function(c) U.try("focus pose", function() onFocusFxPre(c) end) end
                local post = fnName == FOCUS_FX and function(c) U.try("focus pose", function() onFocusFxPost(c) end) end
                    or nil
                local ok, err = pcall(RegisterHook, path, pre, post)
                focusHooked[fnName] = ok
                if ok or not focusHooked[fnName .. " failed"] then
                    focusHooked[fnName .. " failed"] = not ok
                    U.log("enemies: focus guard on %s: %s", fnName, ok and "hooked" or tostring(err))
                end
            end
        end
    end
    return focusHooked[FOCUS_SET] and focusHooked[FOCUS_FX]
end

-- Safety net ------------------------------------------------------------------------------------------------------
-- Whatever left it so, an enemy nobody can reach can't be finished, and its Arena wave never ends. One this game runs
-- that is far above or below both players (more than STUCK_Z) for OUT_MS, or - in an Arena challenge - alive and in
-- the fight before, but neither moving nor acting for FROZEN_MS, is put back: its actions cancelled, shown, solid,
-- walking, on its last good spot (where it last moved at the players' level), its AI restarted. Still stuck RETRY_MS
-- after a second try, it's killed the game's own way: the wave counts it and goes on.
-- (Watched in both games whoever runs it - our hidden copy follows the partner's - so a stuck enemy passed back and
-- forth between the games is still seen as stuck.)
local STUCK_Z, OUT_MS, FROZEN_MS, RETRY_MS = 600, 3000, 40000, 15000
local stuck = {}   -- id -> { x, y, at (last moved), act (last action seen), engaged, good, outSince, fixes, fixedAt }

local function playerZs()
    local zs = {}
    pcall(function() zs[#zs + 1] = U.playerController().Pawn:K2_GetActorLocation().Z end)
    local p = require("tc_presence").puppetActor()
    if U.valid(p) then pcall(function() zs[#zs + 1] = p:K2_GetActorLocation().Z end) end
    return zs
end

local function unstick(e, w, why)
    local c = e.actor
    pcall(function() c:BPF_GetOrderComponent():BPF_CancelAllOrders() end)
    pcall(function()
        c:SetActorHiddenInGame(false)
        c.Mesh:SetVisibility(true, true)
        c:SetActorEnableCollision(true)
    end)
    if w.good then
        pcall(function() c:K2_SetActorLocation({ X = w.good.x, Y = w.good.y, Z = w.good.z }, false, {}, true) end)
    end
    pcall(function()
        c.CharacterMovement:SetMovementMode(1, 0)
        c.Controller.BrainComponent:RestartLogic()
    end)
    allowTickets(c)
    aimAt(c, targetOf[e.id] or S.role)
    U.log("enemies: %s was %s: put back in the fight%s (try %d)", e.id, why,
        w.good and string.format(" at %.0f %.0f %.0f", w.good.x, w.good.y, w.good.z) or "", w.fixes)
end

local function stuckTick(now)
    -- (Our game paused, or our player down - Sifu holds the enemies still: nothing here moves, and that's fine.)
    local Pr = require("tc_presence")
    if Pr.isPaused(S.role) or Pr.isDown(S.role) then
        for _, w in pairs(stuck) do w.at, w.act, w.outSince = now, now, nil end
        return
    end
    local zs = playerZs()
    if #zs == 0 then return end
    local arena = F.activity == "arena"
    for _, e in ipairs(liveScan()) do
        local id = e.id
        if deadIds[id] or e.dormant or e.wrongKind or e.proxy then goto nextEnemy end
        do
            -- Where it is in this game: ours, or our hidden copy placed from the partner's snapshots.
            local c = mine(id) and e.actor or E.localActorFor(id)
            if not c then goto nextEnemy end
            local h = health(c)
            if not h or h <= 0 then goto nextEnemy end
            local okL, l = pcall(function() return c:K2_GetActorLocation() end)
            if not okL then goto nextEnemy end
            local w = stuck[id]
            if not w then
                w = { x = l.X, y = l.Y, at = now, act = now }
                stuck[id] = w
            end
            if (l.X - w.x) ^ 2 + (l.Y - w.y) ^ 2 > 50 * 50 then
                -- (Its first steps take it out of a spawn or an idle activity: in the fight from the next ones.)
                if w.moved then w.engaged = true end
                w.moved, w.x, w.y, w.at = true, l.X, l.Y, now
            end
            local a = actNow[id] or lastActions[id]
            if a and a.at > (w.actAt or 0) then w.actAt, w.act, w.engaged = a.at, now, true end
            local dz = math.huge
            for _, z in ipairs(zs) do dz = math.min(dz, math.abs(l.Z - z)) end
            if dz < 200 and now - w.at < 2000 then w.good = { x = l.X, y = l.Y, z = l.Z } end
            if w.fixes and now - w.fixedAt > 60000 then w.fixes = nil end  -- (fine for a minute since)
            if not mine(id) then goto nextEnemy end
            local why = nil
            -- (Not moving either: one walking about on another floor of the level is in reach.)
            if dz > STUCK_Z and now - w.at > OUT_MS then
                w.outSince = w.outSince or now
                if now - w.outSince > OUT_MS then
                    why = string.format("out of reach (%.0f m from the players' level)", dz / 100)
                end
            else
                w.outSince = nil
            end
            local still = now - math.max(w.at, w.act)
            if not why and arena and w.engaged and still > (w.fixes and RETRY_MS or FROZEN_MS) then
                why = string.format("frozen (no move or action for %.0f s)", still / 1000)
            end
            if why and now - (w.fixedAt or -1e9) > RETRY_MS then
                w.fixedAt = now
                if (w.fixes or 0) < 2 then
                    w.fixes = (w.fixes or 0) + 1
                    w.at, w.act, w.outSince = now, now, nil  -- (time to move again)
                    unstick(e, w, why)
                else
                    local ok, err = pcall(function() c:ServerSuicide(false) end)
                    U.log("enemies: %s still %s after being put back twice: %s so the fight goes on", id, why,
                        ok and "killed" or ("NOT killed (" .. tostring(err) .. ")"))
                end
            end
        end
        ::nextEnemy::
    end
end

function E.isDead(id) return deadIds[id] ~= nil end
function E.targetOf(id) return targetOf[id] end

-- Lab: what a character (by address) is to TailCoop here, or nil if it isn't one of ours.
function E.whatIs(addr)
    local k0 = known[addr]
    if k0 and mine(k0.id) and not (k0.dormant or k0.wrongKind) then
        return "running " .. k0.id .. (deadIds[k0.id] and " (dead)" or "")
    end
    for id, r in pairs(remote) do
        local dead = deadIds[id] and " (dead)" or ""
        if r.twin and U.valid(r.twin) and r.twin:GetAddress() == addr then
            return "twin of " .. id .. dead .. (r.controlled and "" or " (not following)")
        end
        if r.parked and r.parked[1] and U.valid(r.parked[1]) and r.parked[1]:GetAddress() == addr then
            return "parked twin of " .. id .. dead
        end
        -- (Only while it's following: once released, the arena pool may have sent the same character out again as
        -- another enemy - the roster below says what it is now.)
        if r.controlled and r.actor and U.valid(r.actor) and r.actor:GetAddress() == addr then
            return "hidden copy of " .. id .. dead
        end
    end
    local k = known[addr]
    if k then
        local dead = deadIds[k.id] and " (dead)" or ""
        if k.proxy then return "stand-in " .. k.id .. dead end
        if k.dormant then return "put aside " .. k.id .. dead end
        if k.wrongKind then return "other variant " .. k.id .. dead end
        return (mine(k.id) and "running " or "ours, partner runs it ") .. k.id .. dead
    end
    return nil
end

-- Our enemies whose AI runs here (ours to run, not put aside, not dead).
function E.running()
    local out = {}
    for _, e in ipairs(scan()) do
        if mine(e.id) and not (e.wrongKind or e.dormant or deadIds[e.id]) and U.valid(e.actor) then out[#out + 1] = e end
    end
    return out
end

-- Every live enemy on this screen and where it's shown: ours (AI running here) and the partner's (their twins).
-- { id, x, y, mine, actor (ours, or the hidden copy behind a twin) }
function E.shown()
    local out = {}
    for _, e in ipairs(scan()) do
        if mine(e.id) and not (e.wrongKind or e.dormant or deadIds[e.id]) and U.valid(e.actor) then
            local ok, l = pcall(function() return e.actor:K2_GetActorLocation() end)
            if ok then out[#out + 1] = { id = e.id, x = l.X, y = l.Y, mine = true, actor = e.actor } end
        end
    end
    for id, r in pairs(remote) do
        if r.controlled and r.twin and U.valid(r.twin) and U.valid(r.actor) and not deadIds[id] and not mine(id) then
            local ok, l = pcall(function() return r.twin:K2_GetActorLocation() end)
            if ok then out[#out + 1] = { id = id, x = l.X, y = l.Y, mine = false, actor = r.actor } end
        end
    end
    return out
end

-- Host (tc_aggro): enemy `id` should be run by `who` ("host"/"join") and fight `target`.
function E.assign(id, who, target)
    if deadIds[id] then return end
    if targetOf[id] ~= target then
        targetOf[id] = target
        if mine(id) then
            local e = entryFor(id)
            if e then aimAt(e.actor, target) end
        end
        -- The joiner always knows (it may run this enemy next, and tc_turns gates by target).
        N.send(true, "etarget", id, target)
    end
    -- The partner couldn't run it a moment ago: it stays here, fighting their character.
    if who ~= S.role and refused[id] and clock() - refused[id] < REFUSED_MS then who = S.role end
    if ownerOf(id) == who then
        handovers[id], requested[id] = nil, nil
        return
    end
    if mine(id) then
        handovers[id] = handovers[id] or { to = who, since = clock() }
    elseif requested[id] ~= who then
        if who == S.role and (busyUntil[id] or 0) > clock() then return end
        requested[id] = who
        N.send(true, "ereq", id, who)
    end
end

local function onOwn(f)
    local id, to = f[1], f[2]
    requested[id] = nil
    if f[8] == "host" or f[8] == "join" then targetOf[id] = f[8] end
    if to == S.role and (f[3] == "" or f[3] == "-") then
        refused[id] = f[3] == "-" and math.huge or clock()  -- "-": the partner can't run it at all
        handovers[id] = nil
    end
    if to == S.role then becomeOwner(id, f) else owner[id] = to end
end

local function onRequest(f)
    if mine(f[1]) and not deadIds[f[1]] then handovers[f[1]] = handovers[f[1]] or { to = f[2], since = clock() } end
end

local function onTarget(f)
    targetOf[f[1]] = f[2]
    if mine(f[1]) then
        local e = entryFor(f[1])
        if e then aimAt(e.actor, f[2]) end
    end
end

function E.start()
    N.on("e", onSnapshot)
    N.on("einfo", onInfo)
    N.on("eact", onAction)
    N.on("eactend", onActionEnd)
    N.on("edmg", onDamage)
    N.on("ehit", onPartnerHit)
    N.on("eown", onOwn)
    N.on("ereq", onRequest)
    N.on("etarget", onTarget)
    N.on("edead", function(f) U.onGameThread("enemy death", function() onDead(f) end) end)
    N.on("ekill", function(f) U.onGameThread("enemy finished by the partner", function() onKill(f) end) end)
    S.onChange(function()
        if not S.connected() then
            handovers, requested, targetOf, deadIds, refused, busyUntil, stuck = {}, {}, {}, {}, {}, {}, {}
        end
    end)
    -- A new world (another challenge, a retry): the same ids come back as new enemies, owned by the host again.
    F.onMapChange(function()
        owner, handovers, requested, targetOf, deadIds, refused = {}, {}, {}, {}, {}, {}
        busyUntil, stuck = {}, {}
        watchers, lastActions, lastPoseAt, gearStates, actNow = {}, {}, {}, {}, {}
        connectedAt = nil
    end)
    U.poll("enemies", SEND_MS, function()
        if not (S.connected() and F.activity) then return false end
        joinerTick()   -- the ones the partner owns (+ the joiner's roster); ours are sent from "enemy actions"
        return false
    end)
    U.poll("enemy actions", 10, function()
        if not (S.connected() and F.activity) then
            if next(remote) ~= nil and not S.connected() then releaseAll() end
            return false
        end
        local now = clock()
        local t = U.tick()
        hostActionTick()
        U.tock("owner tick", t)
        handoverTick(now)
        t = U.tick()
        joinerPlaceTick()
        U.tock("follower place+anim", t)
        t = U.tick()
        routeCaptures()
        U.tock("route captures", t)
        return false
    end)
    U.poll("enemies safety net", 1000, function()
        if S.connected() and F.activity then stuckTick(clock()) end
        return false
    end)
    -- (Hooks stay for the whole run: one try every 2 s until our player is in a fight.)
    U.poll("enemies focus guard", 2000, function()
        if not F.activity then return false end
        return hookFocus()
    end)
    U.poll("enemies stats", 20000, function()
        if S.connected() and F.activity then
            local n = 0
            for _ in pairs(known) do n = n + 1 end
            local where = ""
            for _, e in pairs(known) do
                -- (A pcall doesn't protect against a destroyed actor: reading it crashes the game. Check first.)
                if not U.valid(e.actor) then goto nextKnown end
                pcall(function()
                    local l, h = e.actor:K2_GetActorLocation(), health(e.actor)
                    local pc = U.playerController()
                    local me = pc.Pawn:K2_GetActorLocation()
                    where = string.format(" | %s at %.0f %.0f health %.0f, %.0f from me, dilation %.2f animRate %.2f",
                        e.id, l.X, l.Y, h or -1, math.sqrt((l.X - me.X) ^ 2 + (l.Y - me.Y) ^ 2),
                        e.actor.CustomTimeDilation, e.actor.Mesh.GlobalAnimRateScale)
                    local r = remote[e.id]
                    if r and r.twin and U.valid(r.twin) then
                        where = where .. string.format(" | twin dilation %.2f animRate %.2f playRate %.2f",
                            r.twin.CustomTimeDilation, r.twin.Mesh.GlobalAnimRateScale, r.twin.Mesh:GetPlayRate())
                    end
                end)
                do break end
                ::nextKnown::
            end
            U.log("enemies: %s, %d known here, sent %d, received %d, actions %d, partner hits sent %d / applied %d, "
                .. "local reactions %d, echoes skipped %d, copies sent out by our spawners %d (no spawner %d)%s", S.role,
                n, stats.sent, stats.received, stats.actions, stats.hitsSent or 0, stats.hitsApplied or 0,
                stats.localReactions or 0, stats.echoes or 0, stats.made or 0, stats.makeFailed or 0, where)
            U.log("pose: %s", Pose.stats())
        end
        return false
    end)
end

-- For tests: our enemies with ids.
function E.list() return liveScan() end
-- Lab: a character TailCoop must leave alone (a probe's own).
function E.ignore(actor) retiredActors[actor:GetAddress()] = true end

-- Joiner: our (hidden, host-driven) enemy for the host's id, or nil.
function E.localActorFor(id)
    local r = remote[id]
    return r and r.controlled and U.valid(r.actor) and r.actor or nil
end
function E.health(c) return health(c) end

return E
