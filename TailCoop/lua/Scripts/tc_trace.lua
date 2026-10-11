-- tc_trace: G1 instrumentation. Logs which gameplay functions fire, on WHOSE character (ME = our player,
-- PUPPET = the partner's character, otherwise the actor's class), with decoded arguments. Order calls
-- (attacks, dodges, parries, hits...) are logged with their FBuffer payload, which is what co-op has to mirror.
local U = require("tc_util")

local Tr = {}

local ORDER_TYPES = { "Attack", "Dodge", "ParryVictim", "Hitted", "Guard", "Avoided", "FreezeFrame", "WeaponAction",
    "TakedownInstigator", "TakedownVictim", "KnockedDown", "Dizzy", "Pushed", "PlayAnim", "Parry", "GrabInstigator",
    "GrabVictim", "FightingStateRecovery", "DownBeforeStandup", "Standup", "UseMovable", "ThrowObject", "PushObject",
    "PickUpObject", "DropObject", "PushInstigator", "PushVictim", "FallFromPushed", "FallReception", "FallGetUp",
    "Reaction", "IdleExit", "Traversal", "StructureBroken", "AttackEnvInstigator", "AttackEnvVictim", "SwapWeaponHand",
    "Fidget", "FallOnSlope", "PrepFocus", "SynchronizedAttackInstigator", "SynchronizedAttackVictim", "WallJumpEntry",
    "WallJumpAttack", "ParryInstigator", "TraversalClimb", "ParryFromDown", "DeflectSBInstigator", "AnimSync",
    "TraversalCinematic", "RagingBull", "Avoid", "FallOnSlopeRecovery", "Dash", "FallOnSlopeEntry",
    "AttackActionGeneric", "ChargeBuildUp", "OpeningDoor", "HittedGeneric", "TraversalPush", "TraversalPushInstigator",
    "TraversalDropDown", "RainDash", "Incapacipated", "Jiggle", "Deflected", "Taunt", "PlayBlendSpace",
    "TargetReactionBlendSpace", "MoveToWithPhysWalking" }
Tr.ORDER_TYPES = ORDER_TYPES

-- Native (/Script) functions exist at startup, so they can be hooked immediately.
-- kind: "order" = (EOrderType, forcedID, FBuffer, int64 time, ...), "plain" = generic argument dump.
local HOOKS = {
    { "/Script/Sifu.OrderComponent:ServerPlayOrder", "order" },
    { "/Script/Sifu.OrderComponent:MultiCastPlayOrder", "order" },
    { "/Script/Sifu.OrderComponent:ServerUpdateOrder", "update" },
    { "/Script/Sifu.OrderComponent:MultiCastUpdateOrder", "update" },
    { "/Script/Sifu.OrderComponent:ServerCancelOrderByID" },
    { "/Script/Sifu.OrderComponent:MultiCastCancelOrderByID" },
    { "/Script/Sifu.OrderComponent:ServerCancelOrderByType" },
    { "/Script/Sifu.OrderComponent:MultiCastCancelOrderByType" },
    { "/Script/Sifu.OrderComponent:ServerCancelOrderByIDList" },
    { "/Script/Sifu.OrderComponent:MultiCastCancelOrderByIDList" },
    { "/Script/Sifu.OrderComponent:MultiCastFirstOrderTransformData" },
    { "/Script/Sifu.OrderComponent:ClientPlayOrderRejected" },
    { "/Script/Sifu.AttackComponent:ServerSetTarget" },
    { "/Script/Sifu.AttackComponent:MulticastOrderAttackTrackingOver" },
    { "/Script/Sifu.DefenseComponent:ServerSetGuardValue" },
    { "/Script/Sifu.DefenseComponent:ClientNotifyIsTargettedByAttack" },
    { "/Script/Sifu.HealthComponent:BPF_ServerSetHealth" },
    { "/Script/Sifu.HealthComponent:BPF_ServerAddHealth" },
    { "/Script/Sifu.FightingCharacter:MulticastAddEffect" },
    { "/Script/Sifu.FightingCharacter:MulticastRemoveEffect" },
    { "/Script/Sifu.FightingCharacter:ServerPullOutWeapon" },
    { "/Script/Sifu.FightingCharacter:ServerSuicide" },
    { "/Script/Sifu.FightingCharacter:BPE_OnDeath" },
    { "/Script/Sifu.FightingCharacter:BPE_Hit" },
    { "/Script/Sifu.FightingCharacter:BPE_JustBeenHitted" },
    { "/Script/Sifu.FightingCharacter:BPE_DoParry" },
    { "/Script/Sifu.FightingCharacter:BPE_AttackStarted" },
    { "/Script/Sifu.FightingCharacter:BPE_AttackEnded" },
    { "/Script/Sifu.FightingMovementComponent:ServerPopDesyncFromServer" },
    { "/Script/Sifu.ThePlainesGameInstance:TravelToNextMap" },
    { "/Script/Sifu.ThePlainesGameInstance:TravelToLoadedMap" },
    { "/Script/Sifu.ThePlainesGameInstance:LoadMapAsync" },
    { "/Script/Sifu.ThePlainesGameInstance:GoToMapInGameFlow" },
}

