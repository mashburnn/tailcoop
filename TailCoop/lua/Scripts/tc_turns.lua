-- tc_turns: enemies take turns attacking across both games ("turns = shared" in TailCoop.ini, the default).
-- Sifu's AI hands out attack tickets per target: an enemy attacks only while it holds one, the others wait around it.
-- Each game hands them out to the enemies it runs (the ones fighting its own player: tc_aggro, tc_enemies ownership),
-- so with two players two attacks came at once, one on each, and the fight was twice as busy as in single player.
-- Shared: while an attack is under way on one player (a ticket held on them, in either game), the enemies fighting
-- the other player can't take a ticket; once it's over, the other player's enemies go first for a moment (if any are
-- fighting them), then both sides may again. The host decides from both games' counts; the gate is Sifu's own
-- UAIFightingComponent:BPF_SetCanTakeAttackTicket on every enemy run here.
-- (First version: a "turn" that stayed with one side until its attack ended or 2.5 s passed. The other side's enemies
-- were held back most of the time, Sifu demoted them all to non-opponents (they stayed away), and the joiner was
-- never attacked again - lab -Test arenacrowd. Now a side is only held back while the other is actually attacked.)
-- "turns = each": Sifu's tickets per player, untouched (each player fought as in single player).
local U = require("tc_util")
local N = require("tc_net")
local S = require("tc_session")
local F = require("tc_flow")

local TT = {}

local TICK_MS = 100
local GAP_MS = 300        -- an attack is over once no ticket has been held on its player this long
local PRIORITY_MS = 1200  -- then the other player's enemies go first this long
local MAX_HOLD_MS = 6000  -- one side attacking longer than this doesn't hold the other back any more
local REPORT_MS = 500     -- joiner -> host counts at least this often (and on every change)

TT.allow = { host = true, join = true }  -- may the enemies fighting this player take a ticket now?
local counted = { me = { held = 0, fighting = 0 }, partner = { held = 0, fighting = 0 } }  -- enemies run here
local reported = { me = { held = 0, fighting = 0 }, partner = { held = 0, fighting = 0 }, at = -1e9 }  -- joiner's
local side = {
    host = { lastHeld = -1e9, heldSince = nil, attacking = false },
    join = { lastHeld = -1e9, heldSince = nil, attacking = false },
}
local priority = { who = nil, untilAt = 0 }
local lastReport, lastSent, lastBroadcast, lastAllowText = "", -1e9, -1e9, ""
local stats = { attacks = { host = 0, join = 0 }, alternations = 0, lastAttacker = nil, held = { host = 0, join = 0 },
    gated = 0, ticks = 0 }
local active = false

local function other(role) return role == "host" and "join" or "host" end
local function shared() return U.config.turns ~= "each" end

