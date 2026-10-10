-- tc_aggro: enemies fight both players (G6), and run where they fight.
-- Host decides, for every enemy, which player it fights (UAIFightingComponent:BPF_ForceEnemy): the nearer one,
-- sticking with its choice unless the other is clearly closer; an enemy just hit by a player turns on that player.
-- The enemy's AI then runs in that player's game (tc_enemies ownership: handed over between its actions), so that
-- player's hits, blocks, parries and dodges against it are all local and exact.
-- Both games: the partner's character here (the puppet) is hittable. When an enemy we run hits it (captured
-- FightingCharacter:Hitted, routed here by tc_enemies), the hit is forwarded ("phit": hit as Unreal text, the enemy's
-- and the puppet's paths as $I$ / $T$) and applied to the partner's real player through its own hit pipeline
-- (HitComponent:BPF_GenerateForeignImpact) with their copy of that enemy as the instigator, 100 ms late (when that
-- copy, shown 100 ms in the past, visibly connects). Their defense decides; a parry / dodge is reported back ("pout")
-- and replayed here with the puppet deflecting / avoiding, so the enemy gets Sifu's own outcome.
local U = require("tc_util")
local N = require("tc_net")
local S = require("tc_session")
local F = require("tc_flow")
local Hits = require("tc_hits")

local AG = {}

local ASSIGN_MS = 500
-- Every change of target hands the enemy to the other game (its AI restarts there, its copy swaps): kept rare.
-- (Lab, 2026-10-09: 3 s / 30% made 40 handovers in 3 minutes among 7 enemies - the user saw enemies jerk and spin.)
local HOLD_MS = 6000          -- minimum time an enemy keeps its target before the nearer player can take it
local SWITCH_RATIO = 0.6      -- switch only if the other player is at least 40% closer
local PROVOKED_MS = 4000      -- an enemy a player just hit goes after that player this long
local PROVOKE_SWITCH_MS = 4000  -- ...if it hasn't changed target in this long
local APPLY_DELAY_MS = 100    -- = the copies' interpolation delay

local choice = {}      -- host: enemy id -> { target = "host"|"join", since }
local provoked = {}    -- host: enemy id -> { by = "host"|"join", at }
local stats = { assigned = 0, hitsOut = 0, hitsIn = 0, applied = 0, failed = 0 }

local function puppet()
    local a = require("tc_presence").puppetActor()
    return U.valid(a) and a or nil
end

local function myPawn()
    local pc = U.playerController()
    return pc and U.valid(pc.Pawn) and pc.Pawn or nil
end

local function dist(a, b)
    local p, q = a:K2_GetActorLocation(), b:K2_GetActorLocation()
    return math.sqrt((p.X - q.X) ^ 2 + (p.Y - q.Y) ^ 2)
end

-- Host: a player hit enemy `id` ("host" / "join" / "partner" = join).
function AG.provoke(id, by)
    provoked[id] = { by = by == "partner" and "join" or by, at = TailCoop_Clock() }
end
AG.partnerHit = function(id) AG.provoke(id, "join") end

-- Host: who fights whom; ownership follows (tc_enemies.assign).
-- Each enemy prefers the nearer player (sticking with its choice unless the other is clearly closer), or the player
-- who just hit it; but while both players are in, neither gets more than half of the enemies (rounded up): the extra
-- ones - those with the least way to go to the other player - fight the other player, and keep to that a while.
-- (Without the cap, the crowd around one player drew in every enemy and the other player stood alone: lab
-- -Test arenacrowd, 6 enemies on the joiner and 0 on the host for two minutes.)
local BALANCED_HOLD_MS = 8000
local function assign(enemies, me, partner, now)
    local E = require("tc_enemies")
    local AR = require("tc_arena")
    -- A player who is out of an Arena challenge (game over, watching the partner) isn't fought, nor one whose game is
    -- paused (tc_presence: their world is frozen; the partner's goes on).
    local P = require("tc_presence")
    local hostOut = AR.isOut("host") or P.isPaused("host")
    local joinOut = AR.isOut("join") or P.isPaused("join")
    local items, count = {}, { host = 0, join = 0 }
    for _, e in ipairs(enemies) do
        if not E.isDead(e.id) then
            local ok, err = pcall(function()
                local c = choice[e.id] or { target = "host", since = 0 }
                choice[e.id] = c
                local it = { e = e, c = c, want = c.target }
                local p = provoked[e.id]
                if hostOut ~= joinOut then
                    it.want, it.pinned = hostOut and "join" or "host", true
                else
                    it.dHost = dist(e.actor, me)
                    it.dJoin = partner and dist(e.actor, partner) or math.huge
                    if p and now - p.at < PROVOKED_MS and (p.by == c.target or now - c.since > PROVOKE_SWITCH_MS) then
                        it.want, it.pinned = p.by, true
                    elseif now - c.since > HOLD_MS then
                        if c.target == "host" and it.dJoin < it.dHost * SWITCH_RATIO then it.want = "join" end
                        if c.target == "join" and it.dHost < it.dJoin * SWITCH_RATIO then it.want = "host" end
                    end
                end
                items[#items + 1] = it
                count[it.want] = count[it.want] + 1
            end)
            if not ok and not (choice[e.id] or {}).err then
                choice[e.id] = choice[e.id] or {}
                choice[e.id].err = true
                U.log("aggro: assigning %s failed: %s", e.id, tostring(err))
            end
        end
    end
    if partner and not (hostOut or joinOut) then
        local cap = math.ceil(#items / 2)
        for _, side in ipairs({ "host", "join" }) do
            local otherSide = side == "host" and "join" or "host"
            if count[side] > cap then
                local movable = {}
                for _, it in ipairs(items) do
                    if it.want == side and not it.pinned then movable[#movable + 1] = it end
                end
                -- Least extra way to the other player first.
                local function extra(it)
                    return side == "host" and (it.dJoin - it.dHost) or (it.dHost - it.dJoin)
                end
                table.sort(movable, function(a, b) return extra(a) < extra(b) end)
                for _, it in ipairs(movable) do
                    if count[side] <= cap then break end
                    it.want, it.balanced = otherSide, true
                    count[side], count[otherSide] = count[side] - 1, count[otherSide] + 1
                end
            end
        end
    end
    for _, it in ipairs(items) do
        local c = it.c
        if it.want ~= c.target then
            U.log("aggro: %s now fights the %s%s", it.e.id, it.want == "host" and "host" or "joiner",
                it.balanced and " (sharing the enemies)" or "")
            c.target = it.want
            -- Sent over to even the numbers: stays there a while, not straight back to the nearer player.
            c.since = it.balanced and now + BALANCED_HOLD_MS - HOLD_MS or now
        end
        pcall(E.assign, it.e.id, it.want, it.want)
        stats.assigned = stats.assigned + 1
    end
    AG.split = count
end

-- Both: the puppet is something our enemies can hit: collision on (it's placed by us, not moved by physics), full
-- health (the partner's own game owns their health), and its hits watched.
local preparedPuppet, watchedFn = nil, nil
local function preparePuppet(p)
    if preparedPuppet == p:GetAddress() then return end
    preparedPuppet = p:GetAddress()
    pcall(function() p:SetActorEnableCollision(true) end)
    local fn = Hits.functionFor(p, "Hitted")
    if fn and watchedFn ~= fn:GetAddress() then
        watchedFn = fn:GetAddress()
        local ok, err = TailCoop_WatchParam(tostring(fn:GetAddress()), tostring(Hits.SIZE.description))
        if not ok then U.log("aggro: can't watch hits on the partner's character: %s", tostring(err)) end
    end
    U.log("aggro: the partner's character %s can be attacked here", U.shortName(p))
end

-- Both: hits the partner's character took here (from tc_enemies' capture router). Only enemies we run count: the
-- partner's own game decides about the others, and friendly fire is off.
local hitSeq, sentHits = 0, {}
local friendly = { hits = 0 }
function AG.onCaptured(ctx, text)
    local p = puppet()
    if not (p and ctx == p:GetAddress()) then return end
    local pPath = Hits.pathOf(p)
    -- Our own player hitting the partner's character (should never happen: same faction as us, see preparePuppet).
    local me = myPawn()
    local myPath = me and Hits.pathOf(me)
    if myPath and text:find("m_Instigator=[^,]*" .. myPath:gsub("%p", "%%%0")) then
        friendly.hits = friendly.hits + 1
        if friendly.hits <= 10 then U.log("aggro: our own hit landed on the partner's character (ignored)") end
    end
    local E = require("tc_enemies")
    for _, e in ipairs(E.list()) do
        local ePath = E.mine(e.id) and Hits.pathOf(e.actor)
        if ePath and pPath and text:find("m_Instigator=[^,]*" .. ePath:gsub("%p", "%%%0")) then
            local t = Hits.replace(Hits.replace(text, ePath, "$I$"), pPath, "$T$")
            hitSeq = hitSeq + 1
            sentHits[hitSeq] = { id = e.id, text = text, at = TailCoop_Clock() }
            sentHits[hitSeq - 40] = nil
            N.sendLarge("phit", e.id .. "\n" .. hitSeq .. "\n" .. t)
            stats.hitsOut = stats.hitsOut + 1
            if stats.hitsOut <= 30 then U.log("aggro: %s hit the partner, forwarded", e.id) end
            break
        end
    end
    pcall(function()
        local hc = p.m_HealthComponent
        hc:BPF_ServerSetHealth(hc.m_fMaxHealth)
    end)
end

-- Both (enemy owner): the partner parried / dodged one of our enemy's hits in their game. Here it already landed
-- on their character, so it's played again with that character's guard in its Deflect state (EGuardType 2, parry)
-- or set to avoid: Sifu's defense code then gives our enemy the matching outcome (a parried enemy is staggered).
-- Only lands if the enemy is still in that attack (~1 round trip later).
local foreignImpactFn
local checks = {}
local function onOutcome(f)
    local id, seq, kind = f[1], tonumber(f[2]), f[3]
    local sent = seq and sentHits[seq]
    local p = puppet()
    if not (sent and p) then return end
    local m = Hits.members(sent.text)
    foreignImpactFn = foreignImpactFn or StaticFindObject("/Script/Sifu.HitComponent:BPF_GenerateForeignImpact")
    local dc = p.m_DefenseComponent
    pcall(function()
        if kind == "parry" then
            dc:BPF_SetIsAutoDeflect(true)
            dc:BPF_SetGuardType(2, false)
        else
            dc:BPF_SetAutoAvoid(true)
        end
    end)
    local ok, err = TailCoop_CallImported(tostring(p.m_HitComponent:GetAddress()), tostring(foreignImpactFn:GetAddress()),
        m.m_Result, tostring(Hits.SIZE.result), m.m_Request, tostring(Hits.SIZE.request))
    pcall(function()
        if kind == "parry" then
            dc:BPF_SetGuardType(0, false)
            dc:BPF_SetIsAutoDeflect(false)
        else
            dc:BPF_SetAutoAvoid(false)
        end
    end)
    stats.outcomes = (stats.outcomes or 0) + 1
    U.log("aggro: the partner %s %s's hit (%d ms ago): %s", kind == "parry" and "parried" or "dodged", id,
        TailCoop_Clock() - sent.at, ok and "replayed here" or ("FAILED " .. tostring(err)))
    checks[#checks + 1] = { id = id, kind = kind, at = TailCoop_Clock() }
end

-- Lab: what the enemy did right after a replayed parry / dodge (its next action within 250 ms).
local function checkReactions(now)
    for i = #checks, 1, -1 do
        local c = checks[i]
        if now - c.at > 250 then
            table.remove(checks, i)
            local a = require("tc_enemies").lastActionOf(c.id)
            local reacted = a and a.at >= c.at - 20
            U.log("aggro: after the replayed %s, %s %s", c.kind, c.id,
                reacted and ("plays " .. (a.path:match("[^/]+$") or a.path)) or "started nothing new")
        end
    end
end

-- Both (attacked player): partner's enemy hit us -------------------------------------------------------------------

local pending = {}  -- hits waiting for their moment: { at, id, seq, text }

local function onHitUs(payload)
    local id, seq, text = payload:match("^([^\n]*)\n([^\n]*)\n(.*)$")
    if not id then return end
    stats.hitsIn = stats.hitsIn + 1
    pending[#pending + 1] = { at = TailCoop_Clock() + APPLY_DELAY_MS, id = id, seq = seq, text = text }
end

-- What our defense made of a hit we applied: the first action our character starts right after it. Parries and
-- dodges are reported to the enemy's owner (onOutcome there); a block or a hit changes nothing for the enemy.
local outcomes = {}
local function classify(path)
    local p = path:lower()
    if p:find("/deflect/") or p:find("parry") then return "parry" end
    if p:find("dodge") or p:find("avoid") then return "avoid" end
    if p:find("guard") then return "block" end
    return "hit"
end

local function reportOutcomes(now)
    local last = require("tc_moves").lastOwnAction
    local i = 1
    while i <= #outcomes do
        local o = outcomes[i]
        local kind = last and last.at >= o.at - 5 and classify(last.path) or nil
        if kind or now - o.at > 300 then
            table.remove(outcomes, i)
            kind = kind or "hit"
            stats[kind] = (stats[kind] or 0) + 1
            if kind == "parry" or kind == "avoid" then
                N.send(true, "pout", o.id, o.seq, kind)
                U.log("aggro: we %s the partner's %s", kind == "parry" and "parried" or "dodged", o.id)
            end
        else
            i = i + 1
        end
    end
end

local foreignImpactFnUs
local function applyPending(now)
    local i = 1
    while i <= #pending do
        local h = pending[i]
        if now >= h.at then
            table.remove(pending, i)
            local me = myPawn()
            local enemy = require("tc_enemies").localActorFor(h.id)
            if not (me and enemy) then
                stats.failed = stats.failed + 1
                U.log("aggro: hit from the partner's %s dropped (%s)", h.id, me and "no copy of that enemy" or "no player")
            else
                local t = Hits.replace(Hits.replace(h.text, "$I$", Hits.pathOf(enemy)), "$T$", Hits.pathOf(me))
                local m = Hits.members(t)
                foreignImpactFnUs = foreignImpactFnUs or StaticFindObject("/Script/Sifu.HitComponent:BPF_GenerateForeignImpact")
                local before = me.m_HealthComponent.m_fHealth
                local ok, err, warnings = TailCoop_CallImported(tostring(me.m_HitComponent:GetAddress()),
                    tostring(foreignImpactFnUs:GetAddress()), m.m_Result, tostring(Hits.SIZE.result), m.m_Request,
                    tostring(Hits.SIZE.request))
                if ok then
                    stats.applied = stats.applied + 1
                    outcomes[#outcomes + 1] = { id = h.id, seq = h.seq, at = now }
                    require("tc_moves").readFastUntil = now + 400  -- our defense's first action, read every frame
                else
                    stats.failed = stats.failed + 1
                end
                if not ok or stats.applied <= 30 then
                    U.log("aggro: hit by the partner's %s: %s, %d warnings, our health %.0f -> %.0f", h.id,
                        ok and "applied" or ("FAILED " .. tostring(err)), warnings or -1, before,
                        me.m_HealthComponent.m_fHealth)
                end
            end
        else
            i = i + 1
        end
    end
end

-- No friendly fire ------------------------------------------------------------------------------------------------
-- Who may target / hit whom is Sifu's faction table (UFactionsManager::m_FactionsTargetTable at +0x28, 6x6 bytes,
-- row = attacker faction, column = target; read by ThePlainesGameInstance:BPF_CanTargetFaction and by the native
-- target picking and hit checks). Players are TMP_Neutral (5, BP_TPSCharacter), enemies Faction2 (BP_AICharacter_Base);
-- those are the only two set in the game's data. Neutral may attack everyone, neutral included - so our player locked
-- onto the partner's character and hit it. While a session runs, that one entry (neutral -> neutral) is "no";
-- enemies' rows are untouched, so they still go for both players. Restored when the session ends.
local TABLE_OFFSET, FACTIONS = 0x28, 6
local friendlyFire = { at = -1e9 }  -- { manager address, original value, entry offset }

local function factionOf(actor)
    local ok, f = pcall(function() return actor.m_eFaction end)
    return ok and tonumber(f) or nil
end

local function restoreFriendlyFire()
    local ff = friendlyFire
    if ff.manager and ff.original then
        TailCoop_PokeU8(tostring(ff.manager), tostring(ff.entry), tostring(ff.original))
        U.log("aggro: friendly fire setting restored")
    end
    friendlyFire = { at = -1e9 }
end

local function noFriendlyFire(me, p, now)
    if not TailCoop_PokeU8 or now - friendlyFire.at < 2000 then return end
    if U.config.test == "friendlyoff" then return end  -- lab: the game's own setting, for comparison
    friendlyFire.at = now
    local mine, theirs = factionOf(me), factionOf(p)
    if not (mine and theirs) or mine >= FACTIONS or theirs >= FACTIONS then return end
    if mine ~= theirs then
        -- Not what the game's data gives players: leave Sifu's table alone rather than change a whole relation.
        if not friendlyFire.warned then
            friendlyFire.warned = true
            U.log("aggro: our faction %d, partner's character %d: friendly fire left as Sifu has it", mine, theirs)
        end
        return
    end
    local ok, fm = pcall(function() return FindFirstOf("ThePlainesGameInstance").m_FactionsManager end)
    if not (ok and U.valid(fm)) then return end
    local manager = fm:GetAddress()
    local entry = TABLE_OFFSET + mine * FACTIONS + theirs
    local current = TailCoop_Peek(tostring(manager), tostring(entry), "u8")
    if current == nil or current == 0 then return end
    if friendlyFire.manager ~= manager then
        friendlyFire.manager, friendlyFire.entry, friendlyFire.original = manager, entry, current
    end
    if TailCoop_PokeU8(tostring(manager), tostring(entry), "0") then
        U.log("aggro: friendly fire off (faction %d can't target faction %d while the session runs)", mine, theirs)
    end
end

-- The faction table stops our player choosing the partner as a target (no turning / lunging at them). A punch thrown
-- right at them still connects, though - Sifu's hit detection doesn't ask the table - so those hits are refused too:
-- TailCoopNative answers "no" for the partner's character's HitComponent:BPE_ValidateHit when the attacker is us.
local guard = {}
local function guardHits(me, p)
    if not TailCoop_GuardHits then return end
    local key = tostring(me:GetAddress()) .. ":" .. tostring(p:GetAddress())
    if guard.key == key then return end
    local ok, err = pcall(function()
        local hc = p.m_HitComponent
        local fn = Hits.functionFor(hc, "BPE_ValidateHit")
        if not (U.valid(hc) and fn) then error("no HitComponent / BPE_ValidateHit") end
        if not TailCoop_GuardHits(tostring(fn:GetAddress()), tostring(hc:GetAddress()), tostring(me:GetAddress())) then
            error("native guard refused the addresses")
        end
    end)
    guard.key = key
    U.log("aggro: %s", ok and "our hits on the partner's character are refused" or ("hit guard failed: " .. tostring(err)))
end

local function unguardHits()
    if guard.key and TailCoop_GuardHits then TailCoop_GuardHits("0", "0", "0") end
    guard = {}
end

function AG.friendlyReport()
    local seen, refused, all = 0, 0, 0
    if TailCoop_GuardStats then seen, refused, all = TailCoop_GuardStats() end
    return string.format("our own hits on the partner's character: %d landed, %d refused (hits checked there %d, "
        .. "anywhere %d)", friendly.hits, refused, seen, all or 0)
end

-- Wiring ---------------------------------------------------------------------------------------------------------

function AG.start()
    N.on("phit", onHitUs)
    N.on("pout", onOutcome)
    S.onChange(function()
        if not S.connected() then
            restoreFriendlyFire()
            unguardHits()
        end
    end)
    U.poll("aggro", 10, function()
        if not (S.connected() and F.activity) then
            preparedPuppet, pending, choice, provoked = nil, {}, {}, {}
            return false
        end
        local now = TailCoop_Clock()
        local p, me = puppet(), myPawn()
        if p then preparePuppet(p) end
        if p and me then
            noFriendlyFire(me, p, now)
            if U.config.test ~= "friendlyoff" then guardHits(me, p) end
        end
        applyPending(now)
        reportOutcomes(now)
        checkReactions(now)
        -- (With the joiner out of an Arena challenge its character is gone here: everything fights the host.)
        if S.role == "host" and me and (p or require("tc_arena").isOut("join"))
            and now - (AG.lastAssign or 0) >= ASSIGN_MS then
            AG.lastAssign = now
            assign(require("tc_enemies").list(), me, p, now)
        end
        return false
    end)
    U.poll("aggro stats", 20000, function()
        if S.connected() and F.activity then
            U.log("aggro: %s, hits on the partner forwarded %d / partner's enemies' hits received %d, applied %d, "
                .. "failed %d | our defense: parry %d, avoid %d, block %d, hit %d | replayed here %d", S.role,
                stats.hitsOut, stats.hitsIn, stats.applied, stats.failed, stats.parry or 0, stats.avoid or 0,
                stats.block or 0, stats.hit or 0, stats.outcomes or 0)
        end
        return false
    end)
end

return AG
