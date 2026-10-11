-- tc_pvp: player against player, on an Arena map (CO-OP > HOST GAME > PVP). Rounds: knock the other player out to
-- win one; first to 3 wins the match, then a new match starts. No enemies.
--
-- The map is an Arena challenge's level, travelled to and started by both games as for a co-op challenge (tc_flow,
-- tc_arena), but its challenge never plays: each game stops its wave director and puts every enemy out of the game
-- (alive - a death would move the challenge on). Neither player can die (HealthComponent BPF_SetCanDieByDamage): a
-- blow that would kill leaves 1 health, and that's the knockout. The players' hits on each other are forwarded like
-- the co-op enemies' hits (tc_aggro, "phit" from "player"): the defender's own game plays them, so blocks, parries and
-- dodges are theirs.
-- The host keeps the score: "pvp|ready" (a game's player is in), "pvp|ko" (ours is knocked out), and from the host
-- "pvp|round|n|myScore...|spots" - both games reset their player (health, guard, place) and fight on 2 s later.
local U = require("tc_util")
local N = require("tc_net")
local S = require("tc_session")
local F = require("tc_flow")

local P = {}

-- One challenge per Arena map whose objective never ends on its own (wave objective, no chrono, no cheats - lab probe
-- 2026-10-11). Both players get the same challenge, so the same character age.
-- Not The Stairs or Data Center: their start area has a fixed rail camera (black bars) that turns both players the
-- same way, so one can't see the other, and the HUD counter (our score) isn't shown there.
P.MAPS = {
    { name = "THE STREETS", batch = 0, challenge = 0 },
    { name = "THE PIT", batch = 1, challenge = 0 },
    { name = "ROOFTOP", batch = 3, challenge = 0 },
    { name = "WUGUAN", batch = 10, challenge = 0 },
    { name = "SNOW GARDEN", batch = 13, challenge = 0 },
}
P.FIRST_TO = 3

function P.mapName(map)
    if not map then return "?" end
    for _, m in ipairs(P.MAPS) do
        if m.batch == map.batch and m.challenge == map.challenge then return m.name end
    end
    return string.format("ARENA %d-%d", map.batch, map.challenge)
end

local KO_HEALTH = 1          -- what a blow that would have killed leaves
local RESET_DELAY_MS = 2000  -- knockout -> both players reset
local SAFE_MS = 2000         -- after a reset: invincible
local MATCH_END_MS = 6000    -- "YOU WIN" before the next match
local INTRO_MS = 4000        -- after Start: the challenge's intro camera hands over control (at the earliest)
local INTRO_OVER_MS = 1000   -- the camera back on our player this long: the intro is over
local INTRO_MAX_MS = 60000   -- (in case that's never seen)
local SPOT_NEAR, SPOT_FAR = 150, 550  -- the two players' spots in front of the host's start, 4 m apart

local st = {}
local function reset()
    st = {
        phase = "wait",      -- wait (for both players) | between (reset coming / safe) | fight | ko | matchEnd
        startedAt = nil,     -- clock our PvP activity began
        readySent = false, partnerReady = false,
        score = { host = 0, join = 0 }, round = 0,
        spots = nil,         -- { host = {x,y,z,yaw}, join = {...} }
        resetAt = nil, safeUntil = nil, nextMatchAt = nil,
        cameraOnUsSince = nil,
        enemies = {},        -- address -> actor put out of the game here
        scanAt = -1e9, wavesAt = -1e9, textAt = -1e9,
        banner = nil, bannerUntil = 0,
    }
end
reset()

local function active() return S.mode == "pvp" and F.activity == "pvp" and S.connected() end
local function other(role) return role == "host" and "join" or "host" end
local function clock() return TailCoop_Clock() end

local function myPawn()
    local pc = U.playerController()
    local pawn = pc and pc.Pawn
    return U.valid(pawn) and pawn or nil, pc
end

-- tc_aggro: hits on us aren't played between rounds (reset coming, invincible, match over).
function P.betweenRounds() return active() and st.phase ~= "fight" end

local function banner(text, ms)
    st.banner, st.bannerUntil = text, clock() + (ms or 2000)
    st.textAt = -1e9
end

-- EMPTY ARENA ------------------------------------------------------------------------------------------------------
local function emptyArena(now)
    local AR = require("tc_arena")
    if now - st.wavesAt >= 1000 then
        st.wavesAt = now
        AR.stopWaves()
    end
    if now - st.scanAt < 1000 then return end
    st.scanAt = now
    local E = require("tc_enemies")
    local me = myPawn()
    local puppet = require("tc_presence").puppetActor()
    local skip = {}
    if me then skip[me:GetAddress()] = true end
    if U.valid(puppet) then skip[puppet:GetAddress()] = true end
    local ok, all = pcall(FindAllOf, "FightingCharacter")
    for _, c in ipairs(ok and all or {}) do
        local addr = U.valid(c) and c:GetAddress()
        if addr and not skip[addr] then
            if st.enemies[addr] then
                E.keepAway(c)
            elseif E.isEnemy(c) then
                st.enemies[addr] = c
                E.putAway(c)
                local n = 0
                for _ in pairs(st.enemies) do n = n + 1 end
                if n <= 30 then U.log("pvp: %s put out of the game (%d so far)", U.shortName(c), n) end
            end
        end
    end
    for addr, c in pairs(st.enemies) do
        if not U.valid(c) then st.enemies[addr] = nil end
    end
end

-- ROUNDS -----------------------------------------------------------------------------------------------------------
local function spotText(s) return string.format("%.1f,%.1f,%.1f,%.1f", s.x, s.y, s.z, s.yaw) end
local function parseSpot(t)
    local x, y, z, yaw = (t or ""):match("([^,]+),([^,]+),([^,]+),([^,]+)")
    return x and { x = tonumber(x), y = tonumber(y), z = tonumber(z), yaw = tonumber(yaw) } or nil
end

-- Host: the two spots, in front of where our player started (the challenge's player start faces into the arena).
local function makeSpots()
    local me = myPawn()
    if not me then return nil end
    local ok, s = pcall(function()
        local l, f = me:K2_GetActorLocation(), me:GetActorForwardVector()
        local yaw = me:K2_GetActorRotation().Yaw
        return {
            host = { x = l.X + f.X * SPOT_NEAR, y = l.Y + f.Y * SPOT_NEAR, z = l.Z, yaw = yaw },
            join = { x = l.X + f.X * SPOT_FAR, y = l.Y + f.Y * SPOT_FAR, z = l.Z, yaw = yaw + 180 },
        }
    end)
    return ok and s or nil
end

-- Both: our player back to full and on our spot; invincible for SAFE_MS.
local function resetPlayer()
    local me, pc = myPawn()
    if not me then return end
    pcall(function() me.m_HealthComponent:BPF_SetCanDieByDamage(false) end)
    pcall(function() me:BPF_GetOrderComponent():BPF_CancelAllOrders() end)
    pcall(function()
        local hc = me.m_HealthComponent
        hc:BPF_ServerSetHealth(hc.m_fMaxHealth)
    end)
    pcall(function()
        local d = me.m_DefenseComponent
        d:BPF_IncreaseGuardGauge(d:BPF_GetMaxGuardGauge())
    end)
    local spot = st.spots and st.spots[S.role]
    if spot then
        pcall(function()
            me:K2_SetActorLocationAndRotation({ X = spot.x, Y = spot.y, Z = spot.z }, { Pitch = 0, Yaw = spot.yaw, Roll = 0 },
                false, {}, true)
        end)
        pcall(function() pc:SetControlRotation({ Pitch = -10, Yaw = spot.yaw, Roll = 0 }) end)
        -- Sifu's camera doesn't follow the control rotation: its own look-at turns it to the opponent's spot (the
        -- joiner's camera kept facing the way it spawned - away from the host). Ends at the player's first camera move.
        local theirs = st.spots[other(S.role)]
        if theirs then
            pcall(function()
                me.CameraComponentThird1:BPF_AddLookAt({ m_eLookATType = 1,  -- ELookAtType::Pos
                    m_vTargetPosition = { X = theirs.x, Y = theirs.y, Z = theirs.z },
                    m_timeParams = { m_fReachDuration = 0.4 },
                    m_configParams = { m_bLookAtUseYaw = true, m_bLookAtUsePitch = false, m_bDeactivateOnManual = true } },
                    {})
            end)
        end
    end
    pcall(function() me:BPF_SetInvincibility(true) end)
    st.safeUntil = clock() + SAFE_MS
end

-- Both: a round message from the host (or our own, on the host).
local function onRound(n, hostScore, joinScore, lastWinner, spots)
    st.round, st.score.host, st.score.join = n, hostScore, joinScore
    if spots then st.spots = spots end
    st.phase, st.resetAt = "between", clock() + (n == 1 and 0 or RESET_DELAY_MS)
    st.nextMatchAt = nil
    if lastWinner == S.role then banner("YOU WIN THE ROUND")
    elseif lastWinner == other(S.role) then banner("YOU LOSE THE ROUND")
    else banner("ROUND " .. n) end
    U.log("pvp: round %d, score host %d - joiner %d%s", n, hostScore, joinScore,
        lastWinner and (" (" .. lastWinner .. " won the last)") or "")
end

local function onMatchEnd(hostScore, joinScore, winner)
    st.score.host, st.score.join = hostScore, joinScore
    st.phase = "matchEnd"
    banner(winner == S.role and "YOU WIN THE MATCH" or "YOU LOSE THE MATCH", MATCH_END_MS)
    if S.role == "host" then st.nextMatchAt = clock() + MATCH_END_MS end
    U.log("pvp: match over, %s wins %d - %d", winner, hostScore, joinScore)
end

local function sendRound(lastWinner)
    local s = st.spots
    N.send(true, "pvp", "round", st.round, st.score.host, st.score.join, lastWinner or "-",
        s and spotText(s.host) or "", s and spotText(s.join) or "")
end

-- Host: a knockout (of `loser`).
local function hostKo(loser)
    if st.phase ~= "fight" and st.phase ~= "ko" then return end  -- (both at once: the first one counts)
    local winner = other(loser)
    st.score[winner] = st.score[winner] + 1
    U.log("pvp: %s knocked out: %s scores (%d - %d)", loser, winner, st.score.host, st.score.join)
    if st.score[winner] >= P.FIRST_TO then
        N.send(true, "pvp", "match", st.score.host, st.score.join, winner)
        onMatchEnd(st.score.host, st.score.join, winner)
        return
    end
    st.round = st.round + 1
    sendRound(winner)
    onRound(st.round, st.score.host, st.score.join, winner, st.spots)
end

-- Host: a new match, 0 - 0.
local function newMatch()
    st.score.host, st.score.join, st.round = 0, 0, 1
    st.spots = st.spots or makeSpots()
    sendRound(nil)
    onRound(1, 0, 0, nil, st.spots)
end

local function onMessage(f)
    local what = f[1]
    if what == "ready" then
        st.partnerReady = true
        U.log("pvp: the partner's player is in")
    elseif what == "ko" then
        if S.role == "host" then hostKo("join") end
    elseif what == "round" then
        if S.role == "host" then return end
        local h, j = parseSpot(f[6]), parseSpot(f[7])
        onRound(tonumber(f[2]) or 1, tonumber(f[3]) or 0, tonumber(f[4]) or 0, f[5] ~= "-" and f[5] or nil,
            (h and j) and { host = h, join = j } or nil)
    elseif what == "match" then
        if S.role == "host" then return end
        onMatchEnd(tonumber(f[2]) or 0, tonumber(f[3]) or 0, f[4])
    end
end

-- HUD: the score (ours first) in the waves counter, with what's happening as its label.
local function hudTick(now)
    if now - st.textAt < 250 then return end
    st.textAt = now
    local mine, theirs = st.score[S.role], st.score[other(S.role)]
    local label = (st.banner and now < st.bannerUntil) and st.banner
        or (st.phase == "wait" and "WAITING FOR THE PARTNER") or ("FIRST TO " .. P.FIRST_TO)
    require("tc_arena").showText(string.format("%d - %d", mine, theirs), label)
end

-- The challenge's intro (a level sequence on its own camera) is over: the camera has been back on our player for
-- INTRO_OVER_MS. Some intros run 11 s; a reset during one (orders cancelled, player moved) left a player 5 m off
-- their spot once the intro ended.
local function introOver(now)
    if now - st.startedAt < INTRO_MS then return false end
    if now - st.startedAt >= INTRO_MAX_MS then return true end
    if not require("tc_arena").cameraOnPlayer() then
        st.cameraOnUsSince = nil
        return false
    end
    st.cameraOnUsSince = st.cameraOnUsSince or now
    return now - st.cameraOnUsSince >= INTRO_OVER_MS
end

local function tick()
    if not active() then return false end
    local now = clock()
    st.startedAt = st.startedAt or now
    emptyArena(now)
    local me = myPawn()
    if not me then return false end
    -- Nobody dies in PvP (set again: the game may reset it).
    pcall(function() me.m_HealthComponent:BPF_SetCanDieByDamage(false) end)
    if not st.readySent and introOver(now) then
        st.readySent = true
        if S.role == "host" then st.spots = makeSpots() end  -- (where the challenge put us, before we walk about)
        N.send(true, "pvp", "ready")
        U.log("pvp: our player is in, %.1f s after Start (host's spawn %s)", (now - st.startedAt) / 1000,
            S.role == "host" and "used for the spots" or "not used")
    end
    if S.role == "host" and st.phase == "wait" and st.readySent and st.partnerReady then
        st.spots = st.spots or makeSpots()
        newMatch()
    end
    if S.role == "host" and st.phase == "matchEnd" and st.nextMatchAt and now >= st.nextMatchAt then
        newMatch()
    end
    if st.phase == "between" then
        if st.resetAt and now >= st.resetAt then
            st.resetAt = nil
            resetPlayer()
        elseif not st.resetAt and st.safeUntil and now >= st.safeUntil then
            st.safeUntil = nil
            pcall(function() me:BPF_SetInvincibility(false) end)
            st.phase = "fight"
            banner("FIGHT", 1200)
        end
    elseif st.phase == "fight" then
        local ok, hp = pcall(function() return me.m_HealthComponent.m_fHealth end)
        if ok and hp and hp <= KO_HEALTH then
            st.phase = "ko"
            banner("KNOCKED OUT", RESET_DELAY_MS)
            U.log("pvp: our player is knocked out (health %.1f)", hp)
            if S.role == "host" then hostKo("host") else N.send(true, "pvp", "ko") end
        end
    end
    hudTick(now)
    return false
end

-- Lab / logs: the match as this game sees it.
function P.debug()
    local me = myPawn()
    local hp, inv, at = "?", "?", "?"
    if me then
        pcall(function() hp = string.format("%.0f/%.0f", me.m_HealthComponent.m_fHealth, me.m_HealthComponent.m_fMaxHealth) end)
        pcall(function() inv = tostring(me.m_bIsInvincible) end)
        pcall(function() local l = me:K2_GetActorLocation() at = string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) end)
    end
    local spot = st.spots and st.spots[S.role]
    return string.format("phase %s round %d score host %d join %d | hp %s at %s (spot %s) | enemies put away %d",
        st.phase, st.round, st.score.host, st.score.join, hp, at,
        spot and string.format("%.0f,%.0f,%.0f", spot.x, spot.y, spot.z) or "-",
        (function() local n = 0 for _ in pairs(st.enemies) do n = n + 1 end return n end)())
end

function P.start()
    N.on("pvp", function(f) U.onGameThread("pvp message", function() onMessage(f) end) end)
    F.onMapChange(reset)
    S.onChange(function() if not S.connected() then reset() end end)
    U.poll("pvp", 50, tick)
end

return P
