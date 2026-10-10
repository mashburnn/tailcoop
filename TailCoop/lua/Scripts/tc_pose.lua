-- tc_pose: bone-exact copies (TailCoopNative pose sync, see cpp/src/pose.h).
-- The owner of a character sends its whole pose each tick; the copy in the other game gets a PoseableMeshComponent
-- that shows that pose, and its own mesh follows it (master pose), so materials and everything else stay Sifu's.
-- When no pose arrives (old partner build, skeleton mismatch...) the copy falls back to tc_anim's animation copy.
local U = require("tc_util")

local Pose = {}

local ready = nil

function Pose.init()
    if ready ~= nil then return ready end
    ready = false
    if not TailCoop_PoseInit then
        U.log("pose: native module without pose sync")
        return false
    end
    local snap = StaticFindObject("/Script/Engine.SkeletalMeshComponent:SnapshotPose")
    local apply = StaticFindObject("/Script/Engine.PoseableMeshComponent:ApplyPoseFromSnapshot")
    local ref = StaticFindObject("/Script/Engine.SkinnedMeshComponent:GetRefPosePosition")
    if not (U.valid(snap) and U.valid(apply) and U.valid(ref)) then
        U.log("pose: engine functions missing")
        return false
    end
    local ok, err = TailCoop_PoseInit(tostring(snap:GetAddress()), tostring(apply:GetAddress()),
        tostring(ref:GetAddress()))
    ready = ok and true or false
    U.log("pose: %s", ready and "ready" or ("init failed: " .. tostring(err)))
    return ready
end

local function addr(obj) return tostring(obj:GetAddress()) end

-- A character whose pose we send must keep animating when it's off our screen: Sifu (like UE) stops the pose of
-- unseen characters (VisibilityBasedAnimTickOption), and the partner then saw an enemy frozen mid-move while its hits
-- kept landing. (Turning the animation budget allocator off globally - tried first - made characters play too fast:
-- budgeted meshes then got ticked twice.)
local keptAnimating = {}
local function keepAnimating(mesh)
    local key = mesh:GetAddress()
    if keptAnimating[key] then return end
    keptAnimating[key] = true
    pcall(function() mesh.VisibilityBasedAnimTickOption = 0 end)  -- AlwaysTickPoseAndRefreshBones
end

-- Sends `character`'s pose under `id` (owner side). Returns bytes sent or nil, error.
-- st (optional, the caller's state for this character): keeps the mesh's address between calls - looked up again
-- every second, and checked live (TailCoop_Live) each time - instead of three engine calls per pose.
function Pose.send(character, id, clock, st)
    if not Pose.init() then return nil, "unavailable" end
    local now = TailCoop_Clock()
    local meshStr = st and st.poseMeshStr
    if not (meshStr and now - st.poseMeshAt < 1000 and (not TailCoop_Live or TailCoop_Live(meshStr))) then
        local ok, mesh = pcall(function() return character.Mesh end)
        if not (ok and U.valid(mesh)) then return nil, "no mesh" end
        keepAnimating(mesh)
        meshStr = addr(mesh)
        if st then st.poseMeshStr, st.poseMeshAt = meshStr, now end
    end
    return TailCoop_PoseSend(meshStr, id, tostring(clock))
end

-- Loopback for solo tests: as if `character`'s pose had arrived under `id`.
function Pose.store(character, id, clock)
    if not Pose.init() then return nil, "unavailable" end
    return TailCoop_PoseSend(addr(character.Mesh), id, tostring(clock), "store")
end

-- Gives a copy its poseable mesh (st: the copy's state table). mode "master": the copy's own mesh follows the
-- (hidden) poseable; mode "direct": the poseable is shown and the copy's mesh hidden.
function Pose.attach(actor, st, mode)
    if st.poseable and U.valid(st.poseable) then return st.poseable end
    if not Pose.init() then return nil end
    local ok, err = pcall(function()
        local mesh = actor.Mesh
        local cls = StaticFindObject("/Script/Engine.PoseableMeshComponent")
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 },
                     Scale3D = { X = 1, Y = 1, Z = 1 } }
        local p = actor:AddComponentByClass(cls, false, xf, false)
        p:K2_SetRelativeLocationAndRotation(mesh.RelativeLocation, mesh.RelativeRotation, false, {}, false)
        p:SetSkeletalMesh(mesh.SkeletalMesh, true)
        for i = 0, mesh:GetNumMaterials() - 1 do p:SetMaterial(i, mesh:GetMaterial(i)) end
        -- Hidden (master mode), it must still refresh its bones every frame for the mesh following it.
        p.VisibilityBasedAnimTickOption = 0  -- AlwaysTickPoseAndRefreshBones
        st.poseable, st.poseMode = p, mode or "master"
    end)
    if not ok then
        U.log("pose: attaching a poseable mesh to %s failed: %s", U.shortName(actor), tostring(err))
        return nil
    end
    U.log("pose: %s gets a poseable mesh (%s)", U.shortName(actor), st.poseMode)
    return st.poseable
