-- tc_presence: the partner's character in your world (G3).
-- Each side sends its player's position / facing / velocity at 30 Hz (unreliable). The receiver shows a "puppet":
-- a character of the same class, no controller, no collision, no movement physics, placed every frame by
-- interpolating the snapshots a little in the past (tc_timeline: as far back as the connection needs; extrapolates up
-- to 200 ms on loss).
local U = require("tc_util")
local N = require("tc_net")
local S = require("tc_session")
local F = require("tc_flow")
local TL = require("tc_timeline")
local UEHelpers = require("UEHelpers")

local P = {}

local SEND_MS = 33
local MAX_EXTRAPOLATE_MS = 200
local MAX_SNAPS = 40

local snaps = {}          -- received snapshots, oldest first: { t, x, y, z, yaw, vx, vy, vz }
local peer = { map = nil, class = nil, offset = nil }  -- offset: our clock - their clock (min seen)
local puppet = nil        -- { actor, world }
local stats = { sent = 0, received = 0, lastLog = 0, gear = {}, own = {} }

local function clock() return TailCoop_Clock() end

local function myPawn()
    local pc = U.playerController()
    if not U.valid(pc) then return nil end
    local pawn = pc.Pawn
    return U.valid(pawn) and pawn or nil
end

local function worldKey()
    local w = U.world()
    return U.valid(w) and w:GetAddress() or nil
end

-- Sending ----------------------------------------------------------------------------------------------

