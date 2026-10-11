-- tc_gear: what a character holds (weapons), shown on its copy in the other game.
-- Owner side (each player for their own character, the host for enemies): every 200 ms, the weapons attached to the
-- character (ABaseWeapon actors whose attach parent is it) are described as their visible meshes and where each sits
-- relative to the hand socket it's attached to; sent as "gear|id|socket|part~part..." when it changes (and every 3 s,
-- so a copy spawned later catches up). Receiver: the copy gets plain mesh components with the same meshes attached to
-- the same socket of its mesh, so they follow the bone-exact pose. No weapon actor is spawned on the other side (no
-- pickups, no AI interest, no physics).
local U = require("tc_util")
local N = require("tc_net")

local G = {}

local SEND_MS, RESEND_MS = 200, 3000

local classes = {}
local function class(path)
    local c = classes[path]
    if not U.valid(c) then
        c = StaticFindObject(path)
        classes[path] = c
    end
    return c
end

-- Array elements from UE4SS come wrapped (element:get() is the object) or as the object itself.
local function unwrap(v)
    local ok, inner = pcall(function() return v:get() end)
    return ok and inner or v
end

local function each(arr, fn)
    if type(arr) == "table" then
        for _, v in ipairs(arr) do fn(unwrap(v)) end
    elseif arr and arr.ForEach then
        arr:ForEach(function(_, el) fn(unwrap(el)) end)
    end
end

-- Rounded so float noise in a held weapon's placement doesn't read as a change (0.5 mm, ~0.1 degree).
local function fmt3(v) return string.format("%.1f,%.1f,%.1f", v.X, v.Y, v.Z) end
local function fmt4(q)
    local s = q.W < 0 and -1 or 1  -- q and -q are the same rotation: one sign only
    return string.format("%.3f,%.3f,%.3f,%.3f", s * q.X, s * q.Y, s * q.Z, s * q.W)
end

-- Weapons held by `character` (attached to it). The character's own picked-up weapon first (one call); the level's
-- weapon actors (FindAllOf walks every object in the game) are listed at most every 2 s, shared by everyone, and
-- checked for weapons a character holds otherwise (e.g. an enemy spawned with one).
local weaponList = { at = -1e9, list = {} }
local function levelWeapons()
    local now = TailCoop_Clock()
    if now - weaponList.at > 2000 then
        local ok, all = pcall(FindAllOf, "BaseWeapon")
        weaponList.list, weaponList.at = ok and all or {}, now
    end
    return weaponList.list
end

