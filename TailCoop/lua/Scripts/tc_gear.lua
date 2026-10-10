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
    -- A world weapon let go of (dropped, thrown, disarmed): once it has come to rest, tell the partner where.
    if state.origin and state.origin ~= origin then
        state.released = { origin = state.origin, actor = state.heldActor, at = now + 1500 }
    end
    state.origin, state.heldActor = origin, heldActor
    local rel = state.released
    if rel and now >= rel.at then
        state.released = nil
        pcall(function()
            if not U.valid(rel.actor) then return end
            local l, r = rel.actor:K2_GetActorLocation(), rel.actor:K2_GetActorRotation()
            N.send(true, "wdrop", rel.origin, string.format("%.1f,%.1f,%.1f", l.X, l.Y, l.Z),
                string.format("%.1f,%.1f,%.1f", r.Pitch, r.Yaw, r.Roll))
            U.log("gear: %s let go of %s at %.0f %.0f %.0f", id, rel.origin, l.X, l.Y, l.Z)
        end)
    end
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

local function setTaken(origin, on)
    local w = (not on and takenWeapon(origin)) or localWeapon(origin)
    if not w then
        takenAway[origin] = nil
        return
    end
    pcall(function()
        w:SetActorHiddenInGame(on)
        w:SetActorEnableCollision(not on)
    end)
    takenAway[origin] = on and w or nil
    U.log("gear: our %s %s", origin, on and "is in the partner's hands: hidden" or "is back")
end

local function onGear(f)
    local desc = f[2] == "-" and "" or ((f[2] or ""):gsub("%^", "|"))
    local before = wanted[f[1]]
    wanted[f[1]] = desc
    -- The partner took a world weapon both games have: ours goes out of sight (and reach) meanwhile.
    local newOrigin = desc:match("^[^|]*|[^|]*|(.+)$")
    local oldOrigin = before and before:match("^[^|]*|[^|]*|(.+)$")
    if newOrigin and newOrigin ~= oldOrigin and not takenWeapon(newOrigin) then setTaken(newOrigin, true) end
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

-- Session over: every weapon we hid is ours again.
function G.reset()
    for origin in pairs(takenAway) do setTaken(origin, false) end
    wanted = {}
end

function G.start()
    N.on("gear", onGear)
    N.on("wdrop", onDrop)
    require("tc_session").onChange(function()
        if not require("tc_session").connected() then G.reset() end
    end)
end

return G