local function sendSnapshot()
    if not S.connected() or not F.currentMap or not F.activity then return false end
    local pawn = myPawn()
    if not pawn then return false end
    local now = clock()
    local A = require("tc_anim")
    local t0 = U.tick()
    -- What rarely changes (map, activity, character class) goes reliably on its own: on change and every 2 s.
    local own = stats.own
    if own.pawn ~= pawn:GetAddress() then
        own.pawn, own.class = pawn:GetAddress(), pawn:GetClass():GetFullName():match("%s(.+)$") or ""
        own.inst, own.poseMeshStr = nil, nil
    end
    local info = F.currentMap .. "^" .. F.activity .. "^" .. own.class
    if info ~= own.info or now - (own.infoAt or 0) > 2000 then
        own.info, own.infoAt = info, now
        N.send(true, "pinfo", F.currentMap, F.activity, own.class)
    end
    -- Velocity from our own motion (no engine call; Sifu's velocity getters read 0 for players anyway).
    local loc, yaw = pawn:K2_GetActorLocation(), pawn:K2_GetActorRotation().Yaw
    local vx, vy, vz = 0, 0, 0
    if own.t and now > own.t then
        local dt = (now - own.t) / 1000
        vx, vy, vz = (loc.X - own.x) / dt, (loc.Y - own.y) / dt, (loc.Z - own.z) / dt
    end
    own.t, own.x, own.y, own.z = now, loc.X, loc.Y, loc.Z
    U.tock("own snapshot: info + place", t0)
    local t1 = U.tick()
    if not (U.valid(own.inst)) then own.inst = A.animInstance(pawn) end
    local ms, q = A.moveStatus(pawn), A.quadrant(own.inst)
    U.tock("own snapshot: stance", t1)
    local t2 = U.tick()
    N.send(false, "p", now, string.format("%.0f", loc.X), string.format("%.0f", loc.Y), string.format("%.0f", loc.Z),
        string.format("%.1f", yaw), string.format("%.0f", vx), string.format("%.0f", vy), string.format("%.0f", vz),
        tostring(ms or ""), tostring(q or ""))
    U.tock("own snapshot: send", t2)
    stats.sent = stats.sent + 1
    local tg = U.tick()
    require("tc_gear").publish(pawn, "p", stats.gear, clock())
    U.tock("own gear publish", tg)
    local tp = U.tick()
    -- Our exact pose (every bone), for the copy of us in the partner's game.
    local bytes, err = require("tc_pose").send(pawn, "p", clock(), own)
    if not bytes and err ~= stats.poseErr then
        stats.poseErr = err
        U.log("presence: pose not sent: %s", tostring(err))
    end
    U.tock("own pose send", tp)
    return false
end

-- Receiving (network thread: plain data only, no game objects) -----------------------------------------

-- "pinfo|map|activity|class" (reliable, on change)
local function onInfo(f)
    peer.map, peer.activity, peer.class = f[1], f[2], f[3]
end

-- "p|clock|x|y|z|yaw|vx|vy|vz|stance|quadrant" (unreliable, 30 Hz)
local function onSnapshot(f)
    local t = tonumber(f[1])
    if not t then return end
    local now = clock()
    local offset = now - t
    if not peer.offset or offset < peer.offset then peer.offset = offset end
    TL.observe("p", t, now)
    peer.lastHeard = now
    peer.stance = tonumber(f[9])
    peer.quadrant = tonumber(f[10])
    -- Drop out-of-order snapshots (unreliable channel).
    if #snaps > 0 and t <= snaps[#snaps].t then return end
    snaps[#snaps + 1] = {
        t = t, x = tonumber(f[2]), y = tonumber(f[3]), z = tonumber(f[4]), yaw = tonumber(f[5]),
        vx = tonumber(f[6]), vy = tonumber(f[7]), vz = tonumber(f[8]),
    }
    if #snaps > MAX_SNAPS then table.remove(snaps, 1) end
    stats.received = stats.received + 1
end

-- Puppet ---------------------------------------------------------------------------------------------

-- The partner's character is never destroyed mid-world: enemies fighting it keep a pointer to it (destroying it
-- under them crashed the game: read at +0xb0 in Sifu's AI), and in an Arena challenge destroying a fighting player
-- took a whole second and the game crashed a minute later. It's parked instead - enemies forget it, hidden, lifted
-- far above the fight - and used again when the partner comes back. The world's end takes it.
local parked = nil  -- { actor, world }

local function destroyPuppet(reason)
    if puppet then
        if puppet.world == worldKey() and U.valid(puppet.actor) then
            local actor = puppet.actor
            require("tc_pose").park(actor, puppet.motion)
            -- Enemies fighting it forget it and come for us instead. (Was: every enemy forgot its target, ours too,
            -- and after the partner's game crashed they all stood there idle - "lifeless" - for the rest of the fight.)
            U.try("puppet: enemies forget it", function()
                local me = myPawn()
                local puppetAddr = actor:GetAddress()
                for _, e in ipairs(require("tc_enemies").list()) do
                    pcall(function()
                        local ai = e.actor.m_AIComponent
                        local en = ai:BPF_GetEnemy()
                        if U.valid(en) and en:GetAddress() == puppetAddr then
                            ai:BPF_ForgetEnemy()
                            if me then ai:BPF_ForceEnemy(me, 3) end  -- EGlobalBehaviors::Alerted
                        end
                    end)
                end
            end)
            U.try("park puppet", function()
                actor:SetActorHiddenInGame(true)
                actor:SetActorEnableCollision(false)
                local l = actor:K2_GetActorLocation()
                actor:K2_SetActorLocation({ X = l.X, Y = l.Y, Z = l.Z + 20000 }, false, {}, true)
            end)
            parked = { actor = actor, world = puppet.world, motion = puppet.motion }
        end
        U.log("presence: puppet removed (%s)", reason)
        puppet = nil
    end
end

-- Spawns a visual-only character of `cls` at `at` ({x, y, z}): no collision, no movement physics (we place it).
-- AI classes get no AI controller (AutoPossessAI = Disabled): a visual-only copy runs no behaviour.
function P.spawnCharacter(cls, at)
    local gs = UEHelpers.GetGameplayStatics()
    local xf = {
        Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        Translation = { X = at.x, Y = at.y, Z = at.z },
        Scale3D = { X = 1, Y = 1, Z = 1 },
    }
    local actor = gs:BeginDeferredActorSpawnFromClass(U.world(), cls, xf, 1, nil)  -- 1 = AlwaysSpawn
    if not U.valid(actor) then return nil end
    pcall(function() actor.AutoPossessAI = 0 end)
    gs:FinishSpawningActor(actor, xf)
    actor:SetActorEnableCollision(false)
    local move = actor.CharacterMovement
    if U.valid(move) then move:SetMovementMode(0, 0) end  -- MOVE_None: no gravity, no walking logic
    return actor
end

local function spawnPuppet(at)
    local cls = peer.class and peer.class ~= "" and StaticFindObject(peer.class) or nil
    if not U.valid(cls) then
        local pawn = myPawn()
        cls = pawn and pawn:GetClass() or nil
    end
    if not U.valid(cls) then return end
    if parked and parked.world == worldKey() and U.valid(parked.actor) and parked.actor:IsA(cls) then
        local actor, motion = parked.actor, parked.motion
        parked = nil
        U.try("unpark puppet", function()
            actor:K2_SetActorLocation({ X = at.x, Y = at.y, Z = at.z }, false, {}, true)
            actor:SetActorHiddenInGame(false)
        end)
        require("tc_pose").unpark(motion)
        motion.placed = nil  -- placed again from the next snapshot
        puppet = { actor = actor, world = worldKey(), motion = motion }
        U.log("presence: partner's character back (%s) at %.0f %.0f %.0f", U.shortName(actor), at.x, at.y, at.z)
        return
    end
    local actor = P.spawnCharacter(cls, at)
    if not actor then
        U.log("presence: could not spawn the partner's character (%s)", cls:GetFullName())
        return
    end
    require("tc_anim").makeDriven(actor)
    require("tc_anim").protect(actor)  -- enemies hit it: never swap its animation instance (tc_anim.protect)
    puppet = { actor = actor, world = worldKey(), motion = {} }
    U.log("presence: partner's character spawned (%s) at %.0f %.0f %.0f", U.shortName(actor), at.x, at.y, at.z)
end

local function lerp(a, b, k) return a + (b - a) * k end

local function lerpAngle(a, b, k)
    local d = (b - a + 540) % 360 - 180
    return a + d * k
end

-- Where the partner was at their clock time renderT (tc_timeline), from the snapshot buffer.
local function sample(renderT)
    if #snaps == 0 or not renderT then return nil end
    local newest = snaps[#snaps]
    if renderT >= newest.t then
        local dt = math.min(renderT - newest.t, MAX_EXTRAPOLATE_MS) / 1000
        return { x = newest.x + newest.vx * dt, y = newest.y + newest.vy * dt, z = newest.z + newest.vz * dt,
                 yaw = newest.yaw, vx = newest.vx, vy = newest.vy, vz = newest.vz, mode = "extrapolate" }
    end
    for i = #snaps - 1, 1, -1 do
        local a, b = snaps[i], snaps[i + 1]
        if renderT >= a.t then
            local k = (renderT - a.t) / math.max(1, b.t - a.t)
            return { x = lerp(a.x, b.x, k), y = lerp(a.y, b.y, k), z = lerp(a.z, b.z, k), yaw = lerpAngle(a.yaw, b.yaw, k),
                     vx = lerp(a.vx, b.vx, k), vy = lerp(a.vy, b.vy, k), vz = lerp(a.vz, b.vz, k), mode = "interpolate" }
        end
    end
    local oldest = snaps[1]
    return { x = oldest.x, y = oldest.y, z = oldest.z, yaw = oldest.yaw, vx = 0, vy = 0, vz = 0, mode = "hold" }
end

-- The partner is out of an Arena challenge (game over, watching us): their character isn't shown (tc_arena).
P.partnerOut = false

-- PAUSE ----------------------------------------------------------------------------------------------------------
-- A player who opens the pause menu pauses only their own game (Sifu closes its pause menu if the game is unpaused
-- behind it - lab, 9 ms after). The mod keeps running in a paused game (its loops, the network), but that world is
-- frozen: its player and the enemies it runs stood still on the partner's screen. So each game tells the other
-- whether it's paused ("ppause"), and a paused player counts as away for the moment: enemies leave them for the
-- partner, and the enemies their game ran are handed over (tc_aggro) - the partner's game goes on. Back when they
-- resume.
local pausedState = { me = false, partner = false, sentAt = -1e9 }
function P.isPaused(role)
    if role == S.role then return pausedState.me end
    return pausedState.partner
end

local function pauseTick()
    if not (S.connected() and F.activity) then
        pausedState.me, pausedState.partner = false, false
        return false
    end
    local ok, p = pcall(function() return UEHelpers.GetGameplayStatics():IsGamePaused(U.world()) end)
    p = ok and p == true
    local now = clock()
    if p ~= pausedState.me or now - pausedState.sentAt > 2000 then
        if p ~= pausedState.me then
            U.log("presence: %s", p and "our game is paused: the partner's game goes on, our enemies go to them"
                or "our game is running again")
        end
        pausedState.me, pausedState.sentAt = p, now
        N.send(true, "ppause", p and 1 or 0)
    end
    return false
end

local function updatePuppet()
    -- Snapshots stop when the partner leaves the activity: treat >1 s of silence as "not here".
    local fresh = peer.lastHeard and clock() - peer.lastHeard < 1000
    local together = S.connected() and fresh and F.activity ~= nil and peer.activity == F.activity
        and peer.map == F.currentMap and not P.partnerOut
    if not together then
        if puppet then
            destroyPuppet(not S.connected() and "not connected" or (not fresh and "partner stopped sending")
                or (P.partnerOut and "partner is out of the challenge") or "partner is elsewhere")
        end
        if not S.connected() then
            snaps = {}
            peer.offset = nil
            TL.reset()
        end
        return false
    end
    local tw = U.tick()
    if puppet and (puppet.world ~= worldKey() or not U.valid(puppet.actor)) then
        U.log("presence: puppet lost with the old world")
        puppet = nil
    end
    local now = clock()
    local renderT = TL.renderClock(now)
    local at = sample(renderT)
    U.tock("partner: world check + sample", tw)
    if not at then return false end
    if not puppet then
        if not myPawn() then return false end  -- wait until our own player exists in this map
        spawnPuppet(at)
        if not puppet then return false end
    end
    local actor = puppet.actor
    -- Placed from the snapshots; shows the partner's exact pose on the same timeline (tc_pose), or - without one -
    -- a walk/run/idle that follows that motion and the partner's stance (tc_anim copy animator).
    local Anim = require("tc_anim")
    local td = U.tick()
    Anim.drive(actor, puppet.motion, at.x, at.y, at.z, at.yaw, now)
    U.tock("partner drive", td)
    local ta = U.tick()
    local applied = require("tc_pose").apply(actor, puppet.motion, "p", renderT)
    U.tock("partner pose apply", ta)
    if not applied then
        Anim.copyLocomotion(actor, puppet.motion, peer.stance == 1, now, peer.quadrant)
    end
    -- How far past its newest state the copy was shown (> 0: it ran out of data this frame).
    TL.noteShown("partner", applied and puppet.motion.poseAge or (renderT - snaps[#snaps].t))
    local tg = U.tick()
    require("tc_gear").apply(actor, puppet.motion, "p")
    U.tock("partner gear apply", tg)
    -- Lab check that the copy's feet move (two engine calls): 10 times a second is enough.
    if U.config.system ~= "0" and now - (puppet.strideAt or 0) >= 100 then
        puppet.strideAt = now
        local ts = U.tick()
        Anim.strideSample(actor, puppet.motion)
        U.tock("partner stride sample (lab)", ts)
    end
    -- Stance (combat / exploration), applied when it changes.
    if peer.stance and peer.stance ~= puppet.stance then
        puppet.stance = peer.stance
        require("tc_anim").setMoveStatus(actor, peer.stance)
        U.log("presence: partner stance %d", peer.stance)
    end
    if now - stats.lastLog >= 2000 then
        stats.lastLog = now
        local me = myPawn()
        local ml = me and me:K2_GetActorLocation()
        local m = puppet.motion
        U.log("presence: partner at %.0f %.0f %.0f yaw %.0f speed %.0f stance %s %s (%s, %d snaps, sent %d recv %d)%s",
            at.x, at.y, at.z, at.yaw, math.sqrt((m.vx or 0) ^ 2 + (m.vy or 0) ^ 2), tostring(peer.stance),
            require("tc_anim").strideReport(m), at.mode, #snaps, stats.sent, stats.received,
            ml and string.format(" | me at %.0f %.0f %.0f", ml.X, ml.Y, ml.Z) or "")
    end
    return false
end

function P.start()
    TL.fixed = U.config.buffer == "fixed"
    if TL.fixed then U.log("presence: copies play a fixed 100 ms behind (lab comparison)") end
    N.on("p", onSnapshot)
    N.on("pinfo", onInfo)
    N.on("ppause", function(f)
        local p = f[1] == "1"
        if p ~= pausedState.partner then
            U.log("presence: the partner %s", p and "paused their game (away until they resume)" or "is back from pause")
        end
        pausedState.partner = p
    end)
    U.poll("pause state", 200, pauseTick)
    S.onChange(function()
        if not S.connected() then
            snaps = {}
            peer.offset = nil
            TL.reset()
            peer.map, peer.activity = nil, nil
            stats.own = {}  -- "pinfo" again first thing next session
        end
    end)
    U.poll("presence send", SEND_MS, sendSnapshot)
    U.poll("presence puppet", 16, updatePuppet)
end

-- Our clock minus the partner's (lowest seen, so it includes the fastest one-way path), or nil.
function P.peerOffset() return peer.offset end

-- How long ago (ms) the partner sent something stamped with their clock `senderClock`: the part above the
-- minimum seen (clock offset + fastest path), plus half the RTT for that fastest path.
function P.oneWayDelayMs(senderClock)
    if not (senderClock and peer.offset) then return 0 end
    local now = clock()
    if not peer.rttAt or now - peer.rttAt > 500 then  -- the RTT barely moves: fetched twice a second
        local st = N.status()
        peer.rtt, peer.rttAt = st.rtt, now
    end
    local base = (peer.rtt and peer.rtt > 0) and peer.rtt / 2 or 0
    return math.max(0, clock() - senderClock - peer.offset) + base
end

-- For tests: the puppet actor (or nil) and the latest snapshot.
function P.puppetActor() return puppet and puppet.actor or nil end
function P.puppetState() return puppet and puppet.motion or nil end
function P.latest() return snaps[#snaps] end

return P