end

-- Switches what the copy shows: the received pose (on = true) or its own animation (tc_anim fallback).
local function setPoseDriven(actor, st, on)
    if st.poseDriven == on then return end
    st.poseDriven = on
    pcall(function()
        local mesh, p = actor.Mesh, st.poseable
        if st.poseMode == "direct" then
            p:SetVisibility(on, false)
            mesh:SetVisibility(not on, false)
        else
            p:SetVisibility(false, false)
            mesh:SetMasterPoseComponent(on and p or nil, true)
        end
        -- A mirrored mesh (tc_anim's flip for mirrored moves) would mirror the received pose: off while driven.
        if on then require("tc_anim").setMirror(actor, false) end
    end)
    U.log("pose: %s %s", U.shortName(actor), on and "shows the owner's exact pose" or "back to animation copy")
end

-- Every frame on the copy: shows `id`'s pose at sender time renderClock. Returns true while pose-driven
-- (the caller then skips its animation copy), false to fall back.
-- (The caller has checked the copy is alive this frame; its poseable and mesh live and die with it, so their addresses
-- are kept, looked up again twice a second.)
function Pose.apply(actor, st, id, renderClock)
    local now = TailCoop_Clock()
    if not (st.poseAddr and now - st.poseAddrAt < 500) then
        local p = Pose.attach(actor, st)
        if not p then
            st.poseAddr = nil
            return false
        end
        local ok, meshStr = pcall(function() return addr(actor.Mesh) end)
        if not ok then return false end
        st.poseAddr, st.poseMeshAddr, st.poseAddrAt = addr(p), meshStr, now
    end
    local status, age = TailCoop_PoseApply(st.poseAddr, st.poseMeshAddr, id, tostring(math.floor(renderClock)))
    st.poseAge = age  -- > 0: past the newest pose received (held)
    -- Fresh enough: within half a second of the timeline (packet loss / a hitch hold the last pose that long).
    local good = status == "ok" and age < 500
    if status ~= st.poseStatus then
        st.poseStatus = status
        U.log("pose: %s <- %s: %s", U.shortName(actor), id, status)
    end
    setPoseDriven(actor, st, good)
    return good
end

-- Hands the copy back to its animation copy for now (e.g. a locally predicted hit reaction).
function Pose.release(actor, st)
    if st.poseable then setPoseDriven(actor, st, false) end
end

-- The copy is put aside (kept for reuse): back to its own animation, and the received-pose timeline it followed is
-- dropped, so it starts clean on whatever stream it follows next. The poseable mesh stays.
function Pose.park(actor, st)
    if st.poseable then
        setPoseDriven(actor, st, false)
        pcall(TailCoop_PoseForget, addr(st.poseable))
        pcall(function() st.poseable.VisibilityBasedAnimTickOption = 3 end)  -- OnlyTickPoseWhenRendered: idle
    end
end

function Pose.unpark(st)
    if st.poseable and U.valid(st.poseable) then
        pcall(function() st.poseable.VisibilityBasedAnimTickOption = 0 end)
    end
end

function Pose.detach(actor, st)
    if st.poseable then
        pcall(TailCoop_PoseForget, addr(st.poseable))
        if U.valid(actor) then
            pcall(function() actor.Mesh:SetMasterPoseComponent(nil, true) end)
            pcall(function() actor.Mesh:SetVisibility(true, false) end)
        end
    end
    st.poseable, st.poseDriven, st.poseAddr = nil, nil, nil
end

function Pose.stats() return TailCoop_PoseStats and TailCoop_PoseStats() or "unavailable" end

return Pose
