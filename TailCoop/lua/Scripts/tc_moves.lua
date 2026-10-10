-- tc_moves: the partner's actions on their character (G4) - attacks, dodges, hit reactions, any "action" animation
-- Sifu's player animation is playing - plus their stance (combat / exploration).
--
-- Sender: every frame on the game thread, tc_anim's watcher reads our player's UPlayerAnim action tracks
--   (attack / dodge / override / weapon / emote swapper structs, read raw: UE4SS can't see inherited struct fields)
-- and sends "act" (reliable) when an action starts, "actend" when no action plays any more.
-- Receiver: plays the same sequence on the puppet through a dynamic montage in DefaultSlot (tc_anim), from the
-- sender's position in it plus the measured one-way delay, so the puppet lines up with the real character.
local U = require("tc_util")
local N = require("tc_net")
local S = require("tc_session")
local F = require("tc_flow")
local A = require("tc_anim")

local M = {}

local SEND_MS = 10  -- polled every frame...
-- ...but our action tracks are read 30 times a second: the partner's copy of us shows our exact pose stream (tc_pose),
-- these actions are only its fallback and the outcome of a hit on us (tc_aggro), which asks for every frame for a
-- moment after one (readFastUntil). (Was: every frame, ~7 ms of game time a second.)
local READ_MS = 33
M.readFastUntil = 0
local readAt = -1e9

local watcher = A.watcher()
local stats = { acts = 0, played = 0, missing = 0, mirrored = 0 }

local function myPawn()
    local pc = U.playerController()
    return pc and U.valid(pc.Pawn) and pc.Pawn or nil
end

local function sendTick()
    if not (S.connected() and F.activity) then return false end
    local now = TailCoop_Clock()
    if now - readAt < READ_MS and now >= M.readFastUntil then return false end
    readAt = now
    local pawn = myPawn()
    if not pawn then return false end
    local ev = watcher:update(pawn, now)
    if not ev then return false end
    if ev.kind == "end" then
        N.send(true, "actend", TailCoop_Clock())
        return false
    end
    if not ev.path then return false end
    M.lastOwnAction = { path = ev.path, at = TailCoop_Clock() }
    N.send(true, "act", ev.path, ev.mirror and 1 or 0, string.format("%.3f", ev.rate), string.format("%.3f", ev.start),
        string.format("%.3f", ev.cursor), TailCoop_Clock(), ev.track)
    stats.acts = stats.acts + 1
    if stats.acts <= 60 or stats.acts % 50 == 0 then
        U.log("moves: sent %s %s (rate %.2f start %.2f cursor %.2f mirror %s)", ev.track, ev.path, ev.rate, ev.start,
            ev.cursor, tostring(ev.mirror))
    end
    return false
end

-- Receiving (game thread: the network pump runs there) ---------------------------------------------------

local assetCache = {}

function M.resolve(path)
    local cached = assetCache[path]
    if cached and U.valid(cached) then return cached end
    local obj = StaticFindObject(path)
    if not U.valid(obj) then
        -- Not loaded in this game yet (e.g. a move this player hasn't used): load it now.
        local ok, loaded = pcall(LoadAsset, path)
        obj = ok and loaded or nil
    end
    if U.valid(obj) then assetCache[path] = obj end
    return U.valid(obj) and obj or nil
end

local function puppet()
    local P = require("tc_presence")
    local actor = P.puppetActor()
    return U.valid(actor) and actor or nil
end

-- "act|path|mirror|rate|startRatio|cursor|clock|track"
local function onAct(f)
    local actor = puppet()
    if not actor then return end
    -- The exact pose stream (tc_pose) already shows this move; only the fallback needs it.
    local st = require("tc_presence").puppetState()
    if st and st.poseDriven then
        stats.played = stats.played + 1
        return
    end
    local asset = M.resolve(f[1])
    if not asset then
        stats.missing = stats.missing + 1
        U.log("moves: animation not found: %s", tostring(f[1]))
        return
    end
    local rate = tonumber(f[3]) or 1.0
    local P = require("tc_presence")
    local delay = P.oneWayDelayMs and P.oneWayDelayMs(tonumber(f[6])) or 0
    local startAt = A.startTime(asset, tonumber(f[5]), tonumber(f[4]), delay, rate)
    local montage = A.copyAction(actor, P.puppetState(), asset, rate, startAt, f[2] == "1", TailCoop_Clock())
    stats.played = stats.played + 1
    if f[2] == "1" then stats.mirrored = stats.mirrored + 1 end
    if stats.played <= 60 or stats.played % 50 == 0 then
        U.log("moves: partner %s %s at %.2fs (delay %.0f ms, mirror %s) -> %s", f[7] or "?", f[1], startAt, delay, f[2],
            montage and "playing" or "NOT PLAYING")
    end
end

local function onActEnd()
    local actor = puppet()
    local st = require("tc_presence").puppetState()
    if actor and st then A.copyActionEnd(st) end
end

-- Lab diagnostics: what drives Sifu's locomotion animation (for the puppet's walk/run), every 2 s while moving.
local probe = { at = 0 }
local function locomotionProbe()
    if not F.activity then return false end
    local now = TailCoop_Clock()
    if now - probe.at < 2000 then return false end
    probe.at = now
    local function describe(who, ch)
        if not U.valid(ch) then return who .. " -" end
        local inst = A.animInstance(ch)
        local okA, s = pcall(function()
            local mv = ch.CharacterMovement
            local v = mv.Velocity
            local ov = inst and inst.m_fOwnerVelocityLength or -1
            local ws = inst and inst.m_fWantedSpeed or -1
            local fm = inst and A.path(inst.m_FreeMoveAnimContainer.m_animation) or "-"
            return string.format("%s vel %.0f animVel %.0f wanted %.0f mode %s status %s freeMove %s", who,
                math.sqrt(v.X * v.X + v.Y * v.Y), ov, ws, tostring(mv.MovementMode), tostring(A.moveStatus(ch)),
                tostring(fm))
        end)
        return okA and s or (who .. " error " .. tostring(s))
    end
    U.log("locomotion: %s | %s", describe("me", myPawn()), describe("puppet", puppet()))
    return false
end

function M.start()
    N.on("act", onAct)
    N.on("actend", onActEnd)
    U.poll("moves send", SEND_MS, sendTick)
    U.poll("moves stats", 20000, function()
        if stats.acts + stats.played > 0 then
            U.log("moves: %d actions sent, %d partner actions played (%d mirrored), %d animations missing", stats.acts,
                stats.played, stats.mirrored, stats.missing)
        end
        return false
    end)
end

return M
