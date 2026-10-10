-- tc_anim: reading what animation a Sifu character is playing, and playing it on another character.
-- Sifu's UPlayerAnim keeps its current actions in plain structs (the data its replay system records):
--   FAnimContainer { UAnimSequence* m_animation; bool m_bMirror; bool m_bLoopable; float m_fStartRatio;
--                    uint8 m_uiOrderID; float m_fPlayRate }
--   m_AttackStruct / m_DodgeStruct: FAnimStructBase { m_AnimContainer1, m_AnimContainer2 } (swapped per action)
--   m_animInfo1..4: FAnimInfo { m_bActionInProgress, m_AnimToPlay, m_fPlayRate, m_bMirror, m_fStartRatio, ... }
local U = require("tc_util")

local A = {}

-- Sifu's character anim graph (Wuguan_Character_AnimationBlueprint) has no DefaultSlot: its only slots are
-- "Cinematic" and "Cinematic2". A montage on any other slot plays without affecting the pose.
A.SLOT = "Cinematic"

function A.animInstance(character)
    if not U.valid(character) then return nil end
    local ok, inst = pcall(function() return character.Mesh:GetAnimInstance() end)
    return ok and U.valid(inst) and inst or nil
end

local function path(obj)
    if not U.valid(obj) then return nil end
    return obj:GetFullName():match("%s(.+)$")
end
A.path = path

local function container(c, kind)
    local ok, r = pcall(function()
        local anim = c.m_animation
        if not U.valid(anim) then return nil end
        return { kind = kind, path = path(anim), asset = anim, mirror = c.m_bMirror, rate = c.m_fPlayRate,
                 start = c.m_fStartRatio, order = c.m_uiOrderID }
    end)
    return ok and r or nil
end

local function info(i, kind)
    local ok, r = pcall(function()
        if not i.m_bActionInProgress then return nil end
        local anim = i.m_AnimToPlay
        if not U.valid(anim) then return nil end
        return { kind = kind, path = path(anim), asset = anim, mirror = i.m_bMirror, rate = i.m_fPlayRate,
                 start = i.m_fStartRatio, order = 0 }
    end)
    return ok and r or nil
end