-- Somebody must be able to attack each player. Sifu picks combat roles again only on events (a death, a takedown...),
-- and enemies made non-opponents while held back could all stay that way: with the last two of a group left, nobody
-- attacked for minutes and the next wave never came (lab ArenaFight -Swap). So when the enemies fighting our player
-- may attack but none is a direct opponent or has held a ticket for 2 s, the nearest one is made a direct opponent.
-- (Both players: enemies the host keeps for good - the joiner's copy is a stand-in that can't fight - fight the joiner
-- from here, through the partner's character.)
local ROLE_DIRECT, PROMOTE_MS = 1, 2000
local idleSince = {}

local function promoteNearest(list, now, which)
    local foe
    if which == "me" then
        local pc = U.playerController()
        foe = pc and pc.Pawn
    else
        foe = require("tc_presence").puppetActor()
    end
    if not U.valid(foe) then return end
    local m = foe:K2_GetActorLocation()
    local best, bestD = nil, math.huge
    for _, e in ipairs(list) do
        local ok, l = pcall(function() return e.actor:K2_GetActorLocation() end)
        if ok then
            local d = (l.X - m.X) ^ 2 + (l.Y - m.Y) ^ 2
            if d < bestD then best, bestD = e, d end
        end
    end
    if best and pcall(function() best.ai:BPF_SwitchToCombatRole(ROLE_DIRECT) end) then
        stats.promoted = (stats.promoted or 0) + 1
        if stats.promoted <= 20 then
            U.log("turns: nobody was coming for the %s: %s made a direct opponent (%.0f m away)",
                which == "me" and "player here" or "partner", best.id, math.sqrt(bestD) / 100)
        end
    end
end

-- Every enemy run here: whom it fights, whether it holds a ticket; and its gate.
local function countAndGate(now)
    local E = require("tc_enemies")
    local c = { me = { held = 0, fighting = 0 }, partner = { held = 0, fighting = 0 } }
    local mine, direct = { me = {}, partner = {} }, { me = false, partner = false }
    for _, e in ipairs(E.running()) do
        local target = E.targetOf(e.id) or S.role
        local which = target == S.role and "me" or "partner"
        if not (e.ai and U.valid(e.ai)) then
            local ok, ai = pcall(function() return e.actor.m_AIComponent end)
            e.ai = ok and U.valid(ai) and ai or nil
        end
        local ai = e.ai
        if ai then
            c[which].fighting = c[which].fighting + 1
            local ok, held = pcall(function() return ai:BPF_HasAttackTicket() end)
            if ok and held then c[which].held = c[which].held + 1 end
            -- Running here but unable to move (movement off, as a copy has it): it turned on the spot and swung at
            -- whoever came near - "stuck, attacks sped up, turns 360 in place". Walking again (checked every second).
            -- (Only once it's in a fight and has been here a while: arena enemies come in with their movement off -
            -- climbing in, getting up - and that's Sifu's own doing.)
            if now - (e.moveCheckAt or 0) >= 1000 and now - (e.foundAt or now) > 5000 then
                e.moveCheckAt = now
                local okM, mode = pcall(function() return e.actor.CharacterMovement.MovementMode end)
                local okF, inFight = pcall(function() return ai:BPF_GetCurrentCombatRole() ~= 0 end)
                if okM and tonumber(mode) == 0 and okF and inFight then
                    pcall(function() e.actor.CharacterMovement:SetMovementMode(1, 0) end)
                    stats.unstuck = (stats.unstuck or 0) + 1
                    if stats.unstuck <= 20 then U.log("turns: %s was running here with its movement off: walking again", e.id) end
                end
            end
            local okR, role = pcall(function() return ai:BPF_GetCurrentCombatRole() end)
            mine[which][#mine[which] + 1] = e
            if okR and role == ROLE_DIRECT then direct[which] = true end
            -- Running here but in nobody's fight (combat role None: a handover's "fight this player" didn't take -
            -- lab: two such enemies stood by the joiner for minutes): perception on and the order again, every 2 s.
            if okR and role == 0 and now - (e.engageAt or 0) >= 2000 then
                e.engageAt = now
                local P = require("tc_presence")
                local pc = U.playerController()
                local foe = target == S.role and (pc and pc.Pawn) or P.puppetActor()
                if U.valid(foe) and pcall(function()
                    ai:BPF_SetPerceptionEnabled(true)
                    ai:BPF_ForceEnemy(foe, 3)  -- EGlobalBehaviors::Alerted
                end) then
                    stats.engaged = (stats.engaged or 0) + 1
                    if stats.engaged <= 20 then U.log("turns: %s was in nobody's fight: sent at the %s", e.id,
                        which == "me" and "us" or "partner") end
                end
            end
            local allowed = not shared() or TT.allow[target] ~= false
            -- Set when it changes, and again every 2 s (the game may reset it: spawns, phases).
            if e.turnGate ~= allowed or now - (e.turnGateAt or 0) > 2000 then
                if pcall(function() ai:BPF_SetCanTakeAttackTicket(allowed) end) then
                    if e.turnGate ~= allowed then stats.gated = stats.gated + 1 end
                    e.turnGate, e.turnGateAt = allowed, now
                end
            end
        end
    end
    counted = c
    for _, which in ipairs({ "me", "partner" }) do
        local role = which == "me" and S.role or (S.role == "host" and "join" or "host")
        if #mine[which] > 0 and c[which].held == 0 and not direct[which] and (not shared() or TT.allow[role] ~= false) then
            idleSince[which] = idleSince[which] or now
            if now - idleSince[which] >= PROMOTE_MS then
                idleSince[which] = now  -- (again in 2 s if that didn't take)
                promoteNearest(mine[which], now, which)
            end
        else
            idleSince[which] = nil
        end
    end
end

-- Host: both games' counts for one player.
local function total(role)
    local here = role == S.role and counted.me or counted.partner
    local fresh = TailCoop_Clock() - reported.at < 2000
    local there = fresh and (role == S.role and reported.partner or reported.me) or { held = 0, fighting = 0 }
    return here.held + there.held, here.fighting + there.fighting
end

local function broadcast(now)
    local text = (TT.allow.host and "1" or "0") .. (TT.allow.join and "1" or "0")
    if text ~= lastAllowText or now - lastBroadcast > 1000 then
        lastAllowText, lastBroadcast = text, now
        N.send(true, "turn", TT.allow.host and 1 or 0, TT.allow.join and 1 or 0)
    end
end

-- An enemy's action that is an attack (its animation path; reactions, guards, dodges and deaths aren't).
function TT.isAttackPath(p)
    p = p and p:lower() or ""
    if p:find("hitreaction") or p:find("hitted") or p:find("parr") or p:find("guard") or p:find("dodge")
        or p:find("avoid") or p:find("death") or p:find("dizzy") then return false end
    return p:find("attack") ~= nil or p:find("combo") ~= nil
end

-- Host: players with an attack animation under way on them (tickets can be given back before the blow lands).
-- Every enemy's actions are known here: ours from the watchers, the joiner's from its "eact".
local ATTACK_ANIM_MS = 1200
local function attacksUnderWay(now)
    local E = require("tc_enemies")
    local on = {}
    for _, e in ipairs(E.list()) do
        local a = E.actionNow(e.id)
        if a and now - a.at < ATTACK_ANIM_MS and not E.isDead(e.id) then
            if a.attack == nil then a.attack = TT.isAttackPath(a.path) end
            if a.attack then on[E.targetOf(e.id) or E.ownerOf(e.id)] = true end
        end
    end
    return on
end

local function decide(now)
    local fighting = {}
    local animated = attacksUnderWay(now)
    for _, who in ipairs({ "host", "join" }) do
        local held, fight = total(who)
        fighting[who] = fight
        local s = side[who]
        if held > 0 or animated[who] then
            s.lastHeld = now
            s.heldSince = s.heldSince or now
            stats.held[who] = stats.held[who] + 1
        else
            s.heldSince = nil
        end
        local attacking = now - s.lastHeld < GAP_MS
        if attacking and not s.attacking then
            stats.attacks[who] = stats.attacks[who] + 1
            if stats.lastAttacker and stats.lastAttacker ~= who then stats.alternations = stats.alternations + 1 end
            stats.lastAttacker = who
        elseif s.attacking and not attacking and fighting[who] ~= nil then
            -- This side's attack is over: the other side's enemies go first for a moment.
            priority.who, priority.untilAt = other(who), now + PRIORITY_MS
        end
        s.attacking = attacking
    end
    stats.ticks = stats.ticks + 1
    for _, who in ipairs({ "host", "join" }) do
        local o = side[other(who)]
        local otherBusy = o.attacking and not (o.heldSince and now - o.heldSince > MAX_HOLD_MS)
        local otherFirst = priority.who == other(who) and now < priority.untilAt and fighting[other(who)] > 0
            and not side[who].attacking
        -- Nobody fights the other player: nothing to take turns with.
        if fighting[other(who)] == 0 then otherBusy, otherFirst = false, false end
        TT.allow[who] = not (otherBusy or otherFirst)
    end
    broadcast(now)
end

-- Joiner: our counts to the host (on change, and every REPORT_MS).
local function report(now)
    local c = counted
    local text = c.me.held .. "|" .. c.me.fighting .. "|" .. c.partner.held .. "|" .. c.partner.fighting
    if text ~= lastReport or now - lastSent >= REPORT_MS then
        lastReport, lastSent = text, now
        N.send(false, "tstate", c.me.held, c.me.fighting, c.partner.held, c.partner.fighting)
    end
end

-- Everyone may take tickets again (session or activity over). Every enemy known here, not only the ones we ran:
-- after "leave" no enemy counts as ours any more, and one held back would never attack again.
local function openAll()
    TT.allow = { host = true, join = true }
    for _, e in ipairs(require("tc_enemies").list()) do
        if e.turnGate == false and not e.dormant then
            pcall(function() e.actor.m_AIComponent:BPF_SetCanTakeAttackTicket(true) end)
        end
        e.turnGate = nil
    end
end

function TT.stats()
    local t = math.max(1, stats.ticks)
    return string.format("attacks on host %d / joiner %d, alternations %d, ticket held on host %.0f%% / joiner %.0f%% "
        .. "of the time, now allowed host %s joiner %s, gates set %d, promoted %d, sent back into the fight %d, "
        .. "movement put back %d", stats.attacks.host, stats.attacks.join, stats.alternations, 100 * stats.held.host / t,
        100 * stats.held.join / t, tostring(TT.allow.host), tostring(TT.allow.join), stats.gated, stats.promoted or 0,
        stats.engaged or 0, stats.unstuck or 0)
end

function TT.start()
    N.on("turn", function(f)
        if S.role ~= "host" then TT.allow = { host = f[1] ~= "0", join = f[2] ~= "0" } end
    end)
    N.on("tstate", function(f)
        reported.me = { held = tonumber(f[1]) or 0, fighting = tonumber(f[2]) or 0 }
        reported.partner = { held = tonumber(f[3]) or 0, fighting = tonumber(f[4]) or 0 }
        reported.at = TailCoop_Clock()
    end)
    F.onMapChange(function()
        TT.allow = { host = true, join = true }
        priority = { who = nil, untilAt = 0 }
        for _, s in pairs(side) do s.lastHeld, s.heldSince, s.attacking = -1e9, nil, false end
    end)
    if shared() then U.log("turns: shared (one player attacked at a time)") else U.log("turns: per player") end
    U.poll("turns", TICK_MS, function()
        if not (S.connected() and F.activity) then
            if active then
                active = false
                openAll()
                U.log("turns: off (%s)", TT.stats())
            end
            return false
        end
        active = true
        local now = TailCoop_Clock()
        countAndGate(now)
        if not shared() then return false end
        if S.role == "host" then decide(now) else report(now) end
        return false
    end)
    U.poll("turns stats", 20000, function()
        if active then U.log("turns: %s", TT.stats()) end
        return false
    end)
end

-- Lab: tickets held / enemies fighting per player, as counted here ({ me, partner }).
function TT.counted() return counted end

return TT