-- The level-wide check (one engine call per weapon in the level) is redone at most once a second per character.
local heldScan = {}  -- character address -> { at, list }
local function heldWeapons(character)
    local key = character:GetAddress()
    local okW, w = pcall(function() return character:BPF_GetPickedUpWeapon() end)
    if okW and U.valid(w) then
        local okP, parent = pcall(function() return w:GetAttachParentActor() end)
        if okP and U.valid(parent) and parent:GetAddress() == key then return { w } end
    end
    local now = TailCoop_Clock()
    local cached = heldScan[key]
    if cached and now - cached.at < 1000 then
        local out = {}
        for _, lw in ipairs(cached.list) do if U.valid(lw) then out[#out + 1] = lw end end
        return out
    end
    local out = {}
    for _, lw in ipairs(levelWeapons()) do
        local okP, parent = pcall(function() return U.valid(lw) and lw:GetAttachParentActor() end)
        if okP and parent and U.valid(parent) and parent:GetAddress() == key then out[#out + 1] = lw end
    end
    heldScan[key] = { at = now, list = out }
    return out
end
G.heldWeapons = heldWeapons

-- A world weapon's identity in both games: the training rack that spawned it, or its level-placed actor name
-- (runtime-spawned actors get unique numbers per game and have none). nil if it has none.
-- Weapon racks are level actors: listed once per world (and again every 10 s).
local spawnerList = { at = -1e9, list = {}, world = nil }
local function spawners()
    local now = TailCoop_Clock()
    local w = U.world()
    local wk = w and w:GetAddress()
    if now - spawnerList.at > 10000 or spawnerList.world ~= wk then
        local ok, all = pcall(FindAllOf, "BP_Training_WeaponSpawner_C")
        spawnerList.list, spawnerList.at, spawnerList.world = ok and all or {}, now, wk
    end
    return spawnerList.list
end

local function originOf(w)
    for _, s in ipairs(spawners()) do
        local ok, same = pcall(function() return U.valid(s.WeaponSpawned) and s.WeaponSpawned:GetAddress() == w:GetAddress() end)
        if ok and same then return "spawner:" .. s:GetFName():ToString() end
    end
    local name = w:GetFName():ToString()
    local n = tonumber(name:match("_(%d+)$") or "")
    if n and n < 100000 then return "actor:" .. name end
    return nil
end

-- Our game's weapon for an origin key, or nil.
local function localWeapon(origin)
    local kind, name = origin:match("^(%a+):(.+)$")
    if kind == "spawner" then
        for _, s in ipairs(spawners()) do
            if s:GetFName():ToString() == name and U.valid(s.WeaponSpawned) then return s.WeaponSpawned end
        end
    elseif kind == "actor" then
        for _, w in ipairs(levelWeapons()) do
            if U.valid(w) and w:GetFName():ToString() == name then return w end
        end
    end
    return nil
end

-- "socket|kind;asset;loc;rot;scale~...|origin" for what `character` holds, or "" for nothing.
function G.describe(character)
    local mesh = character.Mesh
    local kml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local meshClass = class("/Script/Engine.MeshComponent")
    local parts, socket, origin, held = {}, nil, nil, nil
    for _, w in ipairs(heldWeapons(character)) do
        origin = origin or originOf(w)
        held = held or w
        local okS, s = pcall(function() return w:GetAttachParentSocketName():ToString() end)
        socket = okS and s or "None"
        local socketXf = mesh:GetSocketTransform(FName(socket), 0)  -- RTS_World
        each(w:K2_GetComponentsByClass(meshClass), function(c)
            local okPart, errPart = pcall(function()
                if not c:IsVisible() then return end
                local kind, asset
                if U.valid(c.StaticMesh) then
                    kind, asset = "S", c.StaticMesh
                elseif U.valid(c.SkeletalMesh) then
                    kind, asset = "K", c.SkeletalMesh
                else
                    return
                end
                local rel = kml:MakeRelativeTransform(c:K2_GetComponentToWorld(), socketXf)
                parts[#parts + 1] = table.concat({ kind, asset:GetFullName():match("%s(.+)$"), fmt3(rel.Translation),
                    fmt4(rel.Rotation), fmt3(rel.Scale3D) }, ";")
            end)
            if not okPart and G.lastError ~= tostring(errPart) then
                G.lastError = tostring(errPart)
                U.log("gear: reading a part of %s failed: %s", U.shortName(w), G.lastError)
            end
        end)
    end
    if #parts == 0 then return "", nil, nil end
    return socket .. "|" .. table.concat(parts, "~") .. "|" .. (origin or ""), origin, held
end

-- Same gear? Same socket and meshes, each placed within 1 cm / ~1 degree (float noise and rounding never count).
local function nums(s)
    local t = {}
    for v in s:gmatch("[-%d%.]+") do t[#t + 1] = tonumber(v) end
    return t
end

local function sameGear(a, b)
    if a == b then return true end
    if not a or not b or a == "" or b == "" then return false end
    local sa, pa, oa = a:match("^([^|]*)|([^|]*)|?(.*)$")
    local sb, pb, ob = b:match("^([^|]*)|([^|]*)|?(.*)$")
    if sa ~= sb or oa ~= ob then return false end
    local listA, listB = {}, {}
    for part in pa:gmatch("[^~]+") do listA[#listA + 1] = part end
    for part in pb:gmatch("[^~]+") do listB[#listB + 1] = part end
    if #listA ~= #listB then return false end
    for i = 1, #listA do
        local ka, assetA, restA = listA[i]:match("^(%a);([^;]+);(.*)$")
        local kb, assetB, restB = listB[i]:match("^(%a);([^;]+);(.*)$")
        if ka ~= kb or assetA ~= assetB then return false end
        local na, nb = nums(restA), nums(restB)
        for k = 1, math.min(#na, #nb) do
            local tol = (k >= 4 and k <= 7) and 0.01 or 1.0  -- quaternion components / cm
            if math.abs(na[k] - nb[k]) > tol then return false end
        end
    end
    return true
end
G.sameGear = sameGear

-- Weapons a character of ours let go of without a throw (dropped, disarmed, died with it): origin -> { actor, at, sends }.
-- The throws section only follows what it sees in the air, scanned 5 times a second - an enemy's weapon falling as it
-- died was never seen (user's session: 0 throws streamed), and the partner's copy of it stayed hidden for good. Its rest
-- place is told instead (ownerTick), twice: once fallen, once settled.
local releases = {}

-- Owner side: sends `id`'s gear when it changes / every RESEND_MS. state: a table this function keeps state in.
function G.publish(character, id, state, now)
    if now - (state.at or 0) < SEND_MS then return end
    state.at = now
    local ok, desc, origin, heldActor = pcall(G.describe, character)
    if not ok then
        if not state.err then
            state.err = true
            U.log("gear: describing %s failed: %s", id, tostring(desc))
        end
        return
    end
    -- (A weapon let go of - thrown, dropped, disarmed - is followed by the throws section below, which shows its flight
    -- and where it comes to rest; one it doesn't see fly is told from releases.)
    if state.origin and state.origin ~= origin and state.heldActor and U.valid(state.heldActor) then
        local okL, l = pcall(function() return character:K2_GetActorLocation() end)
        releases[state.origin] = { actor = state.heldActor, at = now, sends = 0,
                                   from = okL and { x = l.X, y = l.Y, z = l.Z } or nil }
    end
    state.origin, state.heldActor = origin, heldActor
    local changed = state.sent == nil or not sameGear(desc, state.sent)
    if changed or now - (state.sentAt or 0) > RESEND_MS then
        if changed then
            U.log("gear: %s holds %s", id, desc == "" and "nothing" or desc:match("^[^|]*|[^;]*;([^;]*)"))
            state.sent = desc
        end
        desc = state.sent
        state.sentAt = now
        N.send(true, "gear", id, desc == "" and "-" or (desc:gsub("|", "^")))
    end
end

-- Receiver side -----------------------------------------------------------------------------------------------

local wanted = {}        -- id -> descriptor ("" = nothing)
local takenAway = {}     -- origin -> our weapon hidden because the partner holds theirs
local takenAt = {}       -- origin -> clock it was hidden
local freeSince = {}     -- origin -> clock since which no character of the partner's holds it (for takenAway ones)

-- Our hidden weapon for `origin`, if it still exists. Weapons go away during a fight (a bottle breaks, a pipe wears
-- down and is replaced by its worn version): touching the one we kept then crashed the game (lab, 2026-10-09: the
-- host's enemy let go of a worn pipe, the joiner moved its own long-gone pipe -> crash inside UE4SS).
local function takenWeapon(origin)
    local w = takenAway[origin]
    if w and not U.valid(w) then
        takenAway[origin], w = nil, nil
    end
    return w
end

-- Whether our player can pick it up: a weapon hidden here (the partner holds theirs, a stand-in) must not be - its
-- pickup prompt stayed up and took the E press (lab: the joiner's E went to the hidden copy of the machete the host
-- held, nothing was picked up).
local function setUsable(w, on)
    pcall(function() w.m_InteractionComponent:BPF_SetIsUsable(on) end)
end
G.setUsable = setUsable

local function setTaken(origin, on)
    local w = (not on and takenWeapon(origin)) or localWeapon(origin)
    if not w then
        takenAway[origin] = nil
        return
    end
    -- (Its collision stays on: a weapon lying loose with its collision off falls through the floor - lab, a pipe and a
    -- stick 1-1.4 km down by the time they were wanted back. Out of reach is the pickup prompt, setUsable.)
    pcall(function()
        w:SetActorHiddenInGame(on)
        if not on then w:SetActorEnableCollision(true) end
    end)
    setUsable(w, not on)
    takenAway[origin] = on and w or nil
    takenAt[origin] = on and TailCoop_Clock() or nil
    U.log("gear: our %s %s", origin, on and "is in the partner's hands: hidden" or "is back")
end

-- A weapon that fell through the floor (dropped while its collision was off - a hidden one) is put back where it was
-- let go of: from = { x, y, z } of the character that held it. True if it had to be.
function G.rescue(w, from)
    if not (from and U.valid(w)) then return false end
    local ok, l = pcall(function() return w:K2_GetActorLocation() end)
    if not ok or l.Z > from.z - 300 then return false end
    pcall(function()
        w:SetActorEnableCollision(true)
        w:K2_SetActorLocation({ X = from.x, Y = from.y, Z = from.z + 40 }, false, {}, true)
        w.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
    end)
    U.log("gear: %s had fallen through the floor (%.0f m down): put back where it was dropped", U.shortName(w),
        (from.z - l.Z) / 100)
    return true
end

local function onGear(f)
    local desc = f[2] == "-" and "" or ((f[2] or ""):gsub("%^", "|"))
    local before = wanted[f[1]]
    wanted[f[1]] = desc
    -- The partner took a world weapon both games have: ours goes out of sight (and reach) meanwhile.
    -- Only one lying loose here: one in a hand here is that same weapon in our copy of the same enemy's hand (an enemy
    -- spawned with it, or that picked it up in both games) - hidden as ours, it stayed hidden once we ran that enemy,
    -- in its hand and wherever it dropped it (user: "can't pick up dropped weapons"; lab: our own enemy holding a
    -- hidden bat) - or our own player's.
    local newOrigin = desc:match("^[^|]*|[^|]*|(.+)$")
    local oldOrigin = before and before:match("^[^|]*|[^|]*|(.+)$")
    if newOrigin and newOrigin ~= oldOrigin and not takenWeapon(newOrigin) then
        local w = localWeapon(newOrigin)
        local okP, parent = pcall(function() return w and w:GetAttachParentActor() end)
        if not (okP and parent ~= nil and U.valid(parent)) then setTaken(newOrigin, true) end
    end
end

-- The partner let go of it: ours appears where theirs came to rest.
local function onDrop(f)
    local origin = f[1]
    local w = takenWeapon(origin) or localWeapon(origin)
    if not (w and U.valid(w)) then
        takenAway[origin] = nil
        return
    end
    pcall(function()
        local x, y, z = f[2]:match("([^,]+),([^,]+),([^,]+)")
        local p, yw, rl = f[3]:match("([^,]+),([^,]+),([^,]+)")
        w:K2_SetActorLocationAndRotation({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) },
            { Pitch = tonumber(p), Yaw = tonumber(yw), Roll = tonumber(rl) }, false, {}, true)
    end)
    if takenAway[origin] then
        setTaken(origin, false)
    end
end

local function parse3(s)
    local x, y, z = s:match("([^,]+),([^,]+),([^,]+)")
    return { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
end

local function clear(st)
    for _, c in ipairs(st.gearComps or {}) do
        pcall(function() if U.valid(c) then c:K2_DestroyComponent(c) end end)
    end
    st.gearComps = {}
end

-- Lab: where the copy's gear is and whether it shows.
function G.debug(st, actor)
    local out = {}
    for _, c in ipairs(st.gearComps or {}) do
        local ok, s = pcall(function()
            local l = c:K2_GetComponentLocation()
            local h = actor.Mesh:GetSocketLocation(FName("weapon_r"))
            local parent = c:GetAttachParent()
            return string.format("%s visible %s hiddenInGame %s at %.0f %.0f %.0f (weapon_r %.0f %.0f %.0f) parent %s socket %s scale %s",
                U.shortName(c), tostring(c:IsVisible()), tostring(c.bHiddenInGame), l.X, l.Y, l.Z, h.X, h.Y, h.Z,
                U.shortName(parent), c:GetAttachSocketName():ToString(), tostring(c:K2_GetComponentScale().X))
        end)
        out[#out + 1] = ok and s or ("error " .. tostring(s))
    end
    return #out > 0 and table.concat(out, " || ") or "no gear components"
end

-- Every frame on a copy: makes it hold what `id` holds.
function G.apply(actor, st, id)
    local desc = wanted[id]
    if desc == nil or (st.gearDesc ~= nil and sameGear(desc, st.gearDesc)) then return end
    st.gearDesc = desc
    clear(st)
    if desc == "" then
        U.log("gear: %s's copy holds nothing", id)
        return
    end
    local socket, partsText = desc:match("^([^|]*)|([^|]*)")
    for part in (partsText or ""):gmatch("[^~]+") do
        local ok, err = pcall(function()
            local kind, path, loc, rot, scale = part:match("^(%a);([^;]+);([^;]+);([^;]+);([^;]+)$")
            local asset = StaticFindObject(path)
            if not U.valid(asset) then asset = LoadAsset(path) end
            if not U.valid(asset) then error("mesh not found: " .. tostring(path)) end
            local cls = class(kind == "S" and "/Script/Engine.StaticMeshComponent" or "/Script/Engine.SkeletalMeshComponent")
            local ident = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 },
                            Scale3D = { X = 1, Y = 1, Z = 1 } }
            local c = actor:AddComponentByClass(cls, true, ident, false)
            if kind == "S" then c:SetStaticMesh(asset) else c:SetSkeletalMesh(asset, true) end
            c:SetCollisionEnabled(0)
            c:K2_AttachToComponent(actor.Mesh, FName(socket), 2, 2, 2, false)  -- SnapToTarget
            local qx, qy, qz, qw = rot:match("([^,]+),([^,]+),([^,]+),([^,]+)")
            c:K2_SetRelativeTransform({ Translation = parse3(loc), Scale3D = parse3(scale),
                Rotation = { X = tonumber(qx), Y = tonumber(qy), Z = tonumber(qz), W = tonumber(qw) } }, false, {}, false)
            st.gearComps[#st.gearComps + 1] = c
        end)
        if not ok then U.log("gear: giving %s's copy %s failed: %s", id, part:match("^%a;([^;]+)") or "?", tostring(err)) end
    end
    U.log("gear: %s's copy holds %d part(s) on %s", id, #st.gearComps, tostring(socket))
end

function G.remove(st)
    clear(st)
    st.gearDesc = nil
end

-- Hides the weapons a hidden character holds (the joiner's real enemies under the host's control).
function G.hideHeld(character)
    for _, w in ipairs(heldWeapons(character)) do
        pcall(function() if not w.bHidden then w:SetActorHiddenInGame(true) end end)
    end
end

-- THROWS ----------------------------------------------------------------------------------------------------------
-- Only the hand-held copy was mirrored: a weapon the partner threw left their copy's hand and showed up again ~2 s
-- later where it landed - its flight, its spin and its trail (FX_Throw) were never seen, and an object that broke
-- stayed whole here (user's two-PC session, 2026-10-10: "couldn't see weapons thrown by the host... the animation
-- and the weapon effect isn't visible on the join side at all").
-- Every game watches the throwables of its own world (AThrowableActor: weapons, bottles, kicked objects). One in the
-- air there (thrown, dropped, bouncing) is streamed: "wthrow" (identity, class, place) once, "wfly" 30 times a
-- second, "wrest" where it stops, or that it broke. The other game flies its own copy of that object along the stream
-- (collision off, its throw trail on), then leaves it at rest there; one that broke is hidden. An object only one game
-- has (an enemy's own weapon, runtime spawns) gets a visual stand-in of its class for the flight and where it lies.
local FLYING = { [5] = true, [6] = true, [7] = true, [8] = true, [9] = true, [10] = true, [13] = true, [14] = true }
local AT_REST = { [0] = true, [1] = true }
local PICKED, DESTROYED = 12, 15
local FLY_SEND_MS, SCAN_MS, LIST_MS, MAX_FLIGHT_MS = 33, 200, 2000, 8000
local RELEASE_MS, SETTLED_MS, FREE_MS = 1200, 3000, 4000

local throwList = { at = -1e9, list = {} }
local function throwables()
    local now = TailCoop_Clock()
    if now - throwList.at > LIST_MS then
        local ok, all = pcall(FindAllOf, "ThrowableActor")
        throwList.list, throwList.at = {}, now
        for _, a in ipairs(ok and all or {}) do
            local okN, n = pcall(function() return a:GetFullName() end)
            if okN and not n:find("Default__", 1, true) and n:find(":PersistentLevel.", 1, true) then
                throwList.list[#throwList.list + 1] = a
            end
        end
    end
    return throwList.list
end

local function throwState(a)
    local ok, s = pcall(function() return a:BPF_GetThrowableState() end)
    return ok and tonumber(s) or nil
end

-- Identity in both games: a level-placed name or a training rack (originOf); else this game's own name ("rt:"), which
-- the other game shows with a stand-in.
local function throwKey(a)
    return originOf(a) or ("rt:" .. a:GetFName():ToString())
end

local function localThrowable(key)
    local kind, name = key:match("^(%a+):(.+)$")
    if kind == "spawner" then return localWeapon(key) end
    if kind ~= "actor" then return nil end
    for _, a in ipairs(throwables()) do
        if U.valid(a) and a:GetFName():ToString() == name then return a end
    end
    return nil
end

local function fmtLoc(l) return string.format("%.1f,%.1f,%.1f", l.X, l.Y, l.Z) end
local function fmtRot(r) return string.format("%.1f,%.1f,%.1f", r.Pitch, r.Yaw, r.Roll) end
local function parseRot(s)
    local p, y, r = s:match("([^,]+),([^,]+),([^,]+)")
    return { Pitch = tonumber(p), Yaw = tonumber(y), Roll = tonumber(r) }
end

-- The throw trail (and any other particle effect the object has) on or off.
local particleClass
local function trail(a, on)
    particleClass = U.valid(particleClass) and particleClass or StaticFindObject("/Script/Engine.ParticleSystemComponent")
    if not particleClass then return end
    each(a:K2_GetComponentsByClass(particleClass), function(c)
        pcall(function()
            if c:GetFName():ToString():find("Throw", 1, true) then
                if on then c:Activate(true) else c:Deactivate() end
            end
        end)
    end)
end

-- Owner side.
local flights = {}       -- key -> { actor, lastSend, start }  (flying in this game, streamed)
local drivenUntil = {}   -- actor address -> clock until which we move it for the partner (never streamed back)
local rested = {}        -- key -> actor: runtime objects shown by the partner with a stand-in (gone/picked -> told)
local scanAt = -1e9
local shown = {}       -- receiver side (below): key -> { actor, stand, snaps = { {t, loc, rot} }, restAt }

local function sendRest(key, a, reason)
    local okL, l = pcall(function() return a:K2_GetActorLocation() end)
    local okR, r = pcall(function() return a:K2_GetActorRotation() end)
    N.send(true, "wrest", key, okL and fmtLoc(l) or "", okR and fmtRot(r) or "", reason)
    G.stats.rests = (G.stats.rests or 0) + 1
    if G.stats.rests <= 30 then U.log("gear: %s came to rest (%s)", key, reason) end
end

local function ownerTick(now)
    if now - scanAt >= SCAN_MS then
        scanAt = now
        local t = U.tick()
        for _, a in ipairs(throwables()) do
            if U.valid(a) then
                local addr = a:GetAddress()
                local st = (not drivenUntil[addr] or now > drivenUntil[addr]) and throwState(a) or nil
                -- (Not one still in a hand: a worn weapon reads "broken, one last throw allowed" while held - lab, an
                -- enemy's stick was streamed as a throw.)
                if st and FLYING[st] then
                    local okP, parent = pcall(function() return a:GetAttachParentActor() end)
                    if okP and parent ~= nil and U.valid(parent) then st = nil end
                end
                if st and FLYING[st] then
                    local okK, key = pcall(throwKey, a)
                    if okK and key and not flights[key] then
                        flights[key] = { actor = a, lastSend = 0, start = now }
                        local cls = a:GetClass():GetFullName():match("%s(.+)$")
                        N.send(true, "wthrow", key, cls or "", fmtLoc(a:K2_GetActorLocation()), fmtRot(a:K2_GetActorRotation()))
                        G.stats.throws = (G.stats.throws or 0) + 1
                        if G.stats.throws <= 30 then U.log("gear: %s is in the air (state %d): streamed to the partner", key, st) end
                    end
                end
            end
        end
        -- A weapon of ours hidden because the partner's character holds theirs, now in a hand here (our copy of that
        -- enemy took it up - it was lying loose when the partner's gear came): ours again, solid. (In a hidden copy's
        -- hand it's hidden again with it - hideHeld; its collision stays on, so it doesn't fall through the floor when
        -- dropped: the bat of an enemy we ran did, 4 km down, with nothing to pick up.)
        -- And one no character of the partner's holds any more (dropped, died with it, or the partner's game no longer
        -- runs that enemy - its last gear report is stale), with no word of where it came to rest, is ours again after
        -- FREE_MS where it lies: one stayed hidden for good otherwise.
        local E = require("tc_enemies")
        local S = require("tc_session")
        local heldThere = {}
        for id, desc in pairs(wanted) do
            local o = desc:match("^[^|]*|[^|]*|(.+)$")
            if o and (id == "p" or (E.ownerOf(id) ~= S.role and not E.isDead(id))) then heldThere[o] = true end
        end
        for origin, w in pairs(takenAway) do
            if heldThere[origin] or shown[origin] then
                freeSince[origin] = nil
            else
                freeSince[origin] = freeSince[origin] or now
                if now - freeSince[origin] > FREE_MS and now - (takenAt[origin] or 0) > FREE_MS then
                    freeSince[origin] = nil
                    U.log("gear: our %s isn't in the partner's hands any more: back where it lies", origin)
                    setTaken(origin, false)
                end
            end
        end
        for origin, w in pairs(takenAway) do
            if U.valid(w) then
                local okP, parent = pcall(function() return w:GetAttachParentActor() end)
                if okP and parent ~= nil and U.valid(parent) then
                    pcall(function() U.log("gear: our %s is in %s's hand here: ours again", origin, parent:GetFName():ToString()) end)
                    local okH, hidden = pcall(function() return parent.bHidden end)
                    if okH and hidden then
                        pcall(function() w:SetActorEnableCollision(true) end)
                        takenAway[origin] = nil
                    else
                        setTaken(origin, false)
                    end
                end
            end
        end
        -- Let go of without a throw we saw (G.publish): where it lies, 1.2 s after (fallen) and 3 s after (settled).
        for key, r in pairs(releases) do
            if flights[key] then
                releases[key] = nil
            elseif now - r.at >= (r.sends == 0 and RELEASE_MS or SETTLED_MS) then
                r.sends = r.sends + 1
                local a = r.actor
                if not U.valid(a) then
                    releases[key] = nil
                    N.send(true, "wrest", key, "", "", "broken")
                else
                    local okP, parent = pcall(function() return a:GetAttachParentActor() end)
                    if okP and parent ~= nil and U.valid(parent) then
                        releases[key] = nil  -- (in a hand again: that holder's gear says so)
                    else
                        G.rescue(a, r.from)
                        sendRest(key, a, "rest")
                        if r.sends >= 2 then releases[key] = nil end
                    end
                end
            end
        end
        -- Runtime objects the partner shows with a stand-in: gone or picked up here -> the stand-in goes.
        for key, a in pairs(rested) do
            local st = U.valid(a) and throwState(a) or nil
            if not st or st == PICKED or st == DESTROYED then
                rested[key] = nil
                N.send(true, "wrest", key, "", "", "gone")
            end
        end
        U.tock("throws scan", t)
    end
    for key, f in pairs(flights) do
        local a = f.actor
        local st = U.valid(a) and throwState(a) or nil
        if not st or st == DESTROYED then
            flights[key] = nil
            N.send(true, "wrest", key, "", "", "broken")
        elseif AT_REST[st] or st == PICKED or now - f.start > MAX_FLIGHT_MS then
            flights[key] = nil
            sendRest(key, a, st == PICKED and "picked" or "rest")
            if key:find("^rt:") and st ~= PICKED then rested[key] = a end
        elseif now - f.lastSend >= FLY_SEND_MS then
            f.lastSend = now
            pcall(function()
                N.send(false, "wfly", key, now, fmtLoc(a:K2_GetActorLocation()), fmtRot(a:K2_GetActorRotation()))
            end)
        end
    end
end

-- Receiver side.
-- (shown: declared above, with the owner side, which checks it too.)
local standIns = {}    -- key -> stand-in actor (runtime objects of the partner's)
local classCache = {}

local function standInFor(key, clsPath, loc, rot)
    local a = standIns[key]
    if a and U.valid(a) then return a end
    local cls = classCache[clsPath]
    if not U.valid(cls) then
        cls = StaticFindObject(clsPath)
        if not U.valid(cls) then pcall(LoadAsset, (clsPath:gsub("_C$", ""))); cls = StaticFindObject(clsPath) end
        classCache[clsPath] = cls
    end
    if not U.valid(cls) then return nil end
    local ok, spawned = pcall(function()
        local gs = require("UEHelpers").GetGameplayStatics()
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = loc, Scale3D = { X = 1, Y = 1, Z = 1 } }
        local s = gs:BeginDeferredActorSpawnFromClass(U.world(), cls, xf, 1, nil)
        gs:FinishSpawningActor(s, xf)
        return s
    end)
    if not (ok and U.valid(spawned)) then return nil end
    pcall(function() spawned:SetActorEnableCollision(false) end)
    setUsable(spawned, false)  -- (the real one is in the partner's game)
    drivenUntil[spawned:GetAddress()] = math.huge  -- ours to move, never streamed back as a throw of ours
    standIns[key] = spawned
    return spawned
end

local function onThrow(f)
    local key, clsPath = f[1], f[2]
    local loc, rot = parse3(f[3] or "0,0,0"), parseRot(f[4] or "0,0,0")
    local a = localThrowable(key)
    local stand = false
    if not a then
        a = standInFor(key, clsPath, loc, rot)
        stand = true
    end
    if not (a and U.valid(a)) then
        U.log("gear: the partner threw %s: nothing here to show it with (%s)", key, tostring(clsPath))
        return
    end
    -- (Ours in our player's hands, or flying from our own throw: theirs is a different event - not shown.)
    local st = throwState(a)
    if not stand and (st == PICKED or (FLYING[st] and not drivenUntil[a:GetAddress()])) then return end
    if not stand then drivenUntil[a:GetAddress()] = TailCoop_Clock() + MAX_FLIGHT_MS + 2000 end
    pcall(function()
        a:SetActorHiddenInGame(false)
        a:SetActorEnableCollision(false)
        a:K2_SetActorLocationAndRotation(loc, rot, false, {}, true)
    end)
    setUsable(a, false)  -- (in the air: back once it lands)
    trail(a, true)
    shown[key] = { actor = a, stand = stand, snaps = {} }
    G.stats.shown = (G.stats.shown or 0) + 1
    if G.stats.shown <= 30 then U.log("gear: the partner threw %s: shown here (%s)", key, stand and "stand-in" or "our copy") end
end

local function onFly(f)
    local s = shown[f[1]]
    if not s then return end
    local t = tonumber(f[2])
    if not t or (#s.snaps > 0 and t <= s.snaps[#s.snaps].t) then return end
    s.snaps[#s.snaps + 1] = { t = t, at = TailCoop_Clock(), loc = parse3(f[3]), rot = parseRot(f[4]) }
    if #s.snaps > 8 then table.remove(s.snaps, 1) end
end

local function onRest(f)
    local key, reason = f[1], f[4]
    local s = shown[key]
    shown[key] = nil
    local a = (s and s.actor) or standIns[key] or localThrowable(key)
    if not (a and U.valid(a)) then return end
    -- Ours is still in a hand: our copy of the enemy that let go of it. A dead one lets go here too; a live one keeps it
    -- (its own weapon in Sifu's eyes - taken from it outside Sifu's logic, it could break the enemy).
    local okP, holder = pcall(function() return a:GetAttachParentActor() end)
    if okP and holder ~= nil and U.valid(holder) then
        local okH, h = pcall(function() return holder.m_HealthComponent.m_fHealth end)
        if not (okH and h and h <= 0) then return end
        pcall(function() a:K2_DetachFromActor(1, 1, 1) end)  -- EDetachmentRule::KeepWorld
    end
    trail(a, false)
    if reason == "broken" or reason == "gone" or reason == "picked" then
        -- Broke there / picked up again (a held one shows in the holder's hand): out of sight here.
        if reason ~= "picked" or key:find("^rt:") then
            pcall(function()
                a:SetActorHiddenInGame(true)
                a:SetActorEnableCollision(false)
            end)
            setUsable(a, false)
        end
        if reason ~= "picked" and not key:find("^rt:") then takenAway[key] = nil end
        return
    end
    pcall(function()
        if f[2] ~= "" then
            a:K2_SetActorLocationAndRotation(parse3(f[2]), parseRot(f[3]), false, {}, true)
            -- (Ours may have been falling - dropped with its collision off: it stops where theirs lies.)
            pcall(function() a.RootComponent:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None")) end)
        end
        a:SetActorHiddenInGame(false)
        -- (A stand-in stays untouchable: the real one is in the partner's game.)
        if not key:find("^rt:") then a:SetActorEnableCollision(true) end
    end)
    if not key:find("^rt:") then setUsable(a, true) end
    if takenAway[key] then takenAway[key] = nil end
    if not key:find("^rt:") then drivenUntil[a:GetAddress()] = TailCoop_Clock() + 1500 end
end

-- Every frame: each object the partner has in the air, 66 ms behind their stream (two updates to blend between).
local FLY_DELAY_MS = 66
local function lerp(a, b, k) return a + (b - a) * k end
local function lerpAngle(a, b, k) return a + ((b - a + 540) % 360 - 180) * k end
local function receiverTick(now)
    for key, s in pairs(shown) do
        local a = s.actor
        if not U.valid(a) then
            shown[key] = nil
        elseif #s.snaps > 0 then
            local renderAt = now - FLY_DELAY_MS
            local p, q = s.snaps[1], nil
            for i = 1, #s.snaps do
                if s.snaps[i].at <= renderAt then p, q = s.snaps[i], s.snaps[i + 1] end
            end
            local loc, rot = p.loc, p.rot
            if q then
                local k = math.min(1, math.max(0, (renderAt - p.at) / math.max(1, q.at - p.at)))
                loc = { X = lerp(p.loc.X, q.loc.X, k), Y = lerp(p.loc.Y, q.loc.Y, k), Z = lerp(p.loc.Z, q.loc.Z, k) }
                rot = { Pitch = lerpAngle(p.rot.Pitch, q.rot.Pitch, k), Yaw = lerpAngle(p.rot.Yaw, q.rot.Yaw, k),
                        Roll = lerpAngle(p.rot.Roll, q.rot.Roll, k) }
            end
            pcall(function() a:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end)
        end
    end
end

G.stats = {}
function G.throwStats()
    local n = 0
    for _ in pairs(shown) do n = n + 1 end
    return string.format("throws streamed %d, rests sent %d, partner's throws shown %d (in the air now %d)",
        G.stats.throws or 0, G.stats.rests or 0, G.stats.shown or 0, n)
end

local function resetThrows()
    for _, a in pairs(standIns) do
        pcall(function() if U.valid(a) then a:SetActorHiddenInGame(true); a:SetActorEnableCollision(false) end end)
    end
    flights, drivenUntil, rested, shown, standIns = {}, {}, {}, {}, {}
    throwList.at = -1e9
end

-- Session over: every weapon we hid is ours again.
function G.reset()
    for origin in pairs(takenAway) do setTaken(origin, false) end
    wanted, freeSince, releases = {}, {}, {}
    resetThrows()
end

function G.start()
    N.on("gear", onGear)
    N.on("wdrop", onDrop)
    N.on("wthrow", function(f) U.onGameThread("partner throw", function() onThrow(f) end) end)
    N.on("wfly", onFly)
    N.on("wrest", function(f) U.onGameThread("partner throw rest", function() onRest(f) end) end)
    require("tc_flow").onMapChange(resetThrows)
    U.poll("throws", 10, function()
        local S, F = require("tc_session"), require("tc_flow")
        if not (S.connected() and F.activity) then return false end
        local now = TailCoop_Clock()
        ownerTick(now)
        receiverTick(now)
        return false
    end)
    U.poll("throws stats", 20000, function()
        if require("tc_session").connected() and require("tc_flow").activity then U.log("gear: %s", G.throwStats()) end
        return false
    end)
    require("tc_session").onChange(function()
        if not require("tc_session").connected() then G.reset() end
    end)
end

return G