-- Everything that looks like an action animation right now (for logging / discovery).
function A.actions(inst)
    local out = {}
    if not inst then return out end
    for _, f in ipairs({ "m_AttackStruct", "m_DodgeStruct" }) do
        local ok, s = pcall(function() return inst[f] end)
        if ok and s then
            for _, c in ipairs({ "m_AnimContainer1", "m_AnimContainer2" }) do
                local okC, cc = pcall(function() return s[c] end)
                local r = okC and cc and container(cc, f .. "." .. c) or nil
                if r then out[#out + 1] = r end
            end
        end
    end
    for n = 1, 4 do
        local ok, i = pcall(function() return inst["m_animInfo" .. n] end)
        local r = ok and i and info(i, "m_animInfo" .. n) or nil
        if r then out[#out + 1] = r end
    end
    return out
end

-- Raw action reader -------------------------------------------------------------------------------------
-- UE4SS's Lua doesn't see fields a struct inherits (FSwapperStructBase -> FAnimStructBase -> FAnimStructAttack), and
-- m_animInfo1..4 only exist on UAnimInstanceWithDependancy, not on UPlayerAnim - so the reads above find nothing.
-- These offsets (game 1.28, CXXHeaderDump + ObjectDump) are read through TailCoop_Peek instead.
local PLAYER_ANIM_STRUCTS = {  -- swapper structs of UPlayerAnim that play one-shot actions
    { "attack", 0x940 }, { "dodge", 0xBA0 }, { "override", 0xC40 }, { "weapon", 0xDD0 }, { "emote", 0xF20 },
}
local IN_PROGRESS = { 0x51, 0x52 }  -- FSwapperStructBase::m_bInProgress1/2
local CONTAINER = { 0x58, 0x70 }    -- FAnimStructBase::m_AnimContainer1/2
-- FAnimContainer: m_animation 0x0, m_bMirror 0x8, m_fStartRatio 0xC, m_uiOrderID 0x10, m_fPlayRate 0x14
local LAST_ANIM, LAST_MIRROR, LAST_CURSOR = 0xE68, 0xE70, 0xE74

local playerAnimClass
local isPlayerAnimCache = {}  -- anim instance address -> bool (an object's class never changes)
local function isPlayerAnim(inst)
    local key = inst:GetAddress()
    local known = isPlayerAnimCache[key]
    if known ~= nil then return known end
    if not U.valid(playerAnimClass) then playerAnimClass = StaticFindObject("/Script/Sifu.PlayerAnim") end
    local ok, yes = pcall(function() return inst:IsA(playerAnimClass) end)
    isPlayerAnimCache[key] = (ok and yes) and true or false
    return isPlayerAnimCache[key]
end

-- Fast path: the whole read in one native call (TailCoop_ReadAnim), parsed here.
local TRACK_NAMES = { "attack1", "attack2", "dodge1", "dodge2", "override1", "override2", "weapon1", "weapon2",
    "emote1", "emote2" }

local function readNative(inst, subAddrs, text)
    text = text or TailCoop_ReadAnim(tostring(inst:GetAddress()), table.unpack(subAddrs))
    local tracksText, lastText, subsText = text:match("^([^|]*)|([^|]*)|(.*)$")
    local tracks = {}
    for k, ptr, order, mirror, start, rate in (tracksText or ""):gmatch("(%d+),(%d+),(%d+),(%d),([-%d%.]+),([-%d%.]+);") do
        tracks[#tracks + 1] = { key = TRACK_NAMES[tonumber(k)], ptr = math.tointeger(tonumber(ptr)), order = tonumber(order),
            mirror = mirror == "1", start = tonumber(start), rate = tonumber(rate) }
    end
    local lp, lm, lc = (lastText or ""):match("^(%d+),(%d),([-%d%.]+)$")
    local last = { ptr = math.tointeger(tonumber(lp or "0")) or 0, mirror = lm == "1", cursor = tonumber(lc or "0") or 0 }
    local subs, i = {}, 0
    for ptr, order, alpha, mirror, start, rate in (subsText or ""):gmatch("(%d+),(%d+),([-%d%.]+),(%d),([-%d%.]+),([-%d%.]+);") do
        i = i + 1
        local p = math.tointeger(tonumber(ptr))
        if p and p ~= 0 then
            subs[#subs + 1] = { key = "sub" .. subAddrs[i], ptr = p, order = tonumber(order), alpha = tonumber(alpha),
                mirror = mirror == "1", start = tonumber(start), rate = tonumber(rate) }
        end
    end
    return tracks, last, subs
end

local pathCache = {}
function A.pathOf(ptr)
    if not ptr or ptr == 0 then return nil end
    local p = pathCache[ptr]
    if p == nil then
        p = TailCoop_ObjectPath(tostring(ptr)) or false
        pathCache[ptr] = p
    end
    return p or nil
end

local function peek(base, off, kind) return TailCoop_Peek(base, tostring(off), kind) end

-- Every action track playing right now: { key, ptr, mirror, start, order, rate }, plus the anim's "last action"
-- (ptr, mirror, cursor in seconds). nil if this isn't a UPlayerAnim or the native reader is missing.
function A.readRaw(inst)
    if not (TailCoop_Peek and inst and isPlayerAnim(inst)) then return nil end
    local base = tostring(inst:GetAddress())
    local tracks = {}
    for _, s in ipairs(PLAYER_ANIM_STRUCTS) do
        for n = 1, 2 do
            if (peek(base, s[2] + IN_PROGRESS[n], "u8") or 0) ~= 0 then
                local c = s[2] + CONTAINER[n]
                local ptr = peek(base, c, "ptr")
                if ptr and ptr ~= 0 then
                    tracks[#tracks + 1] = {
                        key = s[1] .. n, ptr = ptr, mirror = (peek(base, c + 0x8, "u8") or 0) ~= 0,
                        start = peek(base, c + 0xC, "f32") or 0, order = peek(base, c + 0x10, "u8") or 0,
                        rate = peek(base, c + 0x14, "f32") or 1,
                    }
                end
            end
        end
    end
    local last = {
        ptr = peek(base, LAST_ANIM, "ptr") or 0, mirror = (peek(base, LAST_MIRROR, "u8") or 0) ~= 0,
        cursor = peek(base, LAST_CURSOR, "f32") or 0,
    }
    return tracks, last
end

-- Sifu plays most orders (attacks, dodges, parries, hit reactions) through linked sub anim instances
-- (GenericPlayAnimBP_C : UPlayAnimSubAnimInstance), each holding the sequence it plays:
--   m_AnimContainerToPlay 0x630 (FAnimContainer), m_uiOrderID 0x654, m_fGlobalAlpha 0x658.
-- Their outer is the character's skeletal mesh. One FindAllOf for everyone (it walks every object in the game),
-- refreshed every 2 s - a character's sub-instances are created with its anim instance, so they rarely change.
local SUB_CONTAINER, SUB_ORDER, SUB_ALPHA = 0x630, 0x654, 0x658
local subCache = { at = -1e9, byMesh = {} }

-- Preferred: the mesh's own list of its linked anim instances (USkeletalMeshComponent::LinkedInstances, reflected),
-- filtered to the order sub-instances - no walk over every object. Per mesh, refreshed every 2 s.
local linkedCache = {}  -- mesh address -> { at, list }
local playAnimSubClass
local playAnimSubIs = {}  -- anim instance address -> bool
local function linkedSubInstances(mesh, now)
    local key = mesh:GetAddress()
    local c = linkedCache[key]
    if c and now - c.at < 2000 then return c.list end
    playAnimSubClass = U.valid(playAnimSubClass) and playAnimSubClass or StaticFindObject("/Script/Sifu.PlayAnimSubAnimInstance")
    local list = {}
    local ok = pcall(function()
        mesh.LinkedInstances:ForEach(function(_, el)
            local inst = el:get()
            if not U.valid(inst) then return end
            local a = inst:GetAddress()
            local is = playAnimSubIs[a]
            if is == nil then
                is = inst:IsA(playAnimSubClass) and true or false
                playAnimSubIs[a] = is
            end
            if is then list[#list + 1] = tostring(a) end
        end)
    end)
    if not c then
        U.log("anim: %s lists %d order sub-instance(s) itself%s", U.shortName(mesh:GetOuter()), #list,
            ok and "" or " (reading LinkedInstances failed)")
    end
    if not ok or #list == 0 then  -- fall back to the object walk below (asked again in 2 s)
        linkedCache[key] = { at = now, list = nil }
        return nil
    end
    linkedCache[key] = { at = now, list = list }
    return list
end
A.linkedSubInstances = linkedSubInstances

local function subInstancesOf(meshAddr, now, mesh)
    if mesh then
        local list = linkedSubInstances(mesh, now)
        if list then return list end
    end
    if now - subCache.at > 2000 or (not subCache.byMesh[meshAddr] and now - subCache.at > 500) then
        subCache.at, subCache.byMesh = now, {}
        local ok, all = pcall(FindAllOf, "PlayAnimSubAnimInstance")
        for _, s in ipairs(ok and all or {}) do
            local okO, outer = pcall(function() return s:GetOuter() end)
            if okO and U.valid(outer) and not s:GetFullName():find("Default__", 1, true) then
                local k = outer:GetAddress()
                subCache.byMesh[k] = subCache.byMesh[k] or {}
                table.insert(subCache.byMesh[k], tostring(s:GetAddress()))
            end
        end
    end
    return subCache.byMesh[meshAddr] or {}
end

-- { key, ptr, mirror, start, order, rate, alpha } per sub instance of `character`'s mesh.
function A.readSubs(character, now)
    local okM, mesh = pcall(function() return character.Mesh end)
    if not (okM and U.valid(mesh)) then return {} end
    local out = {}
    for _, base in ipairs(subInstancesOf(mesh:GetAddress(), now)) do
        local ptr = peek(base, SUB_CONTAINER, "ptr")
        if ptr and ptr ~= 0 then
            out[#out + 1] = {
                key = "sub" .. base, ptr = ptr, mirror = (peek(base, SUB_CONTAINER + 0x8, "u8") or 0) ~= 0,
                start = peek(base, SUB_CONTAINER + 0xC, "f32") or 0, order = peek(base, SUB_ORDER, "u8") or 0,
                rate = peek(base, SUB_CONTAINER + 0x14, "f32") or 1, alpha = peek(base, SUB_ALPHA, "f32") or 0,
            }
        end
    end
    return out
end

-- Follows one character's actions frame by frame. update(character, nowMs) returns nil, or
--   { kind = "start", path, mirror, rate, start (ratio), cursor (seconds, -1 = unknown), track }
--   { kind = "end" }
-- Sources: the order sub anim instances (a new order id = a new action), the main anim's swapper structs, and its
-- "last action" pointer. What's already there on the first read is old and not reported.
function A.watcher()
    local w = { prev = {}, subs = {}, current = nil, lastPtr = nil, recent = {}, primed = false }
    function w:update(character, now)
        local t0 = U.tick()
        -- The character's mesh and anim instance, looked up again only every second (or when gone, or when another
        -- character now stands behind the same id: arena pools, stand-ins).
        local charAddr = character:GetAddress()
        if not (self.inst and self.mesh and now - (self.cachedAt or 0) < 1000 and self.charAddr == charAddr
                and U.valid(self.inst)) then
            self.charAddr = charAddr
            self.inst = A.animInstance(character)
            local okM, mesh = pcall(function() return character.Mesh end)
            self.mesh = okM and U.valid(mesh) and mesh or nil
            self.cachedAt = now
        end
        local inst = self.inst
        local tracks, last, nativeSubs
        if TailCoop_ReadAnim and inst and self.mesh and isPlayerAnim(inst) then
            self.instStr = self.instStr or tostring(inst:GetAddress())
            self.meshAddr = self.meshAddr or self.mesh:GetAddress()
            if self.cachedAt == now then self.instStr, self.meshAddr = tostring(inst:GetAddress()), self.mesh:GetAddress() end
            local subs = subInstancesOf(self.meshAddr, now, self.mesh)
            local text = TailCoop_ReadAnim(self.instStr, table.unpack(subs))
            -- Nothing changed since last frame (most frames): nothing to report, no parsing.
            if text == self.lastText and self.primed then
                U.tock("action read: anim tracks", t0)
                return nil
            end
            self.lastText = text
            tracks, last, nativeSubs = readNative(inst, subs, text)
        else
            tracks, last = A.readRaw(inst)
        end
        U.tock("action read: anim tracks", t0)
        if not tracks then return nil end
        local seen, started = {}, nil
        for _, t in ipairs(tracks) do
            local sig = t.ptr .. ":" .. t.order
            seen[t.key] = sig
            if self.primed and self.prev[t.key] ~= sig then started = t end
        end
        self.prev = seen
        -- Sub instances keep their last sequence after it ends, so only a change of sequence/order id counts.
        -- m_fGlobalAlpha (the sub instance's weight) is only trusted as an end signal for the current action once it
        -- has been seen above 0.5 during it.
        local liveSub, alphaOf = false, {}
        local t1 = U.tick()
        local subs = nativeSubs or A.readSubs(character, now)
        U.tock("action read: sub instances", t1)
        for _, s in ipairs(subs) do
            local sig = s.ptr .. ":" .. s.order
            if self.primed and self.subs[s.key] ~= sig then started = s end
            self.subs[s.key] = sig
            alphaOf[s.key] = s.alpha
            if s.alpha > 0.05 then liveSub = true end
        end
        if self.current and (alphaOf[self.current] or 0) > 0.5 then self.alphaSeen = true end
        if not self.alphaSeen and self.current and self.current:sub(1, 3) == "sub" then liveSub = true end
        self.primed = true
        for p, at in pairs(self.recent) do
            if now - at > 1200 then self.recent[p] = nil end
        end
        -- A new "last action": another animation, or the same one started again (its cursor jumped back).
        local restarted = last.ptr == self.lastPtr and self.lastCursor and last.cursor < self.lastCursor - 0.15
        local lastChanged = last.ptr ~= 0 and (last.ptr ~= self.lastPtr or restarted)
        if restarted then self.recent[last.ptr] = nil end
        self.lastPtr, self.lastCursor = last.ptr, last.cursor
        if started then
            self.current, self.alphaSeen = started.key, false
            self.recent[started.ptr] = now
            return { kind = "start", path = A.pathOf(started.ptr), mirror = started.mirror,
                     rate = started.rate > 0 and started.rate or 1, start = started.start, cursor = -1,
                     track = started.key }
        end
        -- The last-action cursor is a 0..1 ratio (reads 1.00 once an action has finished).
        if lastChanged and not self.recent[last.ptr] and last.cursor < 0.9 then
            self.current = "last"
            self.recent[last.ptr] = now
            return { kind = "start", path = A.pathOf(last.ptr), mirror = last.mirror, rate = 1, start = last.cursor,
                     cursor = -1, track = "last" }
        end
        -- End: nothing left playing (no swapper track, no sub instance with weight). The "last" source has no end
        -- signal; its animation just plays out on the copy.
        if self.current and self.current ~= "last" and next(seen) == nil and not liveSub then
            self.current = nil
            return { kind = "end" }
        end
        return nil
    end
    return w
end

-- Seconds into `asset` to start from: the sender's cursor (or start ratio x length) + time in transit.
function A.startTime(asset, cursor, startRatio, delayMs, rate)
    local t = cursor or -1
    if t < 0 then
        local okL, len = pcall(function() return asset.SequenceLength end)
        len = okL and tonumber(len) or 0
        t = (startRatio or 0) * len
    end
    return math.max(0, t + (delayMs or 0) / 1000 * (rate or 1))
end

-- Sifu plays many moves mirrored (left/right swapped) through its anim graph; a dynamic montage can't. Instead the
-- character's mesh is reflected across its left/right axis, which mirrors the whole pose the same way. The mesh is
-- yawed relative to the actor (forward is the mesh's +Y for UE characters), so the axis to flip depends on that yaw.
-- The mirror stays until the next action, like Sifu's stance side does.
function A.setMirror(character, on)
    local ok, err = pcall(function()
        local mesh = character.Mesh
        local scale = mesh.RelativeScale3D
        if ((scale.X * scale.Y) < 0) == (on and true or false) then return end
        local yaw = mesh.RelativeRotation.Yaw % 180
        local sideIsX = yaw > 45 and yaw < 135
        local s = on and -1 or 1
        local x, y = math.abs(scale.X), math.abs(scale.Y)
        mesh:SetRelativeScale3D(sideIsX and { X = s * x, Y = y, Z = scale.Z } or { X = x, Y = s * y, Z = scale.Z })
    end)
    if not ok then U.log("anim: mirror failed: %s", tostring(err)) end
end

-- Plays a sequence on a character through a dynamic montage in the given slot. Returns the montage or nil.
function A.play(character, asset, rate, startTime, blendIn, blendOut, mirror)
    local inst = A.animInstance(character)
    if not (inst and U.valid(asset)) then return nil end
    if mirror ~= nil then A.setMirror(character, mirror) end
    local ok, montage = pcall(function()
        return inst:PlaySlotAnimationAsDynamicMontage(asset, FName(A.SLOT), blendIn or 0.08, blendOut or 0.15,
            rate and rate > 0 and rate or 1.0, 1, -1.0, startTime or 0.0)
    end)
    if not ok then
        U.log("anim: play failed: %s", tostring(montage))
        return nil
    end
    return U.valid(montage) and montage or nil
end

function A.stop(character, blendOut)
    local inst = A.animInstance(character)
    if inst then pcall(function() inst:StopSlotAnimation(blendOut or 0.15, FName(A.SLOT)) end) end
end

-- Characters we move ourselves (the partner's puppet, enemy copies the host drives) -----------------------
-- Sifu's anim graph ignores everything played from outside: montages in any slot, velocity, movement input and AI
-- MoveTo all leave a copy sliding in idle (measured: -Test walkprobe2, stride between the feet stays constant).
-- So a copy's mesh is switched to single-node playback (USkeletalMeshComponent::PlayAnimation, Sifu's 5-argument
-- version) and TailCoop picks what it plays: the owner's action sequences (attacks, dodges, hit reactions...) and,
-- between actions, Sifu's own walk/run cycles from the copy's speed and direction, or its idle.
-- (-Test tickdiag: with the script instance kept, no single-node player exists and nothing plays; replaced, it plays.)

function A.makeDriven(actor)
    local ok, err = pcall(function()
        actor.CharacterMovement:SetMovementMode(0, 0)  -- MOVE_None: we place it every frame
    end)
    if not ok then U.log("anim: makeDriven failed: %s", tostring(err)) end
end

-- Makes a character invisible but leaves it in the game (collision, hits, Sifu logic). Sifu turns visibility back on
-- in places (seen in -Test enemytwin), so callers repeat it every frame; it only acts when something is visible.
local primitiveClass
function A.hideReal(character, components)
    local ok, err = pcall(function()
        if not character.bHidden then character:SetActorHiddenInGame(true) end
        if not components then return end
        primitiveClass = primitiveClass or StaticFindObject("/Script/Engine.PrimitiveComponent")
        local comps = character:K2_GetComponentsByClass(primitiveClass)
        local function hide(c)
            pcall(function()
                local okV, vis = pcall(function() return c:IsVisible() end)
                if not okV then
                    c = c:get()  -- wrapped array element
                    vis = c:IsVisible()
                end
                if vis then c:SetVisibility(false, false) end
            end)
        end
        if type(comps) == "table" then
            for _, c in ipairs(comps) do hide(c) end
        elseif comps and comps.ForEach then
            comps:ForEach(function(_, elem) hide(elem) end)
        end
    end)
    if not ok then U.log("anim: hide failed: %s", tostring(err)) end
end

-- Places the copy and measures its velocity from that motion (smoothed, capped against snapshot hiccups) into st.
-- A copy standing still isn't moved again (re-placed every 250 ms anyway); the move itself is one native call.
local MAX_SPEED = 1500
local placeFn
local function place(actor, st, x, y, z, yaw, now)
    local p = st.placed
    if p and now - p.at < 250 and p.x == x and p.y == y and p.z == z and p.yaw == yaw then return end
    st.placed = { at = now, x = x, y = y, z = z, yaw = yaw }
    if TailCoop_Place then
        if not (placeFn and U.valid(placeFn.obj)) then
            local f = StaticFindObject("/Script/Engine.Actor:K2_SetActorLocationAndRotation")
            placeFn = U.valid(f) and { obj = f, addr = tostring(f:GetAddress()) } or nil
        end
        if placeFn and not placeFn.refused then
            local ok, us = TailCoop_Place(tostring(actor:GetAddress()), placeFn.addr, tostring(x), tostring(y),
                tostring(z), tostring(yaw))
            if ok then
                U.tock("engine move (inside drive)", U.tick() - us)
                return
            end
            if us and us < -1 then
                -- The engine function isn't laid out as expected (another game version): the Lua call from now on.
                placeFn.refused = true
                U.log("anim: native place refused (parameter size %d): placing through Lua", -us)
            end
        end
    end
    actor:K2_SetActorLocationAndRotation({ X = x, Y = y, Z = z }, { Pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
end

A.place = place

function A.drive(actor, st, x, y, z, yaw, now)
    place(actor, st, x, y, z, yaw, now)
    if st.t then
        local dt = (now - st.t) / 1000
        if dt > 0.001 then
            local k = 0.2
            local mx, my = (x - st.x) / dt, (y - st.y) / dt
            local len = math.sqrt(mx * mx + my * my)
            if len > MAX_SPEED then mx, my = mx / len * MAX_SPEED, my / len * MAX_SPEED end
            st.vx = (st.vx or 0) * (1 - k) + mx * k
            st.vy = (st.vy or 0) * (1 - k) + my * k
        end
    end
    st.t, st.x, st.y, st.yaw = now, x, y, yaw
end

-- Locomotion cycles per anim class (Sifu's own sequences; speeds in cm/s the cycle was authored for).
local LOCO_SETS = {
    { match = "Wuguan_MC_", base = "/Game/Animations/MainChar/Locomotion/Man/Barehands/Moving/",
      tense = { N = "V1/Lockmove/North/MC_man_barehands_V1_north_tense", NE = "V1/Lockmove/North_east/MC_man_barehands_V1_northEast_tense",
                E = "V1/Lockmove/East/MC_man_barehands_V1_east_front_tense", SE = "V1/Lockmove/South_east/MC_man_barehands_V1_southEast_tense",
                S = "V1/Lockmove/South/MC_man_barehands_V1_south_tense", SW = "V1/Lockmove/South_west/MC_man_barehands_V1_southWest_tense",
                W = "V1/Lockmove/West/MC_man_barehands_V1_west_front_tense", NW = "V1/Lockmove/North_west/MC_man_barehands_V1_northWest_tense" },
      tenseSpeed = 250, idleFree = "V0/MC_man_barehands_V0_front",
      free = { { 0, "V1/Freemove/North/MC_man_barehands_V1_north", 250 }, { 380, "V2/North/MC_man_barehands_V2_north", 480 },
               { 620, "V3/North/MC_man_barehands_V3_north", 700 } } },
    { match = "Wuguan_Grunt_", base = "/Game/Animations/Grunt/Locomotion/Barehands/Moving/",
      tense = { N = "V1/Lockmove/North/Grunt_barehands_V1_North_tense", NE = "V1/Lockmove/NorthEast/Grunt_barehands_V1_NorthEast_tense",
                E = "V1/Lockmove/East/Grunt_barehands_V1_East_Front_tense", SE = "V1/Lockmove/SouthEast/Grunt_barehands_V1_SouthEast_tense",
                S = "V1/Lockmove/South/Grunt_barehands_V1_south_tense", SW = "V1/Lockmove/SouthWest/Grunt_barehands_V1_SouthWest_tense",
                W = "V1/Lockmove/West/Grunt_barehands_V1_West_Front_tense", NW = "V1/Lockmove/NorthWest/Grunt_barehands_V1_NorthWest_tense" },
      tenseSpeed = 250, idleFree = "V0/Lockmove/North/Grunt_barehands_V0_north_relax",
      free = { { 0, "V1/Freemove/Grunt_barehands_V1_North_relax", 250 }, { 380, "V2/Freemove/Grunt_barehands_V2_North_relax", 480 },
               { 620, "V3/Freemove/Grunt_barehands_V3_North_relax", 700 } } },
}
local DIRS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
local MOVE_START, MOVE_STOP = 60, 30  -- speed (cm/s) hysteresis

local seqCache = {}
local function sequence(path)
    local full = path:find("%.") and path or (path .. "." .. path:match("([^/]+)$"))
    local s = seqCache[full]
    if s and U.valid(s) then return s end
    s = StaticFindObject(full)
    if not U.valid(s) then
        local ok, l = pcall(LoadAsset, full)
        s = ok and l or nil
    end
    if U.valid(s) then seqCache[full] = s else s = nil end
    return s
end
A.sequence = sequence

-- Characters Sifu's own combat code runs on (the partner's character, hittable since enemies fight both players)
-- must keep their animation instance: replacing it while one of their orders runs crashes the game (null read at
-- +0x630 in the order code, seen when the partner disconnected mid-fight). Copies of these only follow the exact
-- pose (tc_pose); without one they keep Sifu's own animation.
local protected = {}
function A.protect(character) protected[character:GetAddress()] = true end

local function playOnMesh(character, asset, loop, rate, startTime)
    if protected[character:GetAddress()] then return false end
    local ok, err = pcall(function()
        local mesh = character.Mesh
        mesh:PlayAnimation(asset, loop, false, false, false)
        mesh:SetPlayRate(rate or 1.0)
        if startTime and startTime > 0 then mesh:SetPosition(startTime, false) end
    end)
    if not ok then U.log("anim: play on %s failed: %s", U.shortName(character), tostring(err)) end
    return ok
end

-- Stance: which way a fighter stands (UPlayerAnim::m_eAnimQuadrant 0x930, EQuadrantTypes): 0 FrontLeft,
-- 1 FrontRight, 2 BackRight, 3 BackLeft. Each has its own combat idle (m_IdleAnimContainerFL/FR/BR/BL: sequence +
-- mirror flag) - showing the FL idle for a fighter standing FR is what made copies look "flipped".
local QUADRANT = 0x930
local QUADRANT_NAMES = { [0] = "FL", [1] = "FR", [2] = "BR", [3] = "BL" }

function A.quadrant(inst)
    if not (TailCoop_Peek and inst and isPlayerAnim(inst)) then return nil end
    local q = peek(tostring(inst:GetAddress()), QUADRANT, "u8")
    return (q and q <= 3) and q or nil
end

-- Right-foot-forward stances: the left-foot movement cycles play mirrored (and left/right directions swap).
local function mirroredStance(q) return q == 1 or q == 2 end
local SWAP_SIDES = { N = "N", NE = "NW", E = "W", SE = "SW", S = "S", SW = "SE", W = "E", NW = "NE" }

-- Takes over a copy's animation. Reads what it needs from Sifu's anim instance (class -> cycles, its idle
-- sequences) before that instance is replaced. st: the copy's state table (same one drive() uses).
function A.copyInit(character, st)
    if st.animInit then return end
    st.animInit = true
    local inst = A.animInstance(character)
    local name = inst and inst:GetClass():GetFName():ToString() or ""
    for _, set in ipairs(LOCO_SETS) do
        if name:find(set.match, 1, true) then st.locoSet = set end
    end
    st.idles = {}
    local found = {}
    for q, suffix in pairs(QUADRANT_NAMES) do
        pcall(function()
            local c = inst["m_IdleAnimContainer" .. suffix]
            local anim = c.m_animation
            if U.valid(anim) then
                st.idles[q] = { asset = anim, mirror = c.m_bMirror and true or false }
                found[#found + 1] = string.format("%s=%s%s", suffix, A.path(anim):match("[^/.]+$") or "?",
                    c.m_bMirror and "(mirrored)" or "")
            end
        end)
    end
    st.idleTense = st.idles[0] and st.idles[0].asset or nil
    st.idleFree = st.locoSet and sequence(st.locoSet.base .. st.locoSet.idleFree) or nil
    st.actionUntil, st.locoKey = 0, nil
    U.log("anim: copy %s (%s): cycles %s, idles %s", U.shortName(character), name,
        st.locoSet and st.locoSet.match or "none", table.concat(found, " "))
end

-- An action (attack, dodge, hit reaction...): plays once from startTime (s) at rate; locomotion resumes after it.
function A.copyAction(character, st, asset, rate, startTime, mirror, now)
    if protected[character:GetAddress()] then return false end
    A.copyInit(character, st)
    -- Hit reactions start at rate ~0.2 (Sifu's hit-freeze, a tenth of a second) and then speed back up; only the
    -- starting rate is known here, so a freeze rate is played as normal speed (it showed 5x slow-motion otherwise).
    rate = (rate and rate >= 0.5) and rate or 1.0
    A.setMirror(character, mirror)
    if not playOnMesh(character, asset, false, rate, startTime) then return false end
    local okL, len = pcall(function() return asset.SequenceLength end)
    len = okL and tonumber(len) or 1.0
    st.actionUntil = now + math.max(0.05, (len - (startTime or 0)) / rate) * 1000
    st.locoKey = nil
    return true
end

-- The owner's action ended early (cancelled): hand back to locomotion now.
function A.copyActionEnd(st)
    st.actionUntil = 0
end

-- Lab check that a copy really animates: distance between its feet, min/max since the last report.
-- Walking opens and closes it (tens of cm); sliding keeps it constant. Returns "range now/what" and resets.
function A.strideSample(character, st)
    if st.feet == nil then
        st.feet = false
        pcall(function()
            local mesh = character.Mesh
            local l, r
            for i = 0, mesh:GetNumBones() - 1 do
                local fn = mesh:GetBoneName(i)
                local n = fn:ToString():lower()
                if n == "foot_l" then l = fn elseif n == "foot_r" then r = fn end
            end
            if l and r then st.feet = { l, r } end
        end)
    end
    if not st.feet then return end
    local ok, d = pcall(function()
        local a, b = character.Mesh:GetSocketLocation(st.feet[1]), character.Mesh:GetSocketLocation(st.feet[2])
        return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2)
    end)
    if ok then
        st.strideMin = math.min(st.strideMin or d, d)
        st.strideMax = math.max(st.strideMax or d, d)
    end
end

function A.strideReport(st)
    if not st.strideMin then return "stride ?" end
    local s = string.format("stride range %.0f", st.strideMax - st.strideMin)
    st.strideMin, st.strideMax = nil, nil
    return s .. " anim " .. tostring(st.locoKey or (st.actionUntil and "action" or "-"))
end

-- Every frame after drive(): walk/run cycle or idle, unless an action is playing. tense = combat stance;
-- quadrant = the owner's stance (A.quadrant on their side), nil if unknown.
function A.copyLocomotion(character, st, tense, now, quadrant)
    if protected[character:GetAddress()] then return end
    A.copyInit(character, st)
    if now < (st.actionUntil or 0) then return end
    local vx, vy = st.vx or 0, st.vy or 0
    local speed = math.sqrt(vx * vx + vy * vy)
    local wasMoving = st.locoKey and st.locoKey:sub(1, 4) ~= "idle"
    local moving = speed > (wasMoving and MOVE_STOP or MOVE_START)
    local set = st.locoSet
    local key, asset, rate, nominal, mirror = nil, nil, 1.0, nil, false
    if moving and set then
        local path
        if tense then
            -- Direction of travel relative to facing, in 8 sectors (N = forward, E = right).
            local rel = (math.deg(math.atan(vy, vx)) - (st.yaw or 0) + 360) % 360
            local dir = DIRS[math.floor((rel + 22.5) / 45) % 8 + 1]
            if mirroredStance(quadrant) then dir, mirror = SWAP_SIDES[dir], true end
            path, nominal = set.tense[dir], set.tenseSpeed
        else
            for _, f in ipairs(set.free) do
                if speed >= f[1] then path, nominal = f[2], f[3] end
            end
        end
        key, asset = path, sequence(set.base .. path)
        rate = math.max(0.6, math.min(1.6, speed / nominal))
    elseif tense then
        local idle = st.idles and (st.idles[quadrant or 0] or st.idles[0])
        asset, mirror = idle and idle.asset or st.idleFree, idle and idle.mirror or false
        key = "idle" .. tostring(quadrant or 0)
    else
        key, asset = "idle", st.idleFree or st.idleTense
    end
    if not asset then return end
    key = key .. (mirror and "|m" or "")
    if key ~= st.locoKey then
        A.setMirror(character, mirror)
        if playOnMesh(character, asset, true, rate, 0) then st.locoKey, st.locoRate = key, rate end
    elseif math.abs(rate - (st.locoRate or 1)) > 0.08 then
        pcall(function() character.Mesh:SetPlayRate(rate) end)
        st.locoRate = rate
    end
end

-- Sifu's combat/exploration stance lives in the movement component (EMoveStatus).
function A.moveStatus(character)
    local ok, s = pcall(function() return character.CharacterMovement.m_eMoveStatus end)
    return ok and s or nil
end

function A.setMoveStatus(character, status)
    pcall(function() character.CharacterMovement:BPF_SetMoveStatus(status) end)
end

return A