local counts = {}

-- "ME", "PUPPET" or a short class name for the actor that owns ctx (ctx can be an actor or a component).
local function who(obj)
    if not U.valid(obj) then return "?" end
    local actor = obj
    local okOwner, owner = pcall(function() return obj:GetOwner() end)
    if okOwner and U.valid(owner) and not obj:IsA(StaticFindObject("/Script/Engine.Actor")) then actor = owner end
    local addr = actor:GetAddress()
    local pc = U.playerController()
    if pc and U.valid(pc.Pawn) and pc.Pawn:GetAddress() == addr then return "ME" end
    local okP, puppet = pcall(function() return require("tc_presence").puppetActor() end)
    if okP and U.valid(puppet) and puppet:GetAddress() == addr then return "PUPPET" end
    local cls = actor:GetClass():GetFName():ToString()
    return cls:gsub("^BP_", ""):gsub("_C$", "")
end
Tr.who = who

local function arrayItems(arr, max, fmt)
    local out = {}
    local ok, n = pcall(function() return arr:GetArrayNum() end)
    if not ok then return "?", 0 end
    for i = 1, math.min(n, max) do
        local okI, v = pcall(function() return arr[i] end)
        out[#out + 1] = okI and fmt(v) or "?"
    end
    return table.concat(out, fmt == nil and "" or " "), n
end

-- FBuffer { TArray<uint8> m_BufferArray; TArray<FName> m_BufferFnames; TArray<AActor*> m_BufferActors;
--           TArray<UObject*> m_BufferUObjects }
local function describeBuffer(buf)
    local bytes, nb = arrayItems(buf.m_BufferArray, 64, function(v) return string.format("%02x", v) end)
    local names, nn = arrayItems(buf.m_BufferFnames, 8, function(v) return v:ToString() end)
    local actors, na = arrayItems(buf.m_BufferActors, 8, function(v) return who(v) end)
    local objs, no = arrayItems(buf.m_BufferUObjects, 8, function(v) return U.shortName(v) end)
    return string.format("bytes[%d]=%s names[%d]=%s actors[%d]=%s objects[%d]=%s", nb, bytes, nn, names, na, actors,
        no, objs)
end
Tr.describeBuffer = describeBuffer

local function orderName(v)
    return ORDER_TYPES[(tonumber(v) or -1) + 1] or tostring(v)
end

local function hook(path, kind)
    local short = path:match("%.([%w_]+:[%w_]+)$") or path
    local ok, err = pcall(function()
        RegisterHook(path, function(ctx, ...)
            counts[short] = (counts[short] or 0) + 1
            local params = { ... }
            local subject = who(ctx:get())
            local detail
            if kind == "order" then
                local okO, d = pcall(function()
                    return string.format("type=%s forcedID=%s time=%s after=%s | %s", orderName(params[1]:get()),
                        tostring(params[2]:get()), tostring(params[4]:get()), tostring(params[5]:get()),
                        describeBuffer(params[3]:get()))
                end)
                detail = okO and d or ("decode error: " .. tostring(d))
            elseif kind == "update" then
                local okO, d = pcall(function()
                    return string.format("id=%s type=%s | %s", tostring(params[1]:get()), orderName(params[2]:get()),
                        describeBuffer(params[3]:get()))
                end)
                detail = okO and d or ("decode error: " .. tostring(d))
            else
                local args = {}
                for i, p in ipairs(params) do
                    if i > 6 then break end
                    args[#args + 1] = U.paramString(p)
                end
                detail = table.concat(args, ", ")
            end
            U.log("TRACE %-6s %s (%s)", subject, short, detail)
        end)
    end)
    if not ok then U.log("trace: could not hook %s: %s", short, tostring(err)) end
    return ok
end

function Tr.start()
    local hooked = 0
    for _, h in ipairs(HOOKS) do
        if hook(h[1], h[2]) then hooked = hooked + 1 end
    end
    U.log("trace: %d/%d hooks active", hooked, #HOOKS)

    U.poll("trace summary", 30000, function()
        local parts = {}
        for k, v in pairs(counts) do parts[#parts + 1] = k .. "=" .. v end
        table.sort(parts)
        U.log("trace summary: %s", #parts > 0 and table.concat(parts, " ") or "(nothing yet)")
        return false
    end)
end

return Tr
