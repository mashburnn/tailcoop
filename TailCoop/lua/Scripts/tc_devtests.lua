-- tc_devtests: one-shot lab experiments, selected with -TailCoopTest=<name>.
--   g0: can this build host a UE listen server? (expected: no, client-only build)
local U = require("tc_util")

local T = {}

local TRAINING_MAP = "/Game/Maps/TrainingRoom/TrainingRoom_Main"

local function netReport(label)
    local world = U.world()
    local ksl = require("UEHelpers").GetKismetSystemLibrary()
    local driver = world.NetDriver
    U.log("G0 %s: map=%s standalone=%s server=%s netdriver=%s", label,
        U.shortName(world), tostring(ksl:IsStandalone(world)), tostring(ksl:IsServer(world)),
        U.valid(driver) and U.shortName(driver) or "none")
    return U.valid(driver) and not ksl:IsStandalone(world)
end

-- UE4SS's InitGameState hook doesn't fire in Sifu, so this keys off the world changing instead.
-- options = "listen" for the real test, "" for the control run (proves OpenLevel itself works).
local function g0(options)
    local phase = "wait_title"
    local waited = 0
    local function worldName(world) return world:GetFullName() end
    U.poll("g0", 1000, function()
        local world = U.world()
        if not U.valid(world) then return false end
        local name = worldName(world)
        if phase == "wait_title" then
            -- Wait until the title scene (Hideout_0_Main) has been up for a while.
            if name:find("Hideout_0_Main", 1, true) then
                waited = waited + 1
                if waited >= 15 then
                    netReport("before")
                    U.log("G0 OpenLevel(%s, options='%s')", TRAINING_MAP, options)
                    require("UEHelpers").GetGameplayStatics():OpenLevel(world, FName(TRAINING_MAP), true, options)
                    phase = "wait_load"
                    waited = 0
                end
            end
        elseif phase == "wait_load" then
            waited = waited + 1
            if waited % 5 == 0 then U.log("G0 waiting: world is %s", name) end
            if name:find("TrainingRoom", 1, true) then
                local listening = netReport("after load")
                U.log("G0 RESULT (%s): map loaded; listen server %s", options == "" and "control" or "listen",
                    listening and "ACTIVE" or "not active")
                return true
            end
            if waited >= 60 then
                U.log("G0 RESULT (%s): TrainingRoom never loaded; world is %s",
                    options == "" and "control" or "listen", name)
                return true
            end
        end
        return false
    end)
end

-- menudiag: where do the live title buttons actually live?
local function menudiag()
    local n = 0
    U.poll("menudiag", 5000, function()
        n = n + 1
        for _, box in ipairs(FindAllOf("VerticalBox") or {}) do
            local name = box:GetFName():ToString()
            if name == "MenuBox" or name == "StoryBox" then
                local slots = box.Slots
                U.log("DIAG %s owner=%s slots=%d count=%d", name, box:GetFullName(), #slots, box:GetChildrenCount())
            end
        end
        for _, b in ipairs(FindAllOf("BP_Btn_TitleBtn_C") or {}) do
            local parent = b:GetParent()
            U.log("DIAG button %s vis=%s parent=%s", b:GetFullName(), tostring(b:GetVisibility()),
                U.valid(parent) and parent:GetFullName() or "none")
        end
        return n >= 6
    end)
end

-- retdiag: do UFunction return values come back correctly from Lua?
local function retdiag()
    -- Does a Lua call reach the function at all? The hook sees the arguments if it does.
    U.try("retdiag hook", function()
        RegisterHook("/Script/Engine.KismetMathLibrary:Add_IntInt", function(ctx, a, b)
            U.log("RETDIAG hook: Add_IntInt reached with A=%s B=%s", U.paramString(a), U.paramString(b))
        end)
    end)
    U.poll("retdiag", 3000, function()
        local UEH = require("UEHelpers")
        local math = UEH.GetKismetMathLibrary()
        local str = UEH.GetKismetStringLibrary()
        local function show(label, fn)
            local ok, v = pcall(fn)
            U.log("RETDIAG %-28s ok=%s value=%s type=%s", label, tostring(ok), tostring(v), type(v))
        end
        show("Add_IntInt(2,3) [5]", function() return math:Add_IntInt(2, 3) end)
        show("Multiply_FloatFloat(1.5,4) [6]", function() return math:Multiply_FloatFloat(1.5, 4.0) end)
        show("Not_PreBool(false) [true]", function() return math:Not_PreBool(false) end)
        show("Concat_StrStr [ab]", function() return str:Concat_StrStr("a", "b"):ToString() end)
        show("Len('hello') [5]", function() return str:Len("hello") end)
        -- Side effect check: does the call run at all? (property reads are known to work)
        local ws = UEH.GetWorldSettings()
        if U.valid(ws) then
            local before = ws.TimeDilation
            UEH.GetGameplayStatics():SetGlobalTimeDilation(U.world(), 0.5)
            local after = ws.TimeDilation
            UEH.GetGameplayStatics():SetGlobalTimeDilation(U.world(), 1.0)
            U.log("RETDIAG SetGlobalTimeDilation(0.5): TimeDilation before=%s after=%s restored=%s",
                tostring(before), tostring(after), tostring(ws.TimeDilation))
            ws.TimeDilation = 0.75
            U.log("RETDIAG direct property write TimeDilation=0.75 -> %s", tostring(ws.TimeDilation))
            ws.TimeDilation = 1.0
        else
            U.log("RETDIAG no WorldSettings")
        end
        return true
    end)
end

-- clickdiag: which events fire when a title button is focused / activated?
local function clickdiag()
    local function logHook(path)
        U.try("clickdiag " .. path, function()
            RegisterHook(path, function(ctx, ...)
                local args = {}
                for _, p in ipairs({ ... }) do args[#args + 1] = U.paramString(p) end
                U.log("CLICKDIAG %s on %s (%s)", path:match("[^:]+$"), U.shortName(ctx:get()), table.concat(args, ", "))
            end)
            U.log("CLICKDIAG hooked %s", path)
        end)
    end
    for _, fn in ipairs({ "BPE_OnClicked", "BPE_OnSelected", "BPE_OnDeselected", "BPE_OnInputActionPressed" }) do
        logHook("/Script/Sifu.ButtonUserWidget:" .. fn)
    end
    logHook("/Script/Sifu.MenuWidget:BPE_OnActionButtonPressed")
    -- Blueprint overrides and bound click events on the title menu, once its class is loaded.
    U.poll("clickdiag bp", 2000, function()
        local cls = StaticFindObject("/Game/UI/Blueprints/Menus/Gameflow/BP_Menu_Startup.BP_Menu_Startup_C")
        if not U.valid(cls) then return false end
        for _, fn in ipairs({ "BPE_OnActionButtonPressed", "BPE_GiveFocus",
            "BndEvt__BP_Menu_Startup_BtnStory_K2Node_ComponentBoundEvent_7_ButtonUserWidgetClickDelegate__DelegateSignature" }) do
            logHook("/Game/UI/Blueprints/Menus/Gameflow/BP_Menu_Startup.BP_Menu_Startup_C:" .. fn)
        end
        return true
    end)
end

-- g2: transport test between the two lab systems (System 1: -Role host, System 2: -Role join).
-- Each side sends COUNT numbered reliable messages plus an unreliable stream; both check that every reliable
-- message arrived exactly once and in order. Then the joiner leaves and rejoins (disconnect/reconnect).
local function g2()
    local S = require("tc_session")
    local N = require("tc_net")
    local COUNT = 2000
    local rel, orderErrors, lastSeq, unrel, peerDone = 0, 0, 0, 0, nil
    N.on("seq", function(f)
        local i = tonumber(f[1])
        rel = rel + 1
        if i ~= lastSeq + 1 then orderErrors = orderErrors + 1 end
        lastSeq = i
    end)
    N.on("u", function() unrel = unrel + 1 end)
    N.on("done", function(f) peerDone = tonumber(f[1]) end)

    local function begin()
        rel, orderErrors, lastSeq, unrel, peerDone = 0, 0, 0, 0, nil
        if U.config.role == "host" then return S.host("training") end
        return S.join(U.config.peer)
    end

    local phase, sent, uSent, round, waitUntil = "start", 0, 0, 1, 0
    U.poll("g2", 33, function()
        local st = N.status()
        if phase == "start" then
            local ok, err = begin()
            U.log("G2 round %d: %s %s", round, U.config.role, ok and "started" or ("FAILED: " .. tostring(err)))
            phase = ok and "wait" or "end"
        elseif phase == "wait" then
            if st.state == "connected" then
                U.log("G2 round %d: connected to %s (local %s)", round, st.peer, st.localAddress)
                phase, sent, uSent = "send", 0, 0
            elseif st.state == "failed" then
                U.log("G2 round %d: FAILED %s", round, st.detail)
                phase = "end"
            end
        elseif phase == "send" then
            for _ = 1, 100 do
                if sent >= COUNT then break end
                local ok, err = N.send(true, "seq", sent + 1)
                if not ok then U.log("G2 send error: %s", err) break end
                sent = sent + 1
            end
            N.send(false, "u", uSent)
            uSent = uSent + 1
            if sent >= COUNT then
                N.send(true, "done", COUNT)
                phase = "wait_peer"
            end
        elseif phase == "wait_peer" then
            N.send(false, "u", uSent)
            uSent = uSent + 1
            if peerDone and rel >= peerDone and st.pending == 0 then
                local pass = rel == COUNT and orderErrors == 0
                U.log("G2 RESULT round %d %s: reliable %d/%d (order errors %d), unreliable received %d of ~%d sent by us, rtt %d ms, resent %d, packets sent %d recv %d, simulated drops %d",
                    round, pass and "PASS" or "FAIL", rel, COUNT, orderErrors, unrel, uSent, st.rtt, st.resent, st.sent, st.recv,
                    TailCoop_Simulate and TailCoop_Simulate(U.config.sim:match("^([%d%.]+)") or "0",
                        U.config.sim:match("^[%d%.]+,(%d+)") or "0", U.config.sim:match("(%d+)$") or "0") or 0)
                phase, waitUntil = "linger", os.time() + 3
            end
        elseif phase == "linger" then
            if os.time() >= waitUntil then
                if round == 1 and U.config.role == "join" then
                    U.log("G2: joiner leaving to test disconnect + rejoin")
                    S.leave()
                    phase, waitUntil = "rejoin", os.time() + 3
                elseif round == 1 then
                    phase = "host_wait_rejoin"
                else
                    U.log("G2 complete")
                    phase = "end"
                end
            end
        elseif phase == "host_wait_rejoin" then
            -- The host saw the joiner leave and is hosting again; the next connection starts round 2.
            if st.state == "hosting" then
                round, phase = 2, "wait"
                rel, orderErrors, lastSeq, unrel, peerDone = 0, 0, 0, 0, nil
                U.log("G2: host is waiting again after the partner left (%s)", st.detail)
            end
        elseif phase == "rejoin" then
            if os.time() >= waitUntil then
                round, phase = 2, "start"
            end
        end
        return phase == "end"
    end)
end

-- g3: presence. The joiner's player walks a square (+X, +Y, -X, -Y, 2 s each, twice) once Free Training is up,
-- so the host can check its puppet follows. Both sides log positions (tc_presence logs every 2 s).
local function g3()
    if U.config.role ~= "join" then return end
    local F = require("tc_flow")
    local startAt, lastLog
    local dirs = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }
    U.poll("g3 bot", 16, function()
        if F.activity ~= "training" then return false end
        local pawn = U.playerController() and U.playerController().Pawn
        if not U.valid(pawn) then return false end
        local now = TailCoop_Clock()
        startAt = startAt or (now + 8000)  -- let Free Training settle
        if now < startAt then return false end
        local leg = math.floor((now - startAt) / 2000)
        local l = pawn:K2_GetActorLocation()
        local d
        if leg < 8 then
            d = dirs[leg % 4 + 1]
        else
            -- Finally walk up to the host's character (our puppet of it) so it's on the host's screen.
            local host = require("tc_presence").puppetActor()
            if not U.valid(host) or leg >= 14 then
                U.log("G3 bot: done, final position %.0f %.0f %.0f", l.X, l.Y, l.Z)
                return true
            end
            local h = host:K2_GetActorLocation()
            local dx, dy = h.X - l.X, h.Y - l.Y
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist < 200 then
                U.log("G3 bot: next to the host (%.0f away), final position %.0f %.0f %.0f", dist, l.X, l.Y, l.Z)
                return true
            end
            d = { dx / dist, dy / dist }
        end
        pawn:AddMovementInput({ X = d[1], Y = d[2], Z = 0 }, 1.0, false)
        if not lastLog or now - lastLog >= 1000 then
            lastLog = now
            local v, rv = pawn:GetVelocity(), pawn.CharacterMovement:GetRealVelocity()
            local actorYaw = pawn:K2_GetActorRotation().Yaw
            local meshYaw = pawn.Mesh:K2_GetComponentRotation().Yaw
            local pc = U.playerController()
            local ctrlYaw = pc and pc:GetControlRotation().Yaw or 0
            U.log("G3 bot: leg %d dir %.1f,%.1f at %.0f %.0f %.0f | GetVelocity %.0f RealVelocity %.0f,%.0f | yaw actor %.0f mesh %.0f control %.0f",
                leg, d[1], d[2], l.X, l.Y, l.Z, math.sqrt(v.X * v.X + v.Y * v.Y), rv.X, rv.Y, actorYaw, meshYaw, ctrlYaw)
        end
        return false
    end)
end

-- g3probe: log what Sifu reports for our own player every 500 ms while in an activity (movement comes from real
-- keyboard input sent by Lab\Press.ps1 -HoldMs).
local function g3probe()
    local F = require("tc_flow")
    U.poll("g3 probe", 500, function()
        if not F.activity then return false end
        local pawn = U.playerController() and U.playerController().Pawn
        if not U.valid(pawn) then return false end
        local l, v, rv = pawn:K2_GetActorLocation(), pawn:GetVelocity(), pawn.CharacterMovement:GetRealVelocity()
        local mv = pawn.CharacterMovement.m_vVelocity
        U.log("G3 probe: at %.0f %.0f %.0f | GetVelocity %.0f,%.0f Real %.0f,%.0f m_vVelocity %.0f,%.0f speedstate %s | yaw actor %.0f mesh %.0f",
            l.X, l.Y, l.Z, v.X, v.Y, rv.X, rv.Y, mv.X, mv.Y, tostring(pawn.CharacterMovement:BPF_GetCurrentSpeedState()),
            pawn:K2_GetActorRotation().Yaw, pawn.Mesh:K2_GetComponentRotation().Yaw)
        return false
    end)
end

-- replayrec: does Sifu's replay recording route orders through the MultiCastPlayOrder RPC (which the trace logs
-- with the full FBuffer)? Enters Free Training alone, starts recording, then the trace shows what fires.
local function replayrec()
    local F = require("tc_flow")
    local entered, started = false, false
    U.poll("replayrec", 1000, function()
        if not entered then
            if F.currentMap and FindFirstOf("BP_Menu_Startup_C") then
                entered = F.enterLocal("training")
                U.log("REPLAYREC: entering training: %s", tostring(entered))
            end
            return false
        end
        if F.activity ~= "training" then return false end
        if not started then
            started = true
            local gi = require("UEHelpers").GetGameInstance()
            local rs = gi:BPF_GetReplaySystem()
            U.log("REPLAYREC: replay system %s; calling Replay_Start", U.shortName(rs))
            gi:Replay_Start()
            return false
        end
        return true
    end)
end

-- animslot: single-system check of the G4 playback tools (no network, no input needed).
local function animslot()
    local F = require("tc_flow")
    local P = require("tc_presence")
    local A = require("tc_anim")
    local entered, dummy, step, nextAt = false, nil, 0, 0
    U.poll("animslot", 500, function()
        if not entered then
            if F.currentMap and FindFirstOf("BP_Menu_Startup_C") then entered = F.enterLocal("training") end
            return false
        end
        if F.activity ~= "training" then return false end
        local pawn = U.playerController() and U.playerController().Pawn
        if not U.valid(pawn) then return false end
        local now = TailCoop_Clock()
        if now < nextAt then return false end
        local inst = A.animInstance(pawn)
        if step == 0 then
            local l, fwd = pawn:K2_GetActorLocation(), pawn:GetActorForwardVector()
            dummy = P.spawnCharacter(pawn:GetClass(), { x = l.X + fwd.X * 250, y = l.Y + fwd.Y * 250, z = l.Z })
            U.log("ANIMSLOT: player anim instance %s, move status %s; test character %s", U.shortName(inst),
                tostring(A.moveStatus(pawn)), U.shortName(dummy))
            local okIdle, idle = pcall(function() return inst.m_IdleAnimContainerFL.m_animation end)
            U.log("ANIMSLOT: player idle FL anim %s", okIdle and tostring(A.path(idle)) or ("error " .. tostring(idle)))
            for _, a in ipairs(A.actions(inst)) do
                U.log("ANIMSLOT: player action %s = %s (rate %.2f mirror %s)", a.kind, a.path, a.rate or 0, tostring(a.mirror))
            end
            U.log("ANIMSLOT: test character move status %s", tostring(A.moveStatus(dummy)))
            step, nextAt = 1, now + 4000
        elseif step == 1 then
            U.log("ANIMSLOT: step 1 - copy move status %s to the test character", tostring(A.moveStatus(pawn)))
            A.setMoveStatus(dummy, A.moveStatus(pawn))
            U.log("ANIMSLOT: test character move status now %s", tostring(A.moveStatus(dummy)))
            step, nextAt = 2, now + 5000
        elseif step == 2 then
            local idle = inst.m_IdleAnimContainerFL.m_animation
            local montage = A.play(dummy, idle, 1.0, 0.0)
            U.log("ANIMSLOT: step 2 - slot '%s' play %s -> montage %s", A.SLOT, tostring(A.path(idle)), U.shortName(montage))
            step, nextAt = 3, now + 5000
        else
            U.log("ANIMSLOT: done")
            return true
        end
        return false
    end)
end

-- g5: shared enemy health without input. Joiner damages its copy of the first enemy by 25 at +15 s (simulating a hit);
-- host damages the real enemy by 10 at +25 s. Both log the enemy's health every 2 s; they must converge.
local function g5()
    local F = require("tc_flow")
    local E = require("tc_enemies")
    local startAt, didJoin, didHost, lastLog
    U.poll("g5", 250, function()
        if F.activity ~= "training" then return false end
        local now = TailCoop_Clock()
        startAt = startAt or now
        local list = E.list()
        local first = list[1]
        if not first then return false end
        if U.config.role == "join" and not didJoin and now - startAt > 15000 then
            didJoin = true
            U.log("G5: joiner takes 25 health off its copy of %s (health %.1f)", first.id, E.health(first.actor) or -1)
            first.actor.m_HealthComponent:BPF_ServerAddHealth(-25)
            U.log("G5: joiner's copy now %.1f", E.health(first.actor) or -1)
        end
        if U.config.role == "host" and not didHost and now - startAt > 25000 then
            didHost = true
            U.log("G5: host takes 10 health off %s (health %.1f)", first.id, E.health(first.actor) or -1)
            first.actor.m_HealthComponent:BPF_ServerAddHealth(-10)
            U.log("G5: host's enemy now %.1f", E.health(first.actor) or -1)
        end
        if not lastLog or now - lastLog >= 2000 then
            lastLog = now
            local l = first.actor:K2_GetActorLocation()
            U.log("G5: %s health %.1f at %.0f %.0f %.0f", first.id, E.health(first.actor) or -1, l.X, l.Y, l.Z)
        end
        return now - startAt > 40000
    end)
end

-- animraw: single-system check of tc_anim's raw action reader (TailCoop_Peek / TailCoop_ObjectPath) in Free Training.
local function animraw()
    local F = require("tc_flow")
    local A = require("tc_anim")
    local entered, checks = false, 0
    U.poll("animraw", 1000, function()
        if not entered then
            if F.currentMap and FindFirstOf("BP_Menu_Startup_C") then entered = F.enterLocal("training") end
            return false
        end
        if F.activity ~= "training" then return false end
        local pawn = U.playerController() and U.playerController().Pawn
        if not U.valid(pawn) then return false end
        checks = checks + 1
        if checks == 1 then
            U.log("ANIMRAW: ObjectPath(pawn) = %s | GetFullName = %s", tostring(A.pathOf(pawn:GetAddress())),
                pawn:GetFullName())
            U.log("ANIMRAW: ObjectPath(bad address) = %s", tostring(TailCoop_ObjectPath("4096")))
            U.log("ANIMRAW: Peek(bad address) = %s", tostring(TailCoop_Peek("123456", "0", "ptr")))
        end
        local chars = { { "player", pawn } }
        for _, e in ipairs(require("tc_enemies").list()) do chars[#chars + 1] = { e.id, e.actor } end
        for _, c in ipairs(chars) do
            local inst = A.animInstance(c[2])
            local tracks, last = A.readRaw(inst)
            if not tracks then
                U.log("ANIMRAW: %s anim %s not readable", c[1], U.shortName(inst))
            else
                local parts = {}
                for _, t in ipairs(tracks) do
                    parts[#parts + 1] = string.format("%s=%s(o%d r%.2f s%.2f m%s)", t.key, tostring(A.pathOf(t.ptr)),
                        t.order, t.rate, t.start, tostring(t.mirror))
                end
                U.log("ANIMRAW: %s (%s) tracks [%s] last %s cursor %.2f mirror %s", c[1], U.shortName(inst),
                    table.concat(parts, ", "), tostring(A.pathOf(last.ptr)), last.cursor, tostring(last.mirror))
            end
        end
        return checks >= 8
    end)
end

-- walkprobe: single-system check that a driven copy walks and plays moves. A test character circles next to the
-- player (phases: A = tc_anim.drive only, B = drive + AddMovementInput), then plays a punch and a hit reaction.
-- Logs "WALKPROBE phase X" lines; the lab script takes screenshots meanwhile.
local function walkprobe()
    local F = require("tc_flow")
    local P = require("tc_presence")
    local A = require("tc_anim")
    local entered, dummy, t0, center, st, lastLog, phase = false, nil, nil, nil, {}, 0, nil
    local PUNCH = "/Game/Animations/MainChar/Attacks/Man/Barehands/LightCombo/MainChar_Attack_Man_Barehands_Pressure_Hook_BL.MainChar_Attack_Man_Barehands_Pressure_Hook_BL"
    local HIT = "/Game/Animations/MainChar/HitReactions/Man/Barehands/Strong/High/MC_Man_Barehands_HitReaction_Strong_High_East.MC_Man_Barehands_HitReaction_Strong_High_East"
    local played = {}
    U.poll("walkprobe", 16, function()
        if not entered then
            if F.currentMap and FindFirstOf("BP_Menu_Startup_C") then entered = F.enterLocal("training") end
            return false
        end
        if F.activity ~= "training" then return false end
        local pawn = U.playerController() and U.playerController().Pawn
        if not U.valid(pawn) then return false end
        local now = TailCoop_Clock()
        if not dummy then
            if not t0 then t0 = now + 3000 end
            if now < t0 then return false end
            local l = pawn:K2_GetActorLocation()
            local fwd = pawn:GetActorForwardVector()
            center = { x = l.X + fwd.X * 450, y = l.Y + fwd.Y * 450, z = l.Z }
            dummy = P.spawnCharacter(pawn:GetClass(), { x = center.x + 200, y = center.y, z = center.z })
            A.makeDriven(dummy)
            A.setMoveStatus(dummy, 1)
            t0 = now
            U.log("WALKPROBE start: dummy %s", U.shortName(dummy))
            return false
        end
        local t = (now - t0) / 1000
        local newPhase = t < 8 and "A" or (t < 16 and "B" or (t < 20 and "STILL" or (t < 24 and "PUNCH" or (t < 28 and "HIT" or "DONE"))))
        if newPhase ~= phase then
            phase = newPhase
            U.log("WALKPROBE phase %s", phase)
        end
        if phase == "A" or phase == "B" then
            local ang = t * 1.4  -- 200 radius * 1.4 rad/s = 280 u/s
            local x, y = center.x + math.cos(ang) * 200, center.y + math.sin(ang) * 200
            local yaw = math.deg(ang) + 90
            local vx, vy = -math.sin(ang) * 280, math.cos(ang) * 280
            A.drive(dummy, st, x, y, center.z, yaw, now, vx, vy)
            if phase == "B" then
                pcall(function() dummy:AddMovementInput({ X = vx / 280, Y = vy / 280, Z = 0 }, 1.0, true) end)
            end
        elseif phase == "STILL" then
            A.drive(dummy, st, center.x, center.y, center.z, 0, now, 0, 0)
        elseif (phase == "PUNCH" or phase == "HIT") and not played[phase] then
            played[phase] = true
            local asset = require("tc_moves").resolve(phase == "PUNCH" and PUNCH or HIT)
            local m = A.play(dummy, asset, 1.0, 0, 0.05, 0.15, phase == "HIT")
            local inst = A.animInstance(dummy)
            local okP, playing = pcall(function() return inst:Montage_IsPlaying(m) end)
            U.log("WALKPROBE %s: asset %s montage %s playing %s", phase, tostring(A.path(asset)), U.shortName(m),
                tostring(okP and playing))
        elseif phase == "DONE" then
            U.log("WALKPROBE done")
            return true
        end
        if now - lastLog >= 500 then
            lastLog = now
            local inst = A.animInstance(dummy)
            local mv = dummy.CharacterMovement
            local okA, s = pcall(function()
                local v, a = mv.Velocity, mv.Acceleration
                return string.format("vel %.0f accel %.0f mode %s | anim ownerVel %.0f wanted %.0f status %s montage %s",
                    math.sqrt(v.X ^ 2 + v.Y ^ 2), math.sqrt(a.X ^ 2 + a.Y ^ 2), tostring(mv.MovementMode),
                    inst.m_fOwnerVelocityLength, inst.m_fWantedSpeed, tostring(A.moveStatus(dummy)),
                    U.shortName(inst:GetCurrentActiveMontage()))
            end)
            U.log("WALKPROBE %s t=%.1f %s", phase, t, okA and s or ("error " .. tostring(s)))
        end
        return false
    end)
end

-- subprobe: logs every change in the player's and enemies' sub anim instances (and the main anim's last action).
local function subprobe()
    local F = require("tc_flow")
    local A = require("tc_anim")
    local entered, prev, n = false, {}, 0
    U.poll("subprobe", 10, function()
        if not entered then
            if F.currentMap and FindFirstOf("BP_Menu_Startup_C") then entered = F.enterLocal("training") end
            return false
        end
        if F.activity ~= "training" then return false end
        local pawn = U.playerController() and U.playerController().Pawn
        if not U.valid(pawn) then return false end
        local now = TailCoop_Clock()
        local chars = { { "player", pawn } }
        for _, e in ipairs(require("tc_enemies").list()) do chars[#chars + 1] = { e.id, e.actor } end
        for _, c in ipairs(chars) do
            for _, s in ipairs(A.readSubs(c[2], now)) do
                local sig = string.format("%s o%d a%.1f m%s", tostring(s.ptr), s.order, s.alpha, tostring(s.mirror))
                if prev[c[1] .. s.key] ~= sig then
                    prev[c[1] .. s.key] = sig
                    n = n + 1
                    U.log("SUBPROBE %s %s order %d alpha %.2f mirror %s rate %.2f start %.2f %s", c[1], s.key, s.order,
                        s.alpha, tostring(s.mirror), s.rate, s.start, tostring(A.pathOf(s.ptr)))
                end
            end
        end
        return n > 400
    end)
end

-- walkprobe2: does a copy really walk (legs) or slide? Measured from the foot bone's swing relative to the body.
-- Phases (8 s each) around a circle next to the player:
--   AI  = possessed by an AIController, moved with MoveToLocation (the way Sifu moves its enemies)
--   IN  = AddMovementInput only (collision on, pawns ignored)
--   TP  = tc_anim.drive teleport + velocity writes (what the build used so far)
local function walkprobe2()
    local F = require("tc_flow")
    local P = require("tc_presence")
    local A = require("tc_anim")
    local UEHelpers = require("UEHelpers")
    local entered, dummy, ctrl, t0, center, st, phase = false, nil, nil, nil, nil, {}, nil
    local footBone, footBoneR, win = nil, nil, nil
    local lastMove = 0
    U.poll("walkprobe2", 16, function()
        if not entered then
            if F.currentMap and FindFirstOf("BP_Menu_Startup_C") then entered = F.enterLocal("training") end
            return false
        end
        if F.activity ~= "training" then return false end
        local pawn = U.playerController() and U.playerController().Pawn
        if not U.valid(pawn) then return false end
        local now = TailCoop_Clock()
        if not dummy then
            if not t0 then t0 = now + 3000 end
            if now < t0 then return false end
            local l, fwd = pawn:K2_GetActorLocation(), pawn:GetActorForwardVector()
            center = { x = l.X + fwd.X * 500, y = l.Y + fwd.Y * 500, z = l.Z }
            dummy = P.spawnCharacter(pawn:GetClass(), { x = center.x + 250, y = center.y, z = center.z })
            -- Collision back on so it has a floor, but pawns pass through it.
            dummy:SetActorEnableCollision(true)
            pcall(function() dummy.CapsuleComponent:SetCollisionResponseToChannel(2, 0) end)  -- ECC_Pawn -> Ignore
            dummy.CharacterMovement:SetMovementMode(1, 0)
            local mesh = dummy.Mesh
            for i = 0, mesh:GetNumBones() - 1 do
                local fn = mesh:GetBoneName(i)
                local n = fn:ToString():lower()
                if n == "foot_l" then footBone = fn end
                if n == "foot_r" then footBoneR = fn end
            end
            U.log("WALK2 start: dummy %s feet %s %s", U.shortName(dummy), footBone and footBone:ToString() or "-", footBoneR and footBoneR:ToString() or "-")
            local okC, c = pcall(function()
                if true then return nil end
                local gs = UEHelpers.GetGameplayStatics()
                local cls = StaticFindObject("/Script/AIModule.AIController")
                local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = center.x, Y = center.y, Z = center.z },
                    Scale3D = { X = 1, Y = 1, Z = 1 } }
                local a = gs:BeginDeferredActorSpawnFromClass(U.world(), cls, xf, 1, nil)
                gs:FinishSpawningActor(a, xf)
                a:Possess(dummy)
                return a
            end)
            ctrl = okC and c or nil
            U.log("WALK2 AI controller %s (%s)", U.shortName(ctrl), okC and "ok" or tostring(c))
            t0 = now
            return false
        end
        local t = (now - t0) / 1000
        local newPhase = t < 4 and "TP" or (t < 11 and "LOCO_TENSE" or (t < 18 and "LOCO_FREE" or (t < 21 and "STOP" or "DONE")))
        if newPhase ~= phase then
            if phase == "AI" and ctrl then pcall(function() ctrl:StopMovement() end) end
            phase = newPhase
            U.log("WALK2 phase %s", phase)
        end
        if phase == "DONE" then
            U.log("WALK2 done")
            return true
        end
        local ang = t * 1.2
        local vx, vy = -math.sin(ang) * 300, math.cos(ang) * 300
        if phase == "AI" then
            if ctrl and now - lastMove > 200 then
                lastMove = now
                local a2 = ang + 0.6
                local ok, r = pcall(function()
                    return ctrl:MoveToLocation({ X = center.x + math.cos(a2) * 250, Y = center.y + math.sin(a2) * 250, Z = center.z },
                        10, false, true, true, false, nil, true)
                end)
                if not ok then U.log("WALK2 MoveToLocation error %s", tostring(r)) end
            end
        elseif phase == "IN" then
            pcall(function() dummy:AddMovementInput({ X = vx / 300, Y = vy / 300, Z = 0 }, 1.0, true) end)
        elseif phase == "TP" or phase:find("LOCO") then
            -- LOCO_TENSE faces the circle's center (strafing); LOCO_FREE faces the way it walks.
            local yaw = phase == "LOCO_TENSE" and (math.deg(ang) + 180) or (math.deg(ang) + 90)
            A.drive(dummy, st, center.x + math.cos(ang) * 250, center.y + math.sin(ang) * 250, center.z, yaw, now, vx, vy)
            if phase ~= "TP" then A.locomotion(dummy, st, yaw, phase == "LOCO_TENSE", now) end
        elseif phase == "STOP" then
            A.drive(dummy, st, dummy:K2_GetActorLocation().X, dummy:K2_GetActorLocation().Y, center.z, 0, now, 0, 0)
            A.locomotion(dummy, st, 0, false, now)
        end
        -- Foot swing: foot position in the actor's frame; walking = it travels back and forth along the body.
        if footBone then
            local okF, f = pcall(function()
                local fl = dummy.Mesh:GetSocketLocation(footBone)
                local al = dummy:K2_GetActorLocation()
                local fwd = dummy:GetActorForwardVector()
                return (fl.X - al.X) * fwd.X + (fl.Y - al.Y) * fwd.Y
            end)
            if okF then
                -- Stride: distance between the feet. Walking makes it open and close; sliding keeps it fixed.
                local okR, stride = pcall(function()
                    local a, b = dummy.Mesh:GetSocketLocation(footBone), dummy.Mesh:GetSocketLocation(footBoneR)
                    return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2)
                end)
                f = okR and stride or 0
                win = win or { min = f, max = f, start = now, n = 0, dist = 0 }
                win.min, win.max, win.n = math.min(win.min, f), math.max(win.max, f), win.n + 1
                local l = dummy:K2_GetActorLocation()
                if win.lx then win.dist = win.dist + math.sqrt((l.X - win.lx) ^ 2 + (l.Y - win.ly) ^ 2) end
                win.lx, win.ly = l.X, l.Y
                if now - win.start >= 1000 then
                    local inst = A.animInstance(dummy)
                    local okS, s = pcall(function()
                        local mv = dummy.CharacterMovement
                        local v = mv.Velocity
                        local fl = dummy.Mesh:GetSocketLocation(footBone)
                        return string.format("vel %.0f mode %s ownerVel %.0f | loco %s montage %s playing %s | foot %.0f %.0f %.0f",
                            math.sqrt(v.X ^ 2 + v.Y ^ 2), tostring(mv.MovementMode), inst.m_fOwnerVelocityLength,
                            tostring(st.locoPath), U.shortName(inst:GetCurrentActiveMontage()),
                            tostring(st.locoMontage and inst:Montage_IsPlaying(st.locoMontage)), fl.X, fl.Y, fl.Z)
                    end)
                    U.log("WALK2 %s t=%.0f moved %.0f/s stride range %.0f (%d samples) %s", phase, t, win.dist, win.max - win.min,
                        win.n, okS and s or tostring(s))
                    win = nil
                end
            end
        end
        return false
    end)
end

-- singlenode: a copy whose mesh plays sequences directly (AnimationSingleNode, Sifu's anim graph bypassed).
-- Walks a small circle in view (walk cycle), then punches, then idles. Measures stride like walkprobe2.
local function singlenode()
    local F = require("tc_flow")
    local P = require("tc_presence")
    local A = require("tc_anim")
    local entered, dummy, t0, center, st, phase, fl, fr, win = false, nil, nil, nil, {}, nil, nil, nil, nil
    local BASE = "/Game/Animations/MainChar/"
    local WALK = BASE .. "Locomotion/Man/Barehands/Moving/V1/Freemove/North/MC_man_barehands_V1_north.MC_man_barehands_V1_north"
    local PUNCH = BASE .. "Attacks/Man/Barehands/LightCombo/MainChar_Attack_Man_Barehands_Pressure_Hook_BL.MainChar_Attack_Man_Barehands_Pressure_Hook_BL"
    U.poll("singlenode", 16, function()
        if not entered then
            if F.currentMap and FindFirstOf("BP_Menu_Startup_C") then entered = F.enterLocal("training") end
            return false
        end
        if F.activity ~= "training" then return false end
        local pawn = U.playerController() and U.playerController().Pawn
        if not U.valid(pawn) then return false end
        local now = TailCoop_Clock()
        if not dummy then
            if not t0 then t0 = now + 3000 end
            if now < t0 then return false end
            local l, fwd = pawn:K2_GetActorLocation(), pawn:GetActorForwardVector()
            center = { x = l.X + fwd.X * 380 - fwd.Y * 150, y = l.Y + fwd.Y * 380 + fwd.X * 150, z = l.Z }
            dummy = P.spawnCharacter(pawn:GetClass(), { x = center.x, y = center.y, z = center.z })
            A.makeDriven(dummy)
            local mesh = dummy.Mesh
            for i = 0, mesh:GetNumBones() - 1 do
                local fn = mesh:GetBoneName(i)
                local n = fn:ToString():lower()
                if n == "foot_l" then fl = fn end
                if n == "foot_r" then fr = fn end
            end
            t0 = now
            U.log("SN start %s", U.shortName(dummy))
            return false
        end
        local t = (now - t0) / 1000
        local newPhase = t < 2 and "GRAPH" or (t < 10 and "WALK" or (t < 13 and "PUNCH" or (t < 16 and "BACK" or "DONE")))
        if newPhase ~= phase then
            phase = newPhase
            local mesh = dummy.Mesh
            local ok, err = pcall(function()
                if phase == "WALK" then
                    mesh:PlayAnimation(require("tc_moves").resolve(WALK), true, true, true, false)
                elseif phase == "PUNCH" then
                    mesh:PlayAnimation(require("tc_moves").resolve(PUNCH), false, true, true, false)
                elseif phase == "BACK" then
                    mesh:SetAnimationMode(0, true, true)  -- back to Sifu's anim graph
                end
            end)
            U.log("SN phase %s (%s) mode %s anim %s", phase, ok and "ok" or tostring(err),
                tostring(mesh.AnimationMode), U.shortName(mesh:GetAnimInstance()))
        end
        if phase == "DONE" then
            U.log("SN done")
            return true
        end
        if phase == "WALK" then
            local ang = (t - 2) * 1.2
            local vx, vy = -math.sin(ang) * 180, math.cos(ang) * 180
            A.drive(dummy, st, center.x + math.cos(ang) * 150, center.y + math.sin(ang) * 150, center.z, math.deg(ang) + 90,
                now, vx, vy)
        else
            A.drive(dummy, st, dummy:K2_GetActorLocation().X, dummy:K2_GetActorLocation().Y, center.z,
                dummy:K2_GetActorRotation().Yaw, now, 0, 0)
        end
        local okR, stride = pcall(function()
            local a, b = dummy.Mesh:GetSocketLocation(fl), dummy.Mesh:GetSocketLocation(fr)
            return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2)
        end)
        if okR then
            win = win or { min = stride, max = stride, start = now }
            win.min, win.max = math.min(win.min, stride), math.max(win.max, stride)
            if now - win.start >= 1000 then
                U.log("SN %s t=%.0f stride range %.0f (%.0f..%.0f)", phase, t, win.max - win.min, win.min, win.max)
                win = nil
            end
        end
        return false
    end)
end

-- tickdiag: why a spawned copy's pose doesn't move. Logs anim tick settings of the player and a copy playing a walk
-- cycle directly (single node), then forces ticking on, measuring the copy's stride and playback position.
local function tickdiag()
    local F = require("tc_flow")
    local P = require("tc_presence")
    local A = require("tc_anim")
    local entered, dummy, t0, phase, fl, fr, win, forced = false, nil, nil, nil, nil, nil, nil, false
    local WALK = "/Game/Animations/MainChar/Locomotion/Man/Barehands/Moving/V1/Freemove/North/MC_man_barehands_V1_north.MC_man_barehands_V1_north"
    local function state(who, ch)
        local m = ch.Mesh
        local parts = {}
        local function add(label, fn)
            local ok, v = pcall(fn)
            parts[#parts + 1] = label .. "=" .. (ok and tostring(v) or "err")
        end
        add("mode", function() return m.AnimationMode end)
        add("compTick", function() return m:IsComponentTickEnabled() end)
        add("actorTick", function() return ch:IsActorTickEnabled() end)
        add("visTick", function() return m.VisibilityBasedAnimTickOption end)
        add("pause", function() return m.bPauseAnims end)
        add("noSkel", function() return m.bNoSkeletonUpdate end)
        add("rate", function() return m.GlobalAnimRateScale end)
        add("dilation", function() return ch.CustomTimeDilation end)
        add("uro", function() return m.bEnableUpdateRateOptimizations end)
        add("rendered", function() return m:WasRecentlyRendered(0.2) end)
        add("pos", function() return string.format("%.2f", m:GetPosition()) end)
        add("playing", function() return m:IsPlaying() end)
        add("tickGroup", function() return m.PrimaryComponentTick.TickGroup end)
        add("hidden", function() return ch.bHidden end)
        return who .. " " .. table.concat(parts, " ")
    end
    U.poll("tickdiag", 16, function()
        if not entered then
            if F.currentMap and FindFirstOf("BP_Menu_Startup_C") then entered = F.enterLocal("training") end
            return false
        end
        if F.activity ~= "training" then return false end
        local pawn = U.playerController() and U.playerController().Pawn
        if not U.valid(pawn) then return false end
        local now = TailCoop_Clock()
        if not dummy then
            if not t0 then t0 = now + 3000 end
            if now < t0 then return false end
            local l, fwd = pawn:K2_GetActorLocation(), pawn:GetActorForwardVector()
            dummy = P.spawnCharacter(pawn:GetClass(), { x = l.X + fwd.X * 300, y = l.Y + fwd.Y * 300, z = l.Z })
            A.makeDriven(dummy)
            local mesh = dummy.Mesh
            for i = 0, mesh:GetNumBones() - 1 do
                local fn = mesh:GetBoneName(i)
                local n = fn:ToString():lower()
                if n == "foot_l" then fl = fn end
                if n == "foot_r" then fr = fn end
            end
            mesh:PlayAnimation(require("tc_moves").resolve(WALK), true, false, false, false)
            t0 = now
            U.log("TICK %s", state("player", pawn))
            U.log("TICK copy anim instance now %s", U.shortName(mesh:GetAnimInstance()))
            return false
        end
        local t = (now - t0) / 1000
        if t > 6 and not forced then
            forced = true
            local m = dummy.Mesh
            local results = {}
            local function try(label, fn)
                local ok, err = pcall(fn)
                results[#results + 1] = label .. (ok and "" or ("!" .. tostring(err):sub(-60)))
            end
            try("dilation", function() dummy.CustomTimeDilation = 1.0 end)
            try("actorTick", function() dummy:SetActorTickEnabled(true) end)
            try("compTick", function() m:SetComponentTickEnabled(true) end)
            try("visTick", function() m.VisibilityBasedAnimTickOption = 0 end)
            try("pause", function() m.bPauseAnims = false end)
            try("noSkel", function() m.bNoSkeletonUpdate = false end)
            try("rate", function() m.GlobalAnimRateScale = 1.0 end)
            try("uro", function() m.bEnableUpdateRateOptimizations = false end)
            try("play", function() m:Play(true) end)
            U.log("TICK forced: %s", table.concat(results, " "))
        end
        local okR, stride = pcall(function()
            local a, b = dummy.Mesh:GetSocketLocation(fl), dummy.Mesh:GetSocketLocation(fr)
            return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2)
        end)
        win = win or { min = 1e9, max = -1e9, start = now }
        if okR then win.min, win.max = math.min(win.min, stride), math.max(win.max, stride) end
        if now - win.start >= 1000 then
            U.log("TICK t=%.0f stride range %.0f | %s", t, win.max - win.min, state("copy", dummy))
            win = nil
        end
        return t > 12
    end)
end

-- approach: the joiner's player is placed 130 units in front of the first enemy, facing it, 20 s into the session
-- (so input tests can hit the joiner's copy of the enemy).
local function approach()
    local F = require("tc_flow")
    local startAt, done = nil, false
    U.poll("approach", 500, function()
        if U.config.role ~= "join" or F.activity ~= "training" then return false end
        local now = TailCoop_Clock()
        startAt = startAt or now
        if now - startAt < 20000 then return false end
        startAt = now - 20000 + 30000  -- again in 30 s
        local e = require("tc_enemies").list()[1]
        local pawn = U.playerController() and U.playerController().Pawn
        if not (e and U.valid(pawn)) then return false end
        local l, fwd = e.actor:K2_GetActorLocation(), e.actor:GetActorForwardVector()
        local at = { X = l.X + fwd.X * 130, Y = l.Y + fwd.Y * 130, Z = pawn:K2_GetActorLocation().Z }
        local yaw = math.deg(math.atan(-fwd.Y, -fwd.X))
        pawn:K2_SetActorLocationAndRotation(at, { Pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
        pcall(function() U.playerController():SetControlRotation({ Pitch = -10, Yaw = yaw, Roll = 0 }) end)
        U.log("APPROACH: placed at %.0f %.0f facing %s (%.0f)", at.X, at.Y, e.id, yaw)
        return false
    end)
end

-- hittest (solo): which part of "following the host" stops our hits from registering on an enemy copy.
-- Phases of 10 s; each adds one takeover step and re-places the player in front of the dummy. An input script
-- punches throughout; health per phase is logged.
local function hittest()
    local F = require("tc_flow")
    local A = require("tc_anim")
    local entered, t0, phase, st, h0 = false, nil, -1, {}, nil
    local steps = {
        { "untouched", function() end },
        { "StopLogic", function(c) c.Controller.BrainComponent:StopLogic("test") end },
        { "ForgetEnemy", function(c) c.m_AIComponent:BPF_ForgetEnemy() end },
        { "MOVE_None", function(c) A.makeDriven(c) end },
        -- { "single node", ... } crashes the game (Sifu's order code reads the replaced anim instance)
    }
    U.poll("hittest", 100, function()
        if not entered then
            if F.currentMap and FindFirstOf("BP_Menu_Startup_C") then entered = F.enterLocal("training") end
            return false
        end
        if F.activity ~= "training" then return false end
        local pawn = U.playerController() and U.playerController().Pawn
        local e = require("tc_enemies").list()[1]
        if not (U.valid(pawn) and e) then return false end
        local c = e.actor
        local now = TailCoop_Clock()
        t0 = t0 or now + 2000
        local p = math.floor((now - t0) / 10000)
        if p < 0 then return false end
        if p ~= phase then
            local h = c.m_HealthComponent.m_fHealth
            if phase >= 0 then U.log("HITTEST phase %d (%s): health %.0f -> %.0f", phase, steps[phase + 1][1], h0, h) end
            if p >= #steps then
                U.log("HITTEST done")
                return true
            end
            phase = p
            pcall(function() c.m_HealthComponent:BPF_ServerSetHealth(c.m_HealthComponent.m_fMaxHealth) end)
            local ok, err = pcall(steps[p + 1][2], c)
            local l, fwd = c:K2_GetActorLocation(), c:GetActorForwardVector()
            local yaw = math.deg(math.atan(-fwd.Y, -fwd.X))
            pawn:K2_SetActorLocationAndRotation({ X = l.X + fwd.X * 120, Y = l.Y + fwd.Y * 120, Z = pawn:K2_GetActorLocation().Z },
                { Pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
            h0 = c.m_HealthComponent.m_fHealth
            U.log("HITTEST phase %d: %s (%s), health %.0f", p, steps[p + 1][1], ok and "ok" or tostring(err), h0)
        end
        return false
    end)
end

-- enemytwin (solo): the joiner-side enemy design. The real dummy is taken over (AI stopped, movement off) and hidden;
-- a visual twin of its class (no AI controller) stands in its place and plays the dummy's actions directly, like a
-- host's actions would arrive. Punched throughout by an input script: dummy order events must keep coming (hits
-- register on the hidden dummy), the twin must play them, and the game must not crash.
local function enemytwin()
    local F = require("tc_flow")
    local A = require("tc_anim")
    local P = require("tc_presence")
    local entered, dummy, twin, st, w, t0, placed, plays, lastLog = false, nil, nil, {}, nil, nil, false, 0, 0
    U.poll("enemytwin", 16, function()
        if not entered then
            if F.currentMap and FindFirstOf("BP_Menu_Startup_C") then entered = F.enterLocal("training") end
            return false
        end
        if F.activity ~= "training" then return false end
        local pawn = U.playerController() and U.playerController().Pawn
        local e = require("tc_enemies").list()[1]
        if not (U.valid(pawn) and e) then return false end
        local now = TailCoop_Clock()
        t0 = t0 or now + 2000
        if now < t0 then return false end
        if not dummy then
            dummy = e.actor
            w = A.watcher()
            pcall(function() dummy.Controller.BrainComponent:StopLogic("test") end)
            pcall(function() dummy.m_AIComponent:BPF_ForgetEnemy() end)
            A.makeDriven(dummy)
            local l = dummy:K2_GetActorLocation()
            twin = P.spawnCharacter(dummy:GetClass(), { x = l.X, y = l.Y, z = l.Z })
            A.makeDriven(twin)
            twin:SetActorEnableCollision(false)
            A.hideReal(dummy)
            U.log("TWIN start: dummy %s hidden, twin %s controller %s", U.shortName(dummy), U.shortName(twin),
                U.shortName(twin.Controller))
            return false
        end
        if not placed then
            placed = true
            local l, fwd = dummy:K2_GetActorLocation(), dummy:GetActorForwardVector()
            pawn:K2_SetActorLocationAndRotation({ X = l.X + fwd.X * 120, Y = l.Y + fwd.Y * 120, Z = pawn:K2_GetActorLocation().Z },
                { Pitch = 0, Yaw = math.deg(math.atan(-fwd.Y, -fwd.X)), Roll = 0 }, false, {}, true)
            U.log("TWIN ready")
        end
        -- The twin follows the hidden dummy and plays what it plays (as the host's "eact" would).
        A.hideReal(dummy)
        local l, r = dummy:K2_GetActorLocation(), dummy:K2_GetActorRotation()
        A.drive(twin, st, l.X, l.Y, l.Z, r.Yaw, now)
        local ev = w:update(dummy, now)
        if ev and ev.kind == "start" and ev.path then
            local asset = A.sequence(ev.path)
            if asset and A.copyAction(twin, st, asset, ev.rate, A.startTime(asset, ev.cursor, ev.start, 0, ev.rate), ev.mirror, now) then
                plays = plays + 1
            end
        elseif ev and ev.kind == "end" then
            A.copyActionEnd(st)
        end
        A.copyLocomotion(twin, st, true, now)
        A.strideSample(twin, st)
        if now - lastLog >= 2000 then
            lastLog = now
            U.log("TWIN t=%.0f twin played %d, %s", (now - t0) / 1000, plays, A.strideReport(st))
        end
        return now - t0 > 50000
    end)
end

-- The most-derived override of `funcName` on obj's class chain (what the engine itself calls), or nil.
local function functionFor(obj, funcName)
    local ok, cls = pcall(function() return obj:GetClass() end)
    while ok and U.valid(cls) do
        local path = cls:GetFullName():match("%s(.+)$")
        local fn = path and StaticFindObject(path .. ":" .. funcName)
        if U.valid(fn) then return fn end
        ok, cls = pcall(function() return cls:GetSuperStruct() end)
    end
    return nil
end
T.functionFor = functionFor

-- hitreplay (solo): captures a real hit on the dummy (FightingCharacter:Hitted) as Unreal text, then - with nobody
-- pressing anything - replays it 4 times through TailCoop_CallImported. The dummy must react each time.
local function hitreplay()
    local F = require("tc_flow")
    local A = require("tc_anim")
    local HIT_SIZE = "1440"  -- sizeof(FHitDescription) = 0x5A0
    local entered, hooked, captured, capturedAt, replaying, replays, lastReplay, w = false, false, nil, 0, false, 0, 0, nil
    local baseFn
    U.poll("hitreplay", 20, function()
        if not entered then
            if F.currentMap and FindFirstOf("BP_Menu_Startup_C") then entered = F.enterLocal("training") end
            return false
        end
        if F.activity ~= "training" then return false end
        local now = TailCoop_Clock()
        local e = require("tc_enemies").list()[1]
        if not hooked and e then
            hooked = true
            baseFn = StaticFindObject("/Script/Sifu.FightingCharacter:Hitted")
            local derived = functionFor(e.actor, "Hitted")
            for _, fn in ipairs({ baseFn, derived }) do
                local ok, err = TailCoop_WatchParam(tostring(fn:GetAddress()), HIT_SIZE)
                U.log("HITREPLAY watching %s: %s %s", fn:GetFullName(), tostring(ok), tostring(err))
            end
            U.log("HITREPLAY hooked Hitted")
        end
        while true do
            local ctxAddr, fnAddr, text = TailCoop_PollCaptured()
            if not ctxAddr then break end
            if not replaying then
                U.log("HITREPLAY captured hit on %s via %s: %d chars", tostring(ctxAddr), tostring(fnAddr), #text)
                captured, capturedAt = { text = text }, now
                if not T.loggedText then
                    T.loggedText = true
                    for i = 1, #text, 900 do U.log("HITREPLAY text: %s", text:sub(i, i + 899)) end
                end
            end
        end
        if e then
            w = w or A.watcher()
            local ev = w:update(e.actor, now)
            if ev and ev.kind == "start" then U.log("HITREPLAY dummy plays %s", tostring(ev.path)) end
        end
        if captured and now - capturedAt > 4000 and now - lastReplay > 3000 and replays < 4 and e then
            lastReplay, replays = now, replays + 1
            local Hits = require("tc_hits")
            local m = Hits.members(captured.text)
            local pawn = U.playerController().Pawn
            local victimHit, playerHit = e.actor.m_HitComponent, pawn.m_HitComponent
            local variants = {
                { "base Hitted on dummy", e.actor, baseFn, { captured.text, HIT_SIZE } },
                { "GenerateForeignImpact on dummy's HitComponent", victimHit,
                  StaticFindObject("/Script/Sifu.HitComponent:BPF_GenerateForeignImpact"),
                  { m.m_Result, tostring(Hits.SIZE.result), m.m_Request, tostring(Hits.SIZE.request) } },
                { "GenerateForeignImpact on player's HitComponent", playerHit,
                  StaticFindObject("/Script/Sifu.HitComponent:BPF_GenerateForeignImpact"),
                  { m.m_Result, tostring(Hits.SIZE.result), m.m_Request, tostring(Hits.SIZE.request) } },
                { "GenerateFakeImpact on dummy's HitComponent", victimHit,
                  StaticFindObject("/Script/Sifu.HitComponent:BPF_GenerateFakeImpact"),
                  { m.m_Result, tostring(Hits.SIZE.result), m.m_Request, tostring(Hits.SIZE.request) } },
            }
            local v = variants[replays]
            replaying = true
            local ok, err, warnings = TailCoop_CallImported(tostring(v[2]:GetAddress()), tostring(v[3]:GetAddress()),
                table.unpack(v[4]))
            while TailCoop_PollCaptured() do end  -- our own call may be captured too
            replaying = false
            U.log("HITREPLAY replay %d (%s): ok %s %s, %d import warnings, health %.0f", replays, v[1], tostring(ok),
                tostring(err), warnings or -1, e.actor.m_HealthComponent.m_fHealth)
        end
        return replays >= 4 and now - lastReplay > 3000
    end)
end

-- twincompare (solo): the dummy stays visible and its visual twin stands 160 units to its side, copying its stance
-- (quadrant idle) and every action, so screenshots show both poses side by side.
local function twincompare()
    local F = require("tc_flow")
    local A = require("tc_anim")
    local P = require("tc_presence")
    local entered, dummy, twin, st, w, t0, lastLog, lastQ = false, nil, nil, {}, nil, nil, 0, nil
    U.poll("twincompare", 16, function()
        if not entered then
            if F.currentMap and FindFirstOf("BP_Menu_Startup_C") then entered = F.enterLocal("training") end
            return false
        end
        if F.activity ~= "training" then return false end
        local pawn = U.playerController() and U.playerController().Pawn
        local e = require("tc_enemies").list()[1]
        if not (U.valid(pawn) and e) then return false end
        local now = TailCoop_Clock()
        t0 = t0 or now + 2000
        if now < t0 then return false end
        if not dummy then
            dummy, w = e.actor, A.watcher()
            local l = dummy:K2_GetActorLocation()
            twin = P.spawnCharacter(dummy:GetClass(), { x = l.X, y = l.Y, z = l.Z })
            A.makeDriven(twin)
            twin:SetActorEnableCollision(false)
            U.log("TWINCMP start")
            return false
        end
        -- Side by side as the camera sees them: offset along the camera's right.
        local l, r = dummy:K2_GetActorLocation(), dummy:K2_GetActorRotation()
        local rv = U.playerController().PlayerCameraManager:GetActorRightVector()
        A.drive(twin, st, l.X + rv.X * 170, l.Y + rv.Y * 170, l.Z, r.Yaw, now)
        local ev = w:update(dummy, now)
        if ev and ev.kind == "start" and ev.path then
            local asset = A.sequence(ev.path)
            if asset then
                A.copyAction(twin, st, asset, ev.rate, A.startTime(asset, ev.cursor, ev.start, 0, ev.rate), ev.mirror, now)
                U.log("TWINCMP action %s mirror %s", ev.path:match("[^/.]+$"), tostring(ev.mirror))
            end
        elseif ev and ev.kind == "end" then
            A.copyActionEnd(st)
        end
        local q = A.quadrant(A.animInstance(dummy))
        if q ~= lastQ then
            lastQ = q
            U.log("TWINCMP dummy stance %s", tostring(q))
        end
        A.copyLocomotion(twin, st, true, now, q)
        if now - lastLog >= 1000 then
            lastLog = now
            -- Hands in each character's own frame (forward, right): equal = same pose, right swapped = mirrored.
            local function pose(ch)
                local mesh = ch.Mesh
                st.bones = st.bones or {}
                local key = mesh:GetAddress()
                if not st.bones[key] then
                    local b = {}
                    for i = 0, mesh:GetNumBones() - 1 do
                        local fn = mesh:GetBoneName(i)
                        local n = fn:ToString():lower()
                        if n == "hand_l" then b.l = fn elseif n == "hand_r" then b.r = fn end
                    end
                    st.bones[key] = b
                end
                local b = st.bones[key]
                local al, f, rt = ch:K2_GetActorLocation(), ch:GetActorForwardVector(), ch:GetActorRightVector()
                local function rel(bone)
                    local p = mesh:GetSocketLocation(bone)
                    local dx, dy = p.X - al.X, p.Y - al.Y
                    return dx * f.X + dy * f.Y, dx * rt.X + dy * rt.Y
                end
                local lf, lr = rel(b.l)
                local rf, rr = rel(b.r)
                return string.format("L(%3.0f,%4.0f) R(%3.0f,%4.0f)", lf, lr, rf, rr)
            end
            local okD, pd = pcall(pose, dummy)
            local okT, pt = pcall(pose, twin)
            U.log("TWINCMP q %s | dummy %s | twin %s", tostring(q),
                okD and pd or tostring(pd), okT and pt or tostring(pt))
        end
        return now - t0 > 60000
    end)
end

-- bonesprobe (solo): what a fighter's pose is made of - skinned mesh components (mesh asset, master pose), bone
-- count and names - for the player and the dummy.
local function bonesprobe()
    local F = require("tc_flow")
    local entered, done = false, false
    U.poll("bonesprobe", 500, function()
        if not entered then
            if F.currentMap and FindFirstOf("BP_Menu_Startup_C") then entered = F.enterLocal("training") end
            return false
        end
        if F.activity ~= "training" then return false end
        local pawn = U.playerController() and U.playerController().Pawn
        local e = require("tc_enemies").list()[1]
        if not (U.valid(pawn) and e) then return false end
        local skinned = StaticFindObject("/Script/Engine.SkinnedMeshComponent")
        for _, who in ipairs({ { "player", pawn }, { "dummy", e.actor } }) do
            local ch = who[2]
            local comps = ch:K2_GetComponentsByClass(skinned)
            local list = {}
            local function each(c)
                local okV, ok = pcall(function() return c:IsA(skinned) end)
                if not okV then c = c:get() end
                list[#list + 1] = c
            end
            if type(comps) == "table" then for _, c in ipairs(comps) do each(c) end
            elseif comps and comps.ForEach then comps:ForEach(function(_, el) each(el) end) end
            U.log("BONES %s: %d skinned mesh components (main mesh %s)", who[1], #list, U.shortName(ch.Mesh))
            for _, c in ipairs(list) do
                local okI, info = pcall(function()
                    return string.format("%s mesh=%s bones=%d master=%s visible=%s", U.shortName(c),
                        tostring(A_path and A_path(c.SkeletalMesh) or (U.valid(c.SkeletalMesh) and c.SkeletalMesh:GetFullName():match("%s(.+)$"))),
                        c:GetNumBones(), U.shortName(c.MasterPoseComponent and c.MasterPoseComponent:Get() or nil),
                        tostring(c:IsVisible()))
                end)
                U.log("BONES   %s", okI and info or ("error " .. tostring(info)))
            end
            local mesh = ch.Mesh
            local names = {}
            for i = 0, mesh:GetNumBones() - 1 do names[#names + 1] = i .. ":" .. mesh:GetBoneName(i):ToString() end
            for i = 1, #names, 40 do
                U.log("BONES %s names %s", who[1], table.concat(names, " ", i, math.min(#names, i + 39)))
            end
        end
        return true
    end)
end

-- posesync (solo): a copy of the dummy, beside it as the camera sees them, shows the dummy's pose through the whole
-- pose path (capture -> encode -> store -> decode -> apply). Phase "master" (0-20 s): the copy's mesh follows a hidden
-- poseable; phase "direct" (20-40 s): the poseable itself is shown. Logs the distance between matching bones of the
-- dummy and the copy (each in its own actor's frame) every second.
local function posesync()
    local F = require("tc_flow")
    local A = require("tc_anim")
    local P = require("tc_presence")
    local Pose = require("tc_pose")
    local entered, dummy, twin, st, t0, lastLog, phase = false, nil, nil, {}, nil, 0, nil
    local BONES = { "hand_l", "hand_r", "foot_l", "foot_r", "head", "pelvis", "index_03_l", "lowerarm_r" }
    local names = {}
    local err = { max = 0, sum = 0, n = 0 }
    U.poll("posesync", 10, function()
        if not entered then
            if F.currentMap and FindFirstOf("BP_Menu_Startup_C") then entered = F.enterLocal("training") end
            return false
        end
        if F.activity ~= "training" then return false end
        local pawn = U.playerController() and U.playerController().Pawn
        local e = require("tc_enemies").list()[1]
        if not (U.valid(pawn) and e) then return false end
        local now = TailCoop_Clock()
        t0 = t0 or now + 2000
        if now < t0 then return false end
        if not dummy then
            dummy = e.actor
            local l = dummy:K2_GetActorLocation()
            twin = P.spawnCharacter(dummy:GetClass(), { x = l.X, y = l.Y, z = l.Z })
            A.makeDriven(twin)
            twin:SetActorEnableCollision(false)
            for i = 0, dummy.Mesh:GetNumBones() - 1 do
                local fn = dummy.Mesh:GetBoneName(i)
                names[fn:ToString()] = fn
            end
            U.log("POSESYNC start")
            return false
        end
        local t = (now - t0) / 1000
        local newPhase = t < 20 and "master" or (t < 40 and "direct" or "done")
        if newPhase ~= phase then
            if phase then Pose.detach(twin, st) end
            phase = newPhase
            U.log("POSESYNC phase %s", phase)
            if phase == "done" then
                U.log("POSESYNC %s", Pose.stats())
                return true
            end
            Pose.attach(twin, st, phase)
            err = { max = 0, sum = 0, n = 0 }
        end
        local l, r = dummy:K2_GetActorLocation(), dummy:K2_GetActorRotation()
        local rv = U.playerController().PlayerCameraManager:GetActorRightVector()
        A.drive(twin, st, l.X + rv.X * 170, l.Y + rv.Y * 170, l.Z, r.Yaw, now)
        local bytes, e1 = Pose.store(dummy, "dummy", now)
        if not bytes and not st.storeErr then
            st.storeErr = true
            U.log("POSESYNC capture failed: %s", tostring(e1))
        end
        local driven = Pose.apply(twin, st, "dummy", now)
        if not driven then A.copyLocomotion(twin, st, true, now, A.quadrant(A.animInstance(dummy))) end
        -- Bone error: each bone relative to its actor, in the actor's frame.
        local shown = phase == "direct" and st.poseable or twin.Mesh
        local function relPos(ch, comp, bone)
            local p = comp:GetSocketLocation(names[bone])
            local al, f, rt = ch:K2_GetActorLocation(), ch:GetActorForwardVector(), ch:GetActorRightVector()
            local dx, dy, dz = p.X - al.X, p.Y - al.Y, p.Z - al.Z
            return dx * f.X + dy * f.Y, dx * rt.X + dy * rt.Y, dz
        end
        local okE, frameMax = pcall(function()
            local m = 0
            for _, b in ipairs(BONES) do
                local ax, ay, az = relPos(dummy, dummy.Mesh, b)
                local bx, by, bz = relPos(twin, shown, b)
                m = math.max(m, math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2))
            end
            return m
        end)
        if okE then
            err.max, err.sum, err.n = math.max(err.max, frameMax), err.sum + frameMax, err.n + 1
        end
        if now - lastLog >= 1000 then
            lastLog = now
            U.log("POSESYNC %s t=%.0f driven %s | bone error avg %.1f cm max %.1f cm (%d frames)%s", phase, t,
                tostring(driven), err.n > 0 and err.sum / err.n or -1, err.max, err.n,
                okE and "" or (" | error " .. tostring(frameMax)))
            err = { max = 0, sum = 0, n = 0 }
        end
        return false
    end)
end

-- reset (co-op): the host presses "Reset Situation" (BP_TrainingManager:ResetTrainingRoom) 20 s into the session.
local function resetTest()
    local F = require("tc_flow")
    local startAt, done = nil, false
    U.poll("reset test", 500, function()
        if U.config.role ~= "host" or F.activity ~= "training" then return false end
        local now = TailCoop_Clock()
        startAt = startAt or now
        if now - startAt < 20000 then return false end
        local tm
        for _, m in ipairs(FindAllOf("BP_TrainingManager_C") or {}) do
            if U.valid(m) and not m:GetFullName():find("Default__", 1, true) then tm = m end
        end
        if not tm then
            U.log("RESET: no training manager")
            return true
        end
        local ok, err = pcall(function() tm:ResetTrainingRoom() end)
        U.log("RESET: host reset the situation (%s)", ok and "ok" or tostring(err))
        return true
    end)
end

-- geartest (co-op): the host picks up a training-room weapon at +20 s (BPF_PickUpObject) and drops it at +45 s.
local function gearTest()
    local F = require("tc_flow")
    local startAt, picked, dropped = nil, false, false
    U.poll("gear test", 500, function()
        if F.activity ~= "training" then return false end
        local now = TailCoop_Clock()
        startAt = startAt or now
        if U.config.role == "join" then
            -- Joiner: where the host's weapon sits on our copy of the host, every 3 s while held.
            if now - startAt > 24000 and now - startAt < 44000 and now - (T.gearDbgAt or 0) > 3000 then
                T.gearDbgAt = now
                local P = require("tc_presence")
                local actor, st = P.puppetActor(), P.puppetState()
                if U.valid(actor) and st then U.log("GEAR joiner: %s", require("tc_gear").debug(st, actor)) end
            end
            return now - startAt > 50000
        end
        local pawn = U.playerController() and U.playerController().Pawn
        if not U.valid(pawn) then return false end
        if not picked and now - startAt > 20000 then
            picked = true
            local weapon
            for _, s in ipairs(FindAllOf("BP_Training_WeaponSpawner_C") or {}) do
                if U.valid(s) and U.valid(s.WeaponSpawned) and not weapon then weapon = s.WeaponSpawned end
            end
            if not weapon then
                U.log("GEAR: no weapon in the room")
                return true
            end
            -- Close enough to pick it up.
            local l = weapon:K2_GetActorLocation()
            T.gearHome = pawn:K2_GetActorLocation()
            pawn:K2_SetActorLocation({ X = l.X + 60, Y = l.Y, Z = pawn:K2_GetActorLocation().Z }, false, {}, true)
            local ok, err = pcall(function() pawn:BPF_PickUpObject(weapon, false) end)
            U.log("GEAR: host picks up %s (%s)", U.shortName(weapon), ok and "ok" or tostring(err))
        elseif picked and not T.gearBack and now - startAt > 23000 and T.gearHome then
            -- Back next to the partner, so their camera shows the weapon up close.
            T.gearBack = true
            pawn:K2_SetActorLocation(T.gearHome, false, {}, true)
            U.log("GEAR: host walks back with the weapon")
        elseif picked and not T.gearProbed and now - startAt > 25000 then
            T.gearProbed = true
            for _, w in ipairs(FindAllOf("BaseWeapon") or {}) do
                local function q(label, fn)
                    local ok, v = pcall(fn)
                    return label .. "=" .. (ok and tostring(v) or ("err " .. tostring(v):sub(-80)))
                end
                U.log("GEAR probe %s | %s | %s | %s | %s", U.shortName(w),
                    q("parentActor", function() return U.shortName(w:GetAttachParentActor()) end),
                    q("socket", function() return w:GetAttachParentSocketName():ToString() end),
                    q("rootParent", function() return U.shortName(w:K2_GetRootComponent():GetAttachParent()) end),
                    q("owner", function() return U.shortName(w:GetOwner()) end))
            end
            local okW, eq = pcall(function() return pawn:BPF_GetPickedUpWeapon() end)
            U.log("GEAR probe pawn %s picked-up weapon %s", U.shortName(pawn), okW and U.shortName(eq) or tostring(eq))
        elseif picked and not dropped and now - startAt > 45000 then
            dropped = true
            local ok, err = pcall(function() pawn:BPF_GetPickedUpWeapon():BPF_DropWeapon(0) end)
            U.log("GEAR: host drops the weapon (%s)", ok and "ok" or tostring(err))
            return true
        end
        return false
    end)
end

-- changetype (co-op): the host changes the enemy type (BP_TrainingManager:ChangeArchetypes, 2 enemies of archetype 1)
-- 20 s into the session.
local function changeTypeTest()
    local F = require("tc_flow")
    local startAt = nil
    U.poll("changetype test", 500, function()
        if U.config.role ~= "host" or F.activity ~= "training" then return false end
        local now = TailCoop_Clock()
        startAt = startAt or now
        if now - startAt < 20000 then return false end
        local tm
        for _, m in ipairs(FindAllOf("BP_TrainingManager_C") or {}) do
            if U.valid(m) and not m:GetFullName():find("Default__", 1, true) then tm = m end
        end
        local ok, err = pcall(function()
            tm:ChangeArchetypes({ Archetype_19_47788A9644DD1B1E37918F9A65EA4E1B = 1,
                                  Version_20_AADD7E0943207135D0DCBCB65DB234FD = 0,
                                  Number_18_87140A9843C0BD65E3FEC68CF6B25DA9 = 2 })
        end)
        U.log("CHANGETYPE: host changed the enemy type (%s)", ok and "ok" or tostring(err))
        return true
    end)
end

-- aggrotest (co-op, with approach for the joiner): the host makes the dummy aggressive at +15 s
-- (BP_TrainingManager:SetAIBehaviour) and walks 700 units away at +22 s, so the joiner is the nearer player; back at
-- +45 s, away again at +70 s and back at +95 s (control of the dummy goes back and forth: twins are reused).
local function aggroTest()
    local F = require("tc_flow")
    local startAt, active, away = nil, false, false
    local cycle = 0
    U.poll("aggro test", 500, function()
        if U.config.role ~= "host" or F.activity ~= "training" then return false end
        local now = TailCoop_Clock()
        startAt = startAt or now
        local pawn = U.playerController() and U.playerController().Pawn
        local e = require("tc_enemies").list()[1]
        if not (U.valid(pawn) and e) then return false end
        if not active and now - startAt > 15000 then
            active = true
            local tm
            for _, m in ipairs(FindAllOf("BP_TrainingManager_C") or {}) do
                if U.valid(m) and not m:GetFullName():find("Default__", 1, true) then tm = m end
            end
            -- The room's own switch (key 1), so tc_training mirrors it to the partner's room as well.
            local ok, err = pcall(function() if tm.IsAIPassive then tm:AIChangeBehaviour() end end)
            U.log("AGGRO: dummy set aggressive (%s)", ok and "ok" or tostring(err))
        elseif active and not away and cycle < 2 and now - startAt > 22000 + cycle * 48000 then
            away = true
            -- Always the same spot (from where the host first stood): from the dummy's side it'd be outside the room.
            local l = T.aggroHome or pawn:K2_GetActorLocation()
            T.aggroHome = l
            pawn:K2_SetActorLocation({ X = l.X + 700, Y = l.Y + 300, Z = l.Z }, false, {}, true)
            U.log("AGGRO: host walks away")
        elseif away and now - startAt > 45000 + cycle * 50000 then
            -- Back in front of the dummy (wherever this game shows it), facing it, to hit it.
            away, cycle = false, cycle + 1
            T.aggroBack = true
            local l, fwd = e.actor:K2_GetActorLocation(), e.actor:GetActorForwardVector()
            local at = { X = l.X + fwd.X * 120, Y = l.Y + fwd.Y * 120, Z = pawn:K2_GetActorLocation().Z }
            pawn:K2_SetActorLocationAndRotation(at, { Pitch = 0, Yaw = math.deg(math.atan(-fwd.Y, -fwd.X)), Roll = 0 },
                false, {}, true)
            pcall(function() U.playerController():SetControlRotation({ Pitch = -10, Yaw = math.deg(math.atan(-fwd.Y, -fwd.X)), Roll = 0 }) end)
            U.log("AGGRO: host comes back to the dummy")
        end
        return now - startAt > 150000
    end)
end

-- friendly / friendlyoff / friendlyfront (co-op): factions of everyone here and Sifu's faction table
-- (ThePlainesGameInstance:BPF_CanTargetFaction), then the joiner is placed by the partner's character (see below) while
-- the lab script attacks (Lab\FriendlyTest.ps1): tc_aggro counts our hits that land on the partner's character.
local function friendlyTest()
    local F = require("tc_flow")
    local startAt, probed = nil, false
    U.poll("friendly test", 100, function()
        if F.activity ~= "training" then return false end
        local now = TailCoop_Clock()
        startAt = startAt or now
        local pawn = U.playerController() and U.playerController().Pawn
        local partner = require("tc_presence").puppetActor()
        if not (U.valid(pawn) and U.valid(partner)) then return false end
        if not probed and now - startAt > 8000 then
            probed = true
            local function faction(a)
                local ok, f = pcall(function() return a.m_eFaction end)
                return ok and tostring(f) or ("? " .. tostring(f))
            end
            U.log("FRIENDLY: factions: me %s, partner's character %s", faction(pawn), faction(partner))
            for _, e in ipairs(require("tc_enemies").list()) do
                U.log("FRIENDLY: faction of %s: %s", e.id, faction(e.actor))
            end
            local gi = FindFirstOf("ThePlainesGameInstance")
            local rows = {}
            for a = 0, 5 do
                local row = {}
                for b = 0, 5 do
                    local ok, can = pcall(function() return gi:BPF_CanTargetFaction(a, b) end)
                    row[#row + 1] = ok and (can and "1" or "0") or "?"
                end
                rows[#rows + 1] = table.concat(row)
            end
            U.log("FRIENDLY: can target (row = attacker faction 0..5, column = target): %s", table.concat(rows, " "))
        end
        -- The joiner stands 110 cm from the partner's character, beside it: the partner is on our right and we face
        -- 90 degrees away from it (placed once). Attacks that lock onto the partner turn us towards it: logged every
        -- second as the angle between where we face and where the partner is (90 = untouched, ~0 = turned to it).
        -- "friendlyfront": the partner's character in the way instead - right between us and the dummy, 110 cm in
        -- front of us, facing it - put back every 3 s (our attacks on the dummy go through the partner).
        local front = U.config.test == "friendlyfront"
        if U.config.role == "join" and now - startAt > 10000 and now - startAt < 50000
            and (not T.friendlyPlaced or (front and now - T.friendlyPlaced > 3000)) then
            T.friendlyPlaced = now
            local l = partner:K2_GetActorLocation()
            local me = pawn:K2_GetActorLocation()
            local e = require("tc_enemies").list()[1]
            if front and e and U.valid(e.actor) then me = e.actor:K2_GetActorLocation() end
            local dx, dy = me.X - l.X, me.Y - l.Y
            if front then dx, dy = -dx, -dy end  -- the side away from the dummy
            me = pawn:K2_GetActorLocation()
            local d = math.max(1, math.sqrt(dx * dx + dy * dy))
            local at = { X = l.X + dx / d * 110, Y = l.Y + dy / d * 110, Z = me.Z }
            local toPartner = math.deg(math.atan(-dy, -dx))
            local yaw = front and toPartner or (toPartner + 90)
            pawn:K2_SetActorLocationAndRotation(at, { Pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
            pcall(function() U.playerController():SetControlRotation({ Pitch = -10, Yaw = yaw, Roll = 0 }) end)
        end
        if U.config.role == "join" and T.friendlyPlaced and now - (T.friendlyLogAt or 0) >= 1000 and now - startAt < 50000 then
            T.friendlyLogAt = now
            local l, me, fwd = partner:K2_GetActorLocation(), pawn:K2_GetActorLocation(), pawn:GetActorForwardVector()
            local dx, dy = l.X - me.X, l.Y - me.Y
            local d = math.max(1, math.sqrt(dx * dx + dy * dy))
            local angle = math.deg(math.acos(math.max(-1, math.min(1, (fwd.X * dx + fwd.Y * dy) / d))))
            U.log("FRIENDLY: angle to the partner %.0f deg, distance %.0f", angle, d)
        end
        if now - startAt > 75000 then
            U.log("FRIENDLY: done - %s", require("tc_aggro").friendlyReport())
            return true
        end
        return false
    end)
end

-- trainprobe (solo): which BP_TrainingManager functions run when the training HUD's keys are pressed (the lab
-- script presses 1, 2, 3 + Enter meanwhile).
local function trainProbe()
    local F = require("tc_flow")
    local entered, hooked = false, false
    local NAMES = { "ResetTrainingRoom", "AIChangeBehaviour", "ChangeArchetypes", "StartArchetypeChange",
        "ApplyArchetype", "SetAIBehaviour", "CleanSpawnedAIs", "Spawn AIs", "FinishedSpawn", "SetCurrentTrainingEvent",
        "SetSpawnAIAsPassive", "ReturnToTrainingModeSelection", "LeaveTrainingRoom" }
    U.poll("trainprobe", 500, function()
        if not entered then
            if F.currentMap and FindFirstOf("BP_Menu_Startup_C") then entered = F.enterLocal("training") end
            return false
        end
        if F.activity ~= "training" or hooked then return hooked end
        hooked = true
        for _, n in ipairs(NAMES) do
            local path = "/Game/Blueprints/Gameplay/TrainingRoom/BP_TrainingManager.BP_TrainingManager_C:" .. n
            local tm
            for _, m in ipairs(FindAllOf("BP_TrainingManager_C") or {}) do
                if U.valid(m) and not m:GetFullName():find("Default__", 1, true) then tm = m end
            end
            if tm then path = tm:GetClass():GetFullName():match("%s(.+)$") .. ":" .. n end
            local ok, err = pcall(RegisterHook, path, function(ctx, a, b)
                local extra = ""
                pcall(function()
                    local s = a:get()
                    extra = string.format(" archetype %s version %s number %s", tostring(s.Archetype_19_47788A9644DD1B1E37918F9A65EA4E1B),
                        tostring(s.Version_20_AADD7E0943207135D0DCBCB65DB234FD), tostring(s.Number_18_87140A9843C0BD65E3FEC68CF6B25DA9))
                end)
                U.log("TRAINPROBE called %s%s", n, extra)
            end)
            U.log("TRAINPROBE hook %s: %s", n, ok and "ok" or tostring(err))
        end
        return true
    end)
end

-- arenaprobe (both lab games, session up, no arena sync): each game enters the Arena scene (session start), travels to
-- challenge (batch, challenge) from Lua, presses Start, then logs once a second what's there - enemies (id, class,
-- place, meshes when first seen), the objective (score, stars, complete), the wave director - and which arena
-- functions run (tc_arena probe hooks). At 50 s each game kills one enemy, the host with ServerSuicide, the joiner by
-- setting its health to 0, to see which one the wave director counts. Compare the two logs.
local function arenaProbe()
    local F = require("tc_flow")
    local AR = require("tc_arena")
    local E = require("tc_enemies")
    local batch, challenge = tonumber(U.config.arenabatch or "") or 0, tonumber(U.config.arenachallenge or "") or 0
    AR.probeHooks()
    local phase, at, startAt, seen, killed = "scene", 0, nil, {}, false
    U.poll("arenaprobe", 1000, function()
        local now = TailCoop_Clock()
        if phase == "scene" then
            if F.currentMap == "ArenaMode_Menu" and not F.entering() then
                phase, at = "list", now
            end
            return false
        end
        if phase == "list" then
            if now - at < 4000 then return false end
            local ok, err = AR.travel(batch, challenge)
            U.log("ARENAPROBE travel(%d, %d): %s", batch, challenge, ok and "ok" or tostring(err))
            phase, at = "travel", now
            return not ok
        end
        if phase == "travel" then
            if not AR.titleMenu() then
                if now - at > 90000 then
                    U.log("ARENAPROBE: no challenge title screen after 90 s (map %s)", tostring(F.currentMap))
                    return true
                end
                return false
            end
            local b, c, name, tag = AR.current()
            U.log("ARENAPROBE title screen in %s: batch %s challenge %s = %s (%s)", tostring(F.currentMap), tostring(b),
                tostring(c), tostring(name), tostring(tag))
            phase, at = "title", now
            return false
        end
        if phase == "title" then
            if now - at < 3000 then return false end
            U.log("ARENAPROBE pressing Start (clock %d): %s", now, tostring(AR.pressStart()))
            phase, startAt = "play", now
            return false
        end
        -- play: what's there, once a second
        local t = (now - startAt) / 1000
        local parts = {}
        for _, e in ipairs(E.list()) do
            local c = e.actor
            local ok, line = pcall(function()
                local l = c:K2_GetActorLocation()
                local hp = c.m_HealthComponent.m_fHealth
                return string.format("%s %s (%.0f %.0f) hp %.0f", e.id, c:GetClass():GetFName():ToString(), l.X, l.Y, hp)
            end)
            parts[#parts + 1] = ok and line or (e.id .. " ?")
            if not seen[e.id] then
                seen[e.id] = true
                local meshes = {}
                pcall(function()
                    for _, m in ipairs(c:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SkeletalMeshComponent"))) do
                        local okM, p = pcall(function() return m.SkeletalMesh:GetFName():ToString() end)
                        meshes[#meshes + 1] = okM and p or "?"
                    end
                end)
                U.log("ARENAPROBE new enemy %s at %.1f s, meshes: %s", e.id, t, table.concat(meshes, ", "))
            end
        end
        if not seen.detail then
            -- What tells a pooled (waiting, at the origin) character from an active one.
            local pooled, active
            for _, e in ipairs(E.list()) do
                if e.id:find("@0,0", 1, true) then pooled = pooled or e else active = active or e end
            end
            for label, e in pairs({ pooled = pooled, active = active }) do
                local ok, d = pcall(function()
                    local c = e.actor
                    local l = c:K2_GetActorLocation()
                    return string.format("%s: hidden %s tick %s collision %s z %.0f controller %s spawner %s brain %s", e.id,
                        tostring(c.bHidden), tostring(c:IsActorTickEnabled()), tostring(c:GetActorEnableCollision()), l.Z,
                        U.shortName(c.Controller), U.shortName(c.m_AIComponent.m_Spawner),
                        tostring(c.Controller.BrainComponent and c.Controller.BrainComponent:IsRunning()))
                end)
                U.log("ARENAPROBE %s %s", label, ok and d or tostring(d))
            end
            seen.detail = true
        end
        local okP, paused = pcall(function() return require("UEHelpers").GetGameplayStatics():IsGamePaused(U.world()) end)
        local o, dir = AR.objective(), AR.live("AIWaveRefillDirector")
        local okO, os_ = pcall(function()
            return string.format("%s score %d stars %d complete %s", o:GetClass():GetFName():ToString(), o.m_iScore,
                o.m_iStarCount, tostring(o.m_bIsArenaObjectiveComplete))
        end)
        local okD, ds = pcall(function()
            return string.format("wave in progress %s, %d left", tostring(dir:BPF_IsWaveInProgress()),
                dir:BPF_GetAIRemainingInCurrentWave())
        end)
        local activeParts = {}
        for _, p in ipairs(parts) do
            if not p:find("@0,0", 1, true) then activeParts[#activeParts + 1] = p end
        end
        U.log("ARENAPROBE t=%.0f paused %s | objective %s | director %s | enemies %d, active: %s", t,
            okP and tostring(paused) or "?", okO and os_ or "-", okD and ds or "-", #parts, table.concat(activeParts, "; "))
        if not killed and t >= 40 then
            killed = true
            local first
            for _, e in ipairs(E.list()) do
                if not first and not e.id:find("@0,0", 1, true) then first = e end
            end
            if first then
                local how = U.config.role == "host" and "ServerSuicide" or "health 0"
                local ok, err = pcall(function()
                    if how == "ServerSuicide" then first.actor:ServerSuicide(false)
                    else first.actor.m_HealthComponent:BPF_ServerSetHealth(0) end
                end)
                U.log("ARENAPROBE killed %s with %s: %s", first.id, how, ok and "ok" or tostring(err))
            end
        end
        if t >= 110 then
            U.log("ARENAPROBE: done")
            return true
        end
        return false
    end)
end

-- arenago (session, mode arena): the picker (host, or the joiner with "arenapicker = join") picks challenge
-- (arenabatch, arenachallenge) through the challenge list's own TravelToArena and presses Start on the title screen
-- like the player does; the partner must follow both. Then logs both players and the partner's copy for 30 s.
local function arenaGo()
    local F = require("tc_flow")
    local AR = require("tc_arena")
    local P = require("tc_presence")
    local batch, challenge = tonumber(U.config.arenabatch or "") or 0, tonumber(U.config.arenachallenge or "") or 0
    local picker = (U.config.arenapicker or "host") == U.config.role
    local phase, at, startAt = "list", nil, nil
    U.poll("arenago", 500, function()
        local now = TailCoop_Clock()
        if phase == "list" then
            if F.entered ~= "arena" or F.currentMap ~= "ArenaMode_Menu" then return false end
            at = at or now
            if not picker then phase = "title"; return false end
            if now - at < 4000 then return false end
            local list = AR.live("BP_Menu_ArenaSelection_C")
            local ok, err = pcall(function()
                AR.helper():BPF_SetCurrentArena(batch, challenge)
                list:TravelToArena()
            end)
            U.log("ARENAGO: picked batch %d challenge %d in the list: %s", batch, challenge, ok and "ok" or tostring(err))
            phase = "title"
            return not ok
        end
        if phase == "title" then
            if not AR.titleMenu() then return false end
            if not picker then phase = "wait"; return false end
            phase = "press"
            at = now
            return false
        end
        if phase == "press" then
            if now - at < 3000 then return false end
            U.log("ARENAGO: pressing Start on the title screen (clock %d): %s", now, tostring(AR.pressStart()))
            phase = "wait"
            return false
        end
        if phase == "wait" then
            if F.activity ~= "arena" then return false end
            phase, startAt, at = "play", now, nil
            U.log("ARENAGO: started in %s (clock %d)", tostring(F.currentMap), now)
            return false
        end
        local t = (now - startAt) / 1000
        if not at or now >= at then
            at = now + 5000
            local pc = U.playerController()
            local me = pc and pc.Pawn
            local puppet = P.puppetActor()
            local function where(a)
                local ok, s = pcall(function()
                    local l = a:K2_GetActorLocation()
                    return string.format("(%.0f %.0f %.0f)", l.X, l.Y, l.Z)
                end)
                return ok and s or "-"
            end
            local o, dir = AR.objective(), AR.live("AIWaveRefillDirector")
            local okO, os_ = pcall(function()
                return string.format("score %d stars %d complete %s", o.m_iScore, o.m_iStarCount,
                    tostring(o.m_bIsArenaObjectiveComplete))
            end)
            local okD, ds = pcall(function()
                return string.format("wave %s, %d left", dir:BPF_IsWaveInProgress() and "on" or "off",
                    dir:BPF_GetAIRemainingInCurrentWave())
            end)
            local hp = "?"
            pcall(function() hp = string.format("%.0f", me.m_HealthComponent.m_fHealth) end)
            U.log("ARENAGO t=%.0f me %s hp %s partner's copy %s enemies %d | %s | %s", t, where(me), hp,
                U.valid(puppet) and where(puppet) or "none", #require("tc_enemies").list(), okO and os_ or "-",
                okD and ds or "-")
        end
        if t >= (tonumber(U.config.arenaseconds or "") or 30) then
            U.log("ARENAGO: done")
            return true
        end
        return false
    end)
end

-- arenakill (with arenago): from 15 s after Start, every 5 s each game kills one enemy it runs (ServerSuicide, as a
-- player's finishing blow would end it there): deaths in either game must reach the other one, and the host's wave
-- director must count all of them and start the next waves (whose enemies the joiner must get too).
local function arenaKill()
    local F = require("tc_flow")
    local E = require("tc_enemies")
    local AR = require("tc_arena")
    local startAt, nextKill, kills = nil, nil, 0
    local lastWave
    U.poll("arenakill", 500, function()
        if F.activity ~= "arena" then
            startAt = nil
            return false
        end
        local now = TailCoop_Clock()
        startAt = startAt or now
        nextKill = nextKill or startAt + 15000
        local dir = AR.live("AIWaveRefillDirector")
        local okD, wave = pcall(function()
            return string.format("%s/%d left", dir:BPF_IsWaveInProgress() and "on" or "off",
                dir:BPF_GetAIRemainingInCurrentWave())
        end)
        wave = okD and wave or "-"
        if wave ~= lastWave then
            lastWave = wave
            U.log("ARENAKILL director wave %s at t=%.0f", wave, (now - startAt) / 1000)
        end
        if now < nextKill then return false end
        nextKill = now + (tonumber(U.config.killevery or "") or 5000)
        for _, e in ipairs(E.list()) do
            local okH, h = pcall(function() return e.actor.m_HealthComponent.m_fHealth end)
            if E.mine(e.id) and not E.isDead(e.id) and not e.wrongKind and not e.dormant and okH and h > 0 then
                local ok, err = pcall(function() e.actor:ServerSuicide(false) end)
                kills = kills + 1
                U.log("ARENAKILL killed our %s (%s), %d so far", e.id, ok and "ok" or tostring(err), kills)
                break
            end
        end
        return false
    end)
end

-- arenaretry (with arenago + arenakill): the host clears the challenge, presses NEXT on the result screen and Retry,
-- Start again, clears it again, then Back to the challenge list. The joiner must follow every step by itself.
local function arenaRetry()
    local F = require("tc_flow")
    local AR = require("tc_arena")
    if U.config.role ~= "host" then return end
    local cycle, phase, at = 1, "play", nil
    U.poll("arenaretry", 500, function()
        local now = TailCoop_Clock()
        if phase == "play" then
            local o = AR.objective()
            local ok, done = pcall(function() return o.m_bIsArenaObjectiveComplete end)
            if F.activity == "arena" and ok and done then
                phase, at = "outro", now + 14000
                U.log("ARENARETRY cycle %d complete", cycle)
            end
            return false
        end
        if phase == "outro" then
            if now < at then return false end
            local outro = AR.live("BP_Arena_Outro_C")
            local ok = outro and pcall(function() outro:BPE_OnActionButtonPressed() end)
            U.log("ARENARETRY NEXT on the result screen: %s", ok and "ok" or "no result screen")
            phase, at = "after", now + 12000
            return false
        end
        if phase == "after" then
            if now < at then return false end
            local after = AR.live("BP_Arena_After_Outro_C")
            if not after then
                U.log("ARENARETRY: no after-result screen")
                return true
            end
            -- (Button handlers: (button, with mouse).)
            local fn = cycle == 1 and "RetryButtonPressed" or "ReturnToChallengeButtonPressed"
            if cycle == 1 then phase, cycle, at = "title", 2, nil else phase = "list" end
            -- Its buttons (the handler wants the one pressed): listed once, the matching one passed.
            local afterName = after:GetFName():ToString()
            local buttons, pick = {}, nil
            for _, b in ipairs(FindAllOf("ButtonUserWidget") or {}) do
                local okN, full = pcall(function() return b:GetFullName() end)
                if okN and full:find(afterName, 1, true) then
                    local n = b:GetFName():ToString()
                    buttons[#buttons + 1] = n
                    local want = cycle == 2 and "[Rr]etry" or "[Cc]hall"
                    if n:find(want) or (cycle == 2 and n:find("[Aa]gain")) then pick = b end
                end
            end
            U.log("ARENARETRY result screen buttons: %s -> %s", table.concat(buttons, ", "), pick and pick:GetFName():ToString() or "none")
            local ok, err = pcall(function() after[fn](after, pick, false) end)
            U.log("ARENARETRY pressing %s: %s", fn, ok and "ok" or tostring(err))
            if not ok then return true end
            return false
        end
        if phase == "title" then
            if not AR.titleMenu() then return false end
            at = at or now + 3000
            if now < at then return false end
            U.log("ARENARETRY pressing Start (cycle %d): %s", cycle, tostring(AR.pressStart()))
            phase, at = "play", nil
            return false
        end
        if phase == "list" and F.currentMap == "ArenaMode_Menu" then
            U.log("ARENARETRY: done, back in the Arena scene")
            return true
        end
        return false
    end)
end

-- arenacrowd (with arenago): both players stay near the start and let the fight come to them (kept alive). Every
-- 200 ms each game measures its screen: enemies overlapping another (closer than 60 cm), enemies in an attack at once
-- per player (from the actions both games report), attack tickets held by the enemies running here per target, and
-- tickets still held by hidden copies (the partner runs them). A summary every 5 s ("CROWD"), action paths seen once.
local function isAttackPath(p) return require("tc_turns").isAttackPath(p) end

local function arenaCrowd()
    local F = require("tc_flow")
    local E = require("tc_enemies")
    local P = require("tc_presence")
    local S = require("tc_session")
    local helpers
    local paths, nPaths = {}, 0
    local w, startAt
    local function window()
        return { n = 0, overlap = 0, overlapMax = 0, close = 0, near = { me = 0, partner = 0 },
            atk = { me = { 0, 0, 0 }, partner = { 0, 0, 0 }, both = { 0, 0, 0 } }, tick = { me = 0, partner = 0, max = 0 },
            stale = 0, roles = { 0, 0, 0, 0 }, sifu = { me = 0, partner = 0 }, enemies = 0, fought = { me = 0, partner = 0 } }
    end
    U.poll("arenacrowd", 200, function()
        if F.activity ~= "arena" then
            w, startAt = nil, nil
            return false
        end
        local now = TailCoop_Clock()
        startAt = startAt or now
        w = w or window()
        local pc = U.playerController()
        local me = pc and U.valid(pc.Pawn) and pc.Pawn or nil
        local partner = P.puppetActor()
        partner = U.valid(partner) and partner or nil
        if not me then return false end
        -- Kept alive: the fight goes on for the whole measurement.
        pcall(function()
            local hc = me.m_HealthComponent
            if hc.m_fHealth < hc.m_fMaxHealth * 0.6 then hc:BPF_ServerSetHealth(hc.m_fMaxHealth) end
        end)
        local meAddr, partnerAddr = me:GetAddress(), partner and partner:GetAddress()
        local shown = E.shown()
        w.n = w.n + 1
        w.enemies = w.enemies + #shown
        -- Overlaps on this screen.
        local overlaps, close = 0, 0
        for i = 1, #shown do
            for j = i + 1, #shown do
                local d = math.sqrt((shown[i].x - shown[j].x) ^ 2 + (shown[i].y - shown[j].y) ^ 2)
                if d < 60 then overlaps = overlaps + 1 end
                if d < 100 then close = close + 1 end
            end
        end
        w.overlap, w.close = w.overlap + overlaps, w.close + close
        w.overlapMax = math.max(w.overlapMax, overlaps)
        local function at(a)
            local ok, l = pcall(function() return a:K2_GetActorLocation() end)
            return ok and l or nil
        end
        local lm, lp = at(me), partner and at(partner)
        -- Attacks at once per player; tickets of the enemies running here.
        local atk = { me = 0, partner = 0 }
        local tick = { me = 0, partner = 0 }
        for _, s in ipairs(shown) do
            if lm and math.sqrt((s.x - lm.X) ^ 2 + (s.y - lm.Y) ^ 2) < 250 then w.near.me = w.near.me + 1 end
            if lp and math.sqrt((s.x - lp.X) ^ 2 + (s.y - lp.Y) ^ 2) < 250 then w.near.partner = w.near.partner + 1 end
            local a = E.actionNow(s.id)
            if a and a.path and not paths[a.path] and nPaths < 60 then
                paths[a.path], nPaths = true, nPaths + 1
                U.log("CROWD path %s %s", isAttackPath(a.path) and "ATTACK" or "other ", a.path)
            end
            local who
            if s.mine then
                pcall(function()
                    local ai = s.actor.m_AIComponent
                    local en = ai:BPF_GetEnemy()
                    local ea = U.valid(en) and en:GetAddress()
                    who = ea == meAddr and "me" or (ea and ea == partnerAddr and "partner") or nil
                    local role = ai:BPF_GetCurrentCombatRole()
                    if role then w.roles[role + 1] = (w.roles[role + 1] or 0) + 1 end
                    if ai:BPF_HasAttackTicket() and who then tick[who] = tick[who] + 1 end
                end)
            else
                local t = E.targetOf(s.id) or E.ownerOf(s.id)
                who = t == S.role and "me" or "partner"
                pcall(function()
                    if s.actor.m_AIComponent:BPF_HasAttackTicket() then w.stale = w.stale + 1 end
                end)
            end
            if who and a and isAttackPath(a.path) and now - a.at < 1500 then atk[who] = atk[who] + 1 end
            if who then w.fought[who] = w.fought[who] + 1 end
        end
        do
            local k = math.min(atk.me + atk.partner, 2) + 1
            w.atk.both[k] = w.atk.both[k] + 1
        end
        for _, who in ipairs({ "me", "partner" }) do
            local k = math.min(atk[who], 2) + 1
            w.atk[who][k] = w.atk[who][k] + 1
            w.tick[who] = w.tick[who] + tick[who]
            w.tick.max = math.max(w.tick.max, tick[who])
        end
        helpers = U.valid(helpers) and helpers or StaticFindObject("/Script/Sifu.Default__AIHelpers")
        pcall(function()
            w.sifu.me = math.max(w.sifu.me, helpers:BPF_GetCurrentNumberOfAIAttackers(me))
            if partner then w.sifu.partner = math.max(w.sifu.partner, helpers:BPF_GetCurrentNumberOfAIAttackers(partner)) end
        end)
        if w.n >= 25 then
            local function pct(t, k) return 100 * t[k] / w.n end
            U.log("CROWD t=%.0f %s: enemies shown %.1f | overlapping pairs avg %.2f max %d, within 1 m avg %.2f | near me %.1f, "
                .. "near partner %.1f | attacking me at once 0/1/2+: %.0f/%.0f/%.0f%% | attacking partner 0/1/2+: %.0f/%.0f/%.0f%% "
                .. "| tickets here on me avg %.2f, on partner %.2f, max %d | Sifu attackers max me %d partner %d | stale "
                .. "tickets on hidden copies %d | roles none/direct/indirect/non %d/%d/%d/%d | both players together "
                .. "0/1/2+: %.0f/%.0f/%.0f%% | fighting me %.1f, partner %.1f | %s",
                (now - startAt) / 1000, S.role, w.enemies / w.n, w.overlap / w.n, w.overlapMax, w.close / w.n,
                w.near.me / w.n, w.near.partner / w.n, pct(w.atk.me, 1), pct(w.atk.me, 2), pct(w.atk.me, 3),
                pct(w.atk.partner, 1), pct(w.atk.partner, 2), pct(w.atk.partner, 3), w.tick.me / w.n,
                w.tick.partner / w.n, w.tick.max, w.sifu.me, w.sifu.partner, w.stale, w.roles[1], w.roles[2], w.roles[3],
                w.roles[4], pct(w.atk.both, 1), pct(w.atk.both, 2), pct(w.atk.both, 3), w.fought.me / w.n,
                w.fought.partner / w.n, require("tc_turns").stats())
            w = window()
        end
        return false
    end)
end

-- Lab monitor (lab systems, any co-op activity, whatever the test): what's on this screen that shouldn't be, and
-- what spins. Every 2 s, each visible fighting character is classified (tc_enemies.whatIs): anything but our player,
-- the partner's character, an enemy running here or a twin following the partner's enemy is logged "GHOST" with
-- where it is. 10 times a second, the visible characters' body (pelvis) and actor facing are compared with the last
-- sample: turning faster than 540 deg/s for half a second is logged "SPIN" (what it is, both rates).
local function labMonitor()
    if U.config.system == "0" then return end
    local F = require("tc_flow")
    local S = require("tc_session")
    local E = require("tc_enemies")
    local P = require("tc_presence")
    local chars, scanAt, spin, ghostLogged = {}, -1e9, {}, {}
    local hiddenTargets, aimAt, aimLogAt, stats = {}, -1e9, nil, {}
    local pelvis
    local function wrap(d) return (d + 540) % 360 - 180 end
    U.poll("lab monitor", 50, function()
        if not (S.connected() and F.activity) then
            chars, spin = {}, {}
            return false
        end
        local now = TailCoop_Clock()
        local pc = U.playerController()
        local me = pc and U.valid(pc.Pawn) and pc.Pawn or nil
        local puppet = P.puppetActor()
        if now - scanAt >= 2000 then
            scanAt = now
            chars, hiddenTargets = {}, {}
            local ghosts = {}
            local ok, all = pcall(FindAllOf, "FightingCharacter")
            for _, c in ipairs(ok and all or {}) do
                if U.valid(c) then
                    pcall(function()
                        -- Characters placed in a level only (cutscene assets hold template characters too).
                        if not c:GetFullName():find(":PersistentLevel.", 1, true) then return end
                        if c.m_bIsPooled and not c.m_bPooledActorActive then return end
                        if c.bHidden or not c.Mesh:IsVisible() then
                            -- Hidden but alive: Sifu's auto-aim takes those too.
                            if c.m_HealthComponent.m_fHealth > 0 and not (me and c:GetAddress() == me:GetAddress()) then
                                hiddenTargets[#hiddenTargets + 1] = { actor = c, kind = E.whatIs(c:GetAddress())
                                    or ("unknown " .. c:GetClass():GetFName():ToString()) }
                            end
                            return
                        end
                        local addr = c:GetAddress()
                        local kind
                        if me and addr == me:GetAddress() then kind = "our player"
                        elseif U.valid(puppet) and addr == puppet:GetAddress() then kind = "partner's character"
                        else kind = E.whatIs(addr) or ("unknown " .. c:GetClass():GetFName():ToString()) end
                        chars[#chars + 1] = { actor = c, kind = kind }
                        local expected = kind == "our player" or kind == "partner's character"
                            or (kind:find("^running ") and not kind:find("dead"))
                            or (kind:find("^twin of ") and not kind:find("not following")) or kind:find("^running .*%(dead%)")
                        if not expected then
                            local l = c:K2_GetActorLocation()
                            local h = c.m_HealthComponent.m_fHealth
                            ghosts[#ghosts + 1] = string.format("%s at %.0f %.0f %.0f health %.0f", kind, l.X, l.Y, l.Z, h)
                        end
                    end)
                end
            end
            local key = table.concat(ghosts, "; ")
            if #ghosts > 0 and (key ~= ghostLogged.key or now - (ghostLogged.at or 0) > 10000) then
                ghostLogged.key, ghostLogged.at = key, now
                U.log("GHOST: %d visible character(s) that shouldn't be: %s", #ghosts, key)
            end
        end
        -- What our attacks would aim at (Sifu's auto-aim, UAttackComponent:BPF_GetTargetForInput(AttackLight)), and
        -- invisible valid targets close to us: "AIM" when our target is one the player can't see.
        if me and now - aimAt >= 200 then
            aimAt = now
            local ml = me:K2_GetActorLocation()
            local okT, tgt = pcall(function() return me.m_AttackComponent:BPF_GetTargetForInput(0) end)
            if okT and U.valid(tgt) then
                local hidden = tgt.bHidden
                pcall(function() hidden = hidden or not tgt.Mesh:IsVisible() end)
                stats.aimed = (stats.aimed or 0) + 1
                -- An enemy that's dead in its owner's game (its twin lying there, or our copy of it): punching its
                -- body's spot turns the player in place too (user 2026-10-10 06:07:56, right after a kill).
                local tkind = E.whatIs(tgt:GetAddress())
                if tkind and tkind:find("(dead)", 1, true) then
                    stats.aimedDead = (stats.aimedDead or 0) + 1
                    if now - (stats.deadLogAt or 0) > 1000 then
                        stats.deadLogAt = now
                        local l = tgt:K2_GetActorLocation()
                        U.log("AIM: our attacks aim at a DEAD enemy - %s%s, %.0f cm from us (%d of %d target checks so far)",
                            tkind, hidden and " (invisible)" or "", math.sqrt((l.X - ml.X) ^ 2 + (l.Y - ml.Y) ^ 2),
                            stats.aimedDead, stats.aimed)
                    end
                end
                -- (A hidden copy with its visible twin on the same spot isn't thin air: the player sees that enemy.
                -- Not a body: a dead one's twin there doesn't make the target real.)
                if hidden then
                    local l0 = tgt:K2_GetActorLocation()
                    for _, ch in ipairs(chars) do
                        if U.valid(ch.actor) and ch.kind ~= "our player" and not ch.kind:find("(dead)", 1, true) then
                            local okV, v = pcall(function() return ch.actor:K2_GetActorLocation() end)
                            if okV and math.sqrt((v.X - l0.X) ^ 2 + (v.Y - l0.Y) ^ 2) < 80 then
                                hidden = false
                                break
                            end
                        end
                    end
                end
                if hidden then
                    stats.aimedHidden = (stats.aimedHidden or 0) + 1
                    local l = tgt:K2_GetActorLocation()
                    if now - (aimLogAt or 0) > 1000 then
                        aimLogAt = now
                        U.log("AIM: our attacks aim at thin air - an INVISIBLE %s, %.0f cm from us (%d of %d target checks so far)",
                            E.whatIs(tgt:GetAddress()) or U.shortName(tgt), math.sqrt((l.X - ml.X) ^ 2 + (l.Y - ml.Y) ^ 2),
                            stats.aimedHidden, stats.aimed)
                    end
                end
            end
            for _, h in ipairs(hiddenTargets) do
                if U.valid(h.actor) then
                    local okL, l = pcall(function() return h.actor:K2_GetActorLocation() end)
                    local d = okL and math.sqrt((l.X - ml.X) ^ 2 + (l.Y - ml.Y) ^ 2 + (l.Z - ml.Z) ^ 2) or 1e9
                    -- (Not a hidden copy with its visible twin on the same spot.)
                    local twinThere = false
                    for _, ch in ipairs(chars) do
                        local okV, v = false, nil
                        if U.valid(ch.actor) then okV, v = pcall(function() return ch.actor:K2_GetActorLocation() end) end
                        if okV and ch.kind ~= "our player" and math.sqrt((v.X - l.X) ^ 2 + (v.Y - l.Y) ^ 2) < 80 then
                            twinThere = true
                            break
                        end
                    end
                    if d < 250 and not twinThere and now - (h.loggedAt or 0) > 3000 then
                        h.loggedAt = now
                        U.log("AIM: invisible but targetable %s %.0f cm from us", h.kind, d)
                    end
                end
            end
        end
        -- Body facing: the line between the hips (one bone's own angle flips about in normal moves).
        pelvis = pelvis or { FName("thigh_l"), FName("thigh_r") }
        -- (The two players only: what was reported spinning. Every character every 50 ms cost ~9 ms a second.)
        for _, ch in ipairs(chars) do
            local c = ch.actor
            if U.valid(c) and (ch.kind == "our player" or ch.kind == "partner's character") then
                local ok, body, facing, l = pcall(function()
                    local a, b = c.Mesh:GetSocketLocation(pelvis[1]), c.Mesh:GetSocketLocation(pelvis[2])
                    return math.deg(math.atan(a.Y - b.Y, a.X - b.X)), c:K2_GetActorRotation().Yaw, c:K2_GetActorLocation()
                end)
                if ok then
                    -- Turned (body, unwrapped) over the last 1.5 s while staying within 1 m: a full turn in place is
                    -- "SPIN" (the user: "stuck, attack animations sped up, turns 360 in place").
                    local key = c:GetAddress()
                    local s = spin[key]
                    if not s then
                        s = { body = body, facing = facing, hist = {} }
                        spin[key] = s
                    end
                    s.turned = (s.turned or 0) + wrap(body - s.body)
                    s.turnedF = (s.turnedF or 0) + wrap(facing - s.facing)
                    s.body, s.facing = body, facing
                    local h = s.hist
                    h[#h + 1] = { t = now, b = s.turned, f = s.turnedF, x = l.X, y = l.Y }
                    while #h > 1 and now - h[1].t > 1500 do table.remove(h, 1) end
                    local first = h[1]
                    local net = math.abs(s.turned - first.b)
                    local moved = math.sqrt((l.X - first.x) ^ 2 + (l.Y - first.y) ^ 2)
                    local act0 = ch.kind == "our player" and require("tc_moves").lastOwnAction or nil
                    -- (Not our own death and getting up: the body rolls over, that's the animation.)
                    local dying = act0 and act0.path and (act0.path:find("[Dd]eath") or act0.path:find("resurrect"))
                    if now - first.t >= 1000 and net >= 540 and moved < 60 and not ch.kind:find("dead") and not dying
                        and now - (s.loggedAt or 0) > 3000 then
                        s.loggedAt = now
                        local what = ""
                        pcall(function()
                            local m = c.Mesh
                            what = string.format("dilation %.2f animRate %.2f playRate %.2f", c.CustomTimeDilation,
                                m.GlobalAnimRateScale, m:GetPlayRate())
                        end)
                        local act = nil
                        local id = ch.kind:match("(BP_%S+#%d+)")
                        if id then act = E.actionNow(id) end
                        if ch.kind == "our player" then act = require("tc_moves").lastOwnAction end
                        U.log("SPIN: %s turned %.0f deg (body) / %.0f deg (facing) in %.1f s, moved %.0f cm, at %.0f %.0f | %s | "
                            .. "action %s", ch.kind, s.turned - first.b, s.turnedF - first.f, (now - first.t) / 1000, moved,
                            l.X, l.Y, what, act and act.path and (act.path:match("[^/]+$") or act.path) or "-")
                    end
                end
            end
        end
        return false
    end)
end

-- spawnprobe (with arenago + arenakill): when each wave spawner's class (the variant it will send out) is chosen,
-- compared with when its enemy appears - can the host's choice reach the joiner's spawner first?
local function spawnProbe()
    local F = require("tc_flow")
    local spawners, listAt, last = {}, -1e9, {}
    for _, path in ipairs({ "/Script/Sifu.AIWaveRefillDirector:BPE_OnRefillSequenceStarted",
        "/Script/Sifu.AIWaveSpawner:BPF_SetArchetypeToSpawn", "/Script/Sifu.AISpawner:BPF_SetSpawningClass",
        "/Script/Sifu.AISpawner:BPE_OnRespawnFinished", "/Script/Sifu.AIWaveRefillDirector:BPE_OnWaveStarted" }) do
        local ok, err = pcall(RegisterHook, path, function(ctx)
            local who = "?"
            pcall(function() who = ctx:get():GetFName():ToString() end)
            U.log("SPAWNPROBE hook %s on %s (clock %d)", path:match("[^:]+$"), who, TailCoop_Clock())
        end)
        U.log("SPAWNPROBE hooking %s: %s", path:match("[^:]+$"), ok and "ok" or tostring(err))
    end
    U.poll("spawnprobe", 10, function()
        if F.activity ~= "arena" then
            spawners, last = {}, {}
            return false
        end
        local now = TailCoop_Clock()
        if now - listAt > 2000 then
            listAt = now
            local ok, all = pcall(FindAllOf, "AIWaveSpawner")
            spawners = {}
            for _, sp in ipairs(ok and all or {}) do
                if U.valid(sp) and not sp:GetFullName():find("Default__", 1, true) then spawners[#spawners + 1] = sp end
            end
        end
        for _, sp in ipairs(spawners) do
            if U.valid(sp) then
                local ok, cls, busy = pcall(function()
                    local c = sp.m_SpawningClass
                    return U.valid(c) and c:GetFName():ToString() or "none", sp:IsSpawnerBusy()
                end)
                local key = sp:GetFName():ToString()
                local v = ok and (tostring(cls) .. (busy and " busy" or "")) or "?"
                if last[key] ~= v then
                    U.log("SPAWNPROBE %s: %s -> %s (clock %d)", key, tostring(last[key]), v, now)
                    last[key] = v
                end
            end
        end
        return false
    end)
end

-- spawnask (with arenago, host): can a wave spawner be asked to send out an enemy of a class we choose (the host's
-- variant), outside its wave director, and does that enemy fight? Every 20 s from 20 s after Start: a free wave
-- spawner gets a pooled character's class and is asked (a different call each round); then its spawned AI, class and
-- combat role are logged for 6 s.
local function spawnAsk()
    if U.config.role ~= "host" then return end
    local F = require("tc_flow")
    local startAt, nextAt, round, watch = nil, nil, 0, nil
    local calls = { "class + WantsSpawn", "archetype + WantsSpawn", "archetype + class + WantsSpawn",
        "level spawner: class + WantsSpawn" }
    U.poll("spawnask", 250, function()
        if F.activity ~= "arena" then
            startAt = nil
            return false
        end
        local now = TailCoop_Clock()
        startAt = startAt or now
        nextAt = nextAt or startAt + 20000
        local pc = U.playerController()
        local me = pc and U.valid(pc.Pawn) and pc.Pawn or nil
        if watch then
            local sp = watch.spawner
            local ok, s = pcall(function()
                local ai = sp:BPF_GetSpawnedAI()
                local cls = sp:BPF_GetSpawningClass()
                local role, ticket, enemy = "-", "-", "-"
                if U.valid(ai) then
                    pcall(function()
                        local fc = ai.m_AIComponent or ai
                        role = tostring(fc:BPF_GetCurrentCombatRole())
                        ticket = tostring(fc:BPF_HasAttackTicket())
                        enemy = U.shortName(fc:BPF_GetEnemy())
                    end)
                end
                return string.format("has %s busy %s spawned %s spawning class %s | role %s ticket %s enemy %s",
                    tostring(sp:BPF_HasSpawnedAI()), tostring(sp:IsSpawnerBusy()), U.shortName(ai),
                    U.valid(cls) and cls:GetFName():ToString() or "none", role, ticket, enemy)
            end)
            if not ok or s ~= watch.last or now - watch.loggedAt > 2000 then
                watch.last, watch.loggedAt = s, now
                U.log("SPAWNASK round %d +%.1f s: %s", watch.round, (now - watch.at) / 1000, ok and s or tostring(s))
            end
            if now - watch.at > 8000 then watch = nil end
            return false
        end
        if now < nextAt then return false end
        nextAt = now + 20000
        round = round + 1
        if round > #calls then return true end
        -- A pooled character's class (loaded, and one the arena uses).
        local cls
        for _, c in ipairs(FindAllOf("FightingCharacter") or {}) do
            local okP, p = pcall(function() return c.m_bIsPooled and not c.m_bPooledActorActive end)
            if okP and p and not cls then
                pcall(function() if c:GetClass():GetFName():ToString():find("Grunt_W") then cls = c:GetClass() end end)
            end
        end
        local how = calls[round]
        local free
        for _, sp in ipairs(FindAllOf(how:find("level") and "AISpawner" or "AIWaveSpawner") or {}) do
            local okF, isFree = pcall(function()
                local n = sp:GetFullName()
                return not n:find("Default__", 1, true) and not (how:find("level") and n:find("Wave", 1, true))
                    and not sp:BPF_HasSpawnedAI() and not sp:IsSpawnerBusy()
            end)
            if okF and isFree and not free then free = sp end
        end
        if not (cls and free) then
            U.log("SPAWNASK round %d: class %s, free spawner %s", round, U.shortName(cls), U.shortName(free))
            return false
        end
        local ok, err = pcall(function()
            if how:find("archetype") then free:BPF_SetArchetypeToSpawn(2) end  -- EAIArchetype Grunt
            if how:find("class") then free:BPF_SetSpawningClass(cls) end
            if how:find("level") then free:BPF_SetCanRespawn(true) end
            free:BPF_WantsSpawn()
        end)
        U.log("SPAWNASK round %d: %s on %s with class %s: %s", round, how, free:GetFName():ToString(),
            cls:GetFName():ToString(), ok and "ok" or tostring(err))
        watch = { spawner = free, at = now, loggedAt = 0, round = round }
        return false
    end)
end

-- standinfight (with arenago, joiner): stand-ins (spawned from a class, not by a spawner) never enter Sifu's fight.
-- Does one that gets a real enemy's spawner and phase scenario (UAIComponent m_Spawner, UAIFightingComponent
-- m_PhaseScenario / m_Behavior) fight? Every 15 s from 20 s after Start a pooled class is spawned 4 m in front of
-- our player, set up a different way each round, aimed at us; role, target, brain, attack ticket logged for 8 s.
local function standInFight()
    if U.config.role ~= "join" then return end
    local F = require("tc_flow")
    local E = require("tc_enemies")
    local startAt, nextAt, round, watch = nil, nil, 0, nil
    local ways = { "OnRep_Spawner", "OnAIInitialized", "RunBehaviorTree", "RunBehaviorTree + phase 0 + behaviour change" }
    U.poll("standinfight", 250, function()
        if F.activity ~= "arena" then
            startAt = nil
            return false
        end
        local now = TailCoop_Clock()
        startAt = startAt or now
        nextAt = nextAt or startAt + 20000
        local pc = U.playerController()
        local me = pc and U.valid(pc.Pawn) and pc.Pawn or nil
        if not me then return false end
        if watch then
            local a = watch.actor
            if not U.valid(a) then
                U.log("STANDIN round %d: gone", watch.round)
                watch = nil
                return false
            end
            local ok, s = pcall(function()
                local ai = a.m_AIComponent
                local brain = "?"
                pcall(function() brain = tostring(a.Controller.BrainComponent:IsRunning()) end)
                local reg = "?"
                pcall(function()
                    reg = tostring(StaticFindObject("/Script/Sifu.Default__AIHelpers"):BPF_IsAttackerRegisteredInCombatForTarget(a, me))
                end)
                local beh = "?"
                pcall(function() beh = tostring(ai:BPF_GetGlobalBehavior(false)) end)
                local l, ml = a:K2_GetActorLocation(), me:K2_GetActorLocation()
                return string.format("role %s enemy %s behaviour %s brain %s registered %s ticket %s spawner %s scenario %s "
                    .. "dist %.0f hp %.0f", tostring(ai:BPF_GetCurrentCombatRole()), U.shortName(ai:BPF_GetEnemy()),
                    beh, brain, reg, tostring(ai:BPF_HasAttackTicket()),
                    U.shortName(ai.m_Spawner), U.shortName(ai.m_PhaseScenario),
                    math.sqrt((l.X - ml.X) ^ 2 + (l.Y - ml.Y) ^ 2), a.m_HealthComponent.m_fHealth)
            end)
            if not ok or s ~= watch.last or now - watch.loggedAt > 2000 then
                watch.last, watch.loggedAt = s, now
                U.log("STANDIN round %d (%s) +%.1f s: %s", watch.round, watch.way, (now - watch.at) / 1000,
                    ok and s or tostring(s))
            end
            if now - watch.at > 8000 then
                pcall(function() watch.actor:ServerSuicide(false) end)
                watch = nil
            end
            return false
        end
        if now < nextAt then return false end
        nextAt = now + 15000
        round = round + 1
        if round > #ways then return true end
        local way = ways[round]
        -- A real enemy here (one of ours, held or put aside: its AI was set up by its spawner) lends its setup.
        local donor
        for _, e in ipairs(E.list()) do
            local okD, has = pcall(function()
                local ai = e.actor.m_AIComponent
                return U.valid(ai.m_Spawner) and U.valid(ai.m_PhaseScenario)
            end)
            if okD and has and not donor then donor = e.actor end
        end
        local cls
        for _, c in ipairs(FindAllOf("FightingCharacter") or {}) do
            local okP, p = pcall(function() return c.m_bIsPooled and not c.m_bPooledActorActive end)
            if okP and p and not cls then
                pcall(function() if c:GetClass():GetFName():ToString():find("Grunt") then cls = c:GetClass() end end)
            end
        end
        if not (cls and donor) then
            U.log("STANDIN round %d: class %s donor %s", round, U.shortName(cls), U.shortName(donor))
            return false
        end
        local dai = donor and donor.m_AIComponent
        pcall(function()
            U.log("STANDIN donor %s: m_Behavior %s archetype %s controller %s brain %s", U.shortName(donor),
                U.shortName(dai.m_Behavior), U.shortName(dai.m_CurrentAIArchetype), U.shortName(donor.Controller),
                U.shortName(donor.Controller.BrainComponent))
        end)
        local function lend(ai)
            ai.m_Spawner = dai.m_Spawner
            ai.m_PhaseScenario = dai.m_PhaseScenario
            if U.valid(dai.m_Behavior) then ai.m_Behavior = dai.m_Behavior end
        end
        local ok, actor = pcall(function()
            local gs = require("UEHelpers").GetGameplayStatics()
            local l, f = me:K2_GetActorLocation(), me:GetActorForwardVector()
            local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                         Translation = { X = l.X + f.X * 400, Y = l.Y + f.Y * 400, Z = l.Z + 50 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
            local a = gs:BeginDeferredActorSpawnFromClass(U.world(), cls, xf, 1, nil)
            E.ignore(a)
            gs:FinishSpawningActor(a, xf)
            return a
        end)
        if not (ok and U.valid(actor)) then
            U.log("STANDIN round %d (%s): spawn failed: %s", round, way, tostring(actor))
            return false
        end
        local ok2, err2 = pcall(function()
            local ai = actor.m_AIComponent
            actor:SpawnDefaultController()
            lend(ai)
            if way == "OnRep_Spawner" then ai:OnRep_Spawner() end
            if way == "OnAIInitialized" then ai:OnAIInitialized() end
            if way:find("RunBehaviorTree") then
                U.log("STANDIN RunBehaviorTree(%s): %s", U.shortName(dai.m_Behavior), tostring(actor.Controller:RunBehaviorTree(dai.m_Behavior)))
            end
            if way:find("phase 0") then ai:BPF_SwitchToPhase(0) end
            if way:find("behaviour change") then ai:BPF_TriggerBehaviorChange(me, 3, 0, true) end
            U.log("STANDIN controller now %s, brain %s", U.shortName(actor.Controller),
                U.shortName(U.valid(actor.Controller) and actor.Controller.BrainComponent or nil))
            ai:BPF_ForceEnemy(me, 3)
        end)
        U.log("STANDIN round %d (%s): %s from class %s, donor %s (spawner %s): %s", round, way, U.shortName(actor),
            cls:GetFName():ToString(), U.shortName(donor), donor and U.shortName(dai.m_Spawner) or "-",
            ok2 and "ok" or tostring(err2))
        watch = { actor = actor, at = now, loggedAt = 0, round = round, way = way }
        return false
    end)
end

-- factory (with arenago, joiner): an enemy of a class we choose, sent out by a spawner the way Sifu does it (a level
-- spawner's BPF_WantsSpawn after BPF_SetSpawningClass fought - spawnask), but from a spawner of our own spawned at
-- runtime (no level layout needed, no situation of the level touched). Every 15 s from 20 s: a pooled class, set up a
-- different way each round, 4 m in front of our player; role, target, ticket logged for 8 s, then it's killed.
local function spawnFactory()
    if U.config.role ~= "join" then return end
    local F = require("tc_flow")
    local E = require("tc_enemies")
    local startAt, nextAt, round, watch = nil, nil, 0, nil
    local ways = { "own spawner + scenario", "own spawner, nothing copied", "level spawner moved here" }
    U.poll("factory", 250, function()
        if F.activity ~= "arena" then
            startAt = nil
            return false
        end
        local now = TailCoop_Clock()
        startAt = startAt or now
        nextAt = nextAt or startAt + 20000
        local pc = U.playerController()
        local me = pc and U.valid(pc.Pawn) and pc.Pawn or nil
        if not me then return false end
        if watch then
            local a = watch.actor
            if not U.valid(a) then
                U.log("FACTORY round %d: gone", watch.round)
                watch = nil
                return false
            end
            local ok, s = pcall(function()
                local ai = a.m_AIComponent
                local brain = "?"
                pcall(function() brain = tostring(a.Controller.BrainComponent:IsRunning()) end)
                local beh = "?"
                pcall(function() beh = tostring(ai:BPF_GetGlobalBehavior(false)) end)
                local l, ml = a:K2_GetActorLocation(), me:K2_GetActorLocation()
                return string.format("role %s enemy %s behaviour %s brain %s ticket %s dist %.0f hp %.0f",
                    tostring(ai:BPF_GetCurrentCombatRole()), U.shortName(ai:BPF_GetEnemy()), beh, brain,
                    tostring(ai:BPF_HasAttackTicket()), math.sqrt((l.X - ml.X) ^ 2 + (l.Y - ml.Y) ^ 2),
                    a.m_HealthComponent.m_fHealth)
            end)
            if ok and s:find("ticket true") then watch.ticket = true end
            if not ok or s ~= watch.last or now - watch.loggedAt > 2000 then
                watch.last, watch.loggedAt = s, now
                U.log("FACTORY round %d (%s) +%.1f s: %s", watch.round, watch.way, (now - watch.at) / 1000, ok and s or tostring(s))
            end
            if now - watch.at > 8000 then
                U.log("FACTORY round %d (%s): took an attack ticket: %s", watch.round, watch.way, tostring(watch.ticket == true))
                pcall(function() watch.actor:ServerSuicide(false) end)
                watch = nil
            end
            return false
        end
        if now < nextAt then return false end
        nextAt = now + 15000
        round = round + 1
        if round > #ways then return true end
        local way = ways[round]
        local cls
        for _, c in ipairs(FindAllOf("FightingCharacter") or {}) do
            local okP, p = pcall(function() return c.m_bIsPooled and not c.m_bPooledActorActive end)
            if okP and p and not cls then
                pcall(function() if c:GetClass():GetFName():ToString():find("Grunt") then cls = c:GetClass() end end)
            end
        end
        -- A level spawner (not a wave one): its class for ours, its scenario to copy; a free one to move.
        local level, freeLevel
        for _, sp in ipairs(FindAllOf("AISpawner") or {}) do
            pcall(function()
                local n = sp:GetFullName()
                if n:find("Default__", 1, true) or n:find("Wave", 1, true) or not n:find(":PersistentLevel.", 1, true) then return end
                level = level or sp
                if not freeLevel and not sp:BPF_HasSpawnedAI() and not sp:IsSpawnerBusy() then freeLevel = sp end
            end)
        end
        if not (cls and level) then
            U.log("FACTORY round %d: class %s level spawner %s", round, U.shortName(cls), U.shortName(level))
            return false
        end
        local l, f = me:K2_GetActorLocation(), me:GetActorForwardVector()
        local at = { X = l.X + f.X * 400, Y = l.Y + f.Y * 400, Z = l.Z }
        local ok, res = pcall(function()
            local sp
            if way == "level spawner moved here" then
                sp = freeLevel
                if not sp then error("no free level spawner") end
                sp:K2_SetActorLocation(at, false, {}, true)
            else
                local gs = require("UEHelpers").GetGameplayStatics()
                local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = at, Scale3D = { X = 1, Y = 1, Z = 1 } }
                sp = gs:BeginDeferredActorSpawnFromClass(U.world(), level:GetClass(), xf, 1, nil)
                if way:find("scenario") then
                    sp.m_PhaseScenario = level.m_PhaseScenario
                    sp.m_eFaction = level.m_eFaction
                end
                gs:FinishSpawningActor(sp, xf)
            end
            sp:BPF_SetSpawningClass(cls)
            sp:BPF_SetCanRespawn(true)
            sp:BPF_WantsSpawn()
            local ai = sp:BPF_GetSpawnedAI()
            if U.valid(ai) then E.ignore(ai) end
            return { sp = sp, ai = ai }
        end)
        U.log("FACTORY round %d (%s): spawner %s, class %s -> %s", round, way, ok and U.shortName(res.sp) or "-",
            cls:GetFName():ToString(), ok and U.shortName(res.ai) or tostring(res))
        if ok and U.valid(res.ai) then
            pcall(function() res.ai.m_AIComponent:BPF_ForceEnemy(me, 3) end)
            watch = { actor = res.ai, at = now, loggedAt = 0, round = round, way = way }
        end
        return false
    end)
end

-- pauseprobe (with arenago): what fires when the player opens the pause menu (the lab presses Escape) - while the
-- game is paused no delayed action of the mod runs, only hooks. Hooks a few engine functions and every function of
-- the pause menu classes found live; each call logged with the game's paused state.
local function pauseProbe()
    local F = require("tc_flow")
    local hooked = {}
    local function paused()
        local ok, p = pcall(function() return require("UEHelpers").GetGameplayStatics():IsGamePaused(U.world()) end)
        return ok and tostring(p) or "?"
    end
    local function hook(path)
        if hooked[path] then return end
        hooked[path] = true
        local ok, err = pcall(RegisterHook, path, function()
            U.log("PAUSEPROBE %s (paused %s, clock %d)", path:match("[^%.]+$"), paused(), TailCoop_Clock())
        end)
        if not ok then U.log("PAUSEPROBE can't hook %s: %s", path, tostring(err)) end
    end
    for _, p in ipairs({ "/Script/Engine.GameplayStatics:SetGamePaused", "/Script/Engine.PlayerController:SetPause",
        "/Script/Engine.PlayerController:Pause", "/Script/Engine.UserWidget:SetInputActionPriority" }) do hook(p) end
    for _, cls in ipairs({ "BP_PagedMenu_Pause_C", "BP_Menu_Pause_Arena_C" }) do
        pcall(NotifyOnNewObject, "/Script/UMG.UserWidget", function(o)
            pcall(function()
                if o:GetClass():GetFName():ToString() == cls then U.log("PAUSEPROBE new %s (paused %s)", cls, paused()) end
            end)
        end)
    end
    local lastPaused
    U.poll("pauseprobe", 500, function()
        if F.activity ~= "arena" then return false end
        local p = paused()
        if p ~= lastPaused then
            lastPaused = p
            U.log("PAUSEPROBE poll: paused %s", p)
        end
        for _, cls in ipairs({ "BP_PagedMenu_Pause_C", "BP_Menu_Pause_Arena_C" }) do
            local ok, all = pcall(FindAllOf, cls)
            for _, inst in ipairs(ok and all or {}) do
                pcall(function()
                    if inst:GetFullName():find("Default__", 1, true) then return end
                    local n = 0
                    inst:GetClass():ForEachFunction(function(fn)
                        local path = fn:GetFullName():match("^%S+%s+(.+)$")
                        if path and not hooked[path] then
                            n = n + 1
                            hook(path)
                        end
                    end)
                    if n > 0 then U.log("PAUSEPROBE hooked %d functions of a live %s", n, cls) end
                end)
            end
        end
        return false
    end)
end

-- Takedown kit (lab console, any co-op session): T.td.setup(who) picks the first live enemy, makes it fight `who`
-- ("host"/"join"; the host decides), makes this game's copy of it break its structure in one hit, and puts our player
-- in front of it if we're `who` (else 12 m away). T.td.watch(seconds) logs every change of: our player's action, the
-- enemy's health / guard / action here (the copy we have: running enemy, or hidden copy + twin). For the takedown
-- and grab tests: what a synchronized move does in each game.
T.td = {}
local tdState = {}
local function tdEnemy()
    local E = require("tc_enemies")
    for _, e in ipairs(E.list()) do
        if not E.isDead(e.id) and not e.dormant and not e.wrongKind then return e end
    end
    return nil
end

function T.td.setup(who)
    local E = require("tc_enemies")
    local S = require("tc_session")
    local e = tdEnemy()
    if not e then return "no enemy" end
    tdState.id = e.id
    if S.role == "host" then E.assign(e.id, who, who) end
    local c = E.localActorFor(e.id) or e.actor  -- our hidden copy when the partner runs it
    local okB = pcall(function() c.m_DefenseComponent:BPF_SetIsOnePunchBreaker(true) end)
    -- (Standing still where it runs: a fighting dummy kept hitting the test player before it could land a hit.)
    if E.mine(e.id) then pcall(function() c.Controller.BrainComponent:StopLogic("lab: takedown test") end) end
    local pawn = U.playerController().Pawn
    local l, fwd = c:K2_GetActorLocation(), c:GetActorForwardVector()
    local d = who == S.role and 130 or 1200
    local yaw = math.deg(math.atan(-fwd.Y, -fwd.X))
    pawn:K2_SetActorLocationAndRotation({ X = l.X + fwd.X * d, Y = l.Y + fwd.Y * d, Z = pawn:K2_GetActorLocation().Z },
        { Pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
    pcall(function() U.playerController():SetControlRotation({ Pitch = -10, Yaw = yaw, Roll = 0 }) end)
    return string.format("%s owner %s, fights %s, one-punch breaker %s, our player %d cm in front", e.id, E.ownerOf(e.id),
        who, tostring(okB), d)
end

-- T.td.front(): the joiner's player 130 cm in front of the nearest enemy the host runs (its hidden copy here), facing
-- it; that copy breaks its structure in one hit. Returns the id.
function T.td.front(id)
    local E = require("tc_enemies")
    local pawn = U.playerController().Pawn
    local m = pawn:K2_GetActorLocation()
    local best, bd
    for _, e in ipairs(E.list()) do
        local c = E.localActorFor(e.id)
        if c and not E.isDead(e.id) and (not id or e.id == id) then
            local l = c:K2_GetActorLocation()
            local d = (l.X - m.X) ^ 2 + (l.Y - m.Y) ^ 2
            if not bd or d < bd then best, bd = e, d end
        end
    end
    if not best then return "no enemy the partner runs" end
    tdState.id = best.id
    local c = E.localActorFor(best.id)
    pcall(function() c.m_DefenseComponent:BPF_SetIsOnePunchBreaker(true) end)
    local l, fwd = c:K2_GetActorLocation(), c:GetActorForwardVector()
    local yaw = math.deg(math.atan(-fwd.Y, -fwd.X))
    pawn:K2_SetActorLocationAndRotation({ X = l.X + fwd.X * 130, Y = l.Y + fwd.Y * 130, Z = m.Z },
        { Pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
    pcall(function() U.playerController():SetControlRotation({ Pitch = -10, Yaw = yaw, Roll = 0 }) end)
    return best.id
end

-- T.td.hold(seconds): the host's enemy nearest the partner's character stands still (its AI stopped again every
-- 200 ms) so the joiner's hit lands; returns its id.
function T.td.hold(seconds)
    local E = require("tc_enemies")
    local p = require("tc_presence").puppetActor()
    if not U.valid(p) then return "no partner" end
    local m = p:K2_GetActorLocation()
    local best, bd
    for _, e in ipairs(E.running()) do
        local l = e.actor:K2_GetActorLocation()
        local d = (l.X - m.X) ^ 2 + (l.Y - m.Y) ^ 2
        if not bd or d < bd then best, bd = e, d end
    end
    if not best then return "nothing running here" end
    tdState.id = best.id
    local untilAt = TailCoop_Clock() + (seconds or 8) * 1000
    U.poll("td hold", 200, function()
        if TailCoop_Clock() > untilAt or not E.mine(best.id) then return true end
        pcall(function() best.actor.Controller.BrainComponent:StopLogic("lab: takedown test") end)
        return false
    end)
    return best.id
end

function T.td.watch(seconds)
    local E = require("tc_enemies")
    local id = tdState.id
    if not id then return "setup first" end
    local untilAt, last = TailCoop_Clock() + (seconds or 20) * 1000, {}
    local function short(p) return p and (p:match("([^/%.]+)%.[^/]*$") or p:match("[^/]+$") or p) or "-" end
    U.poll("td watch", 50, function()
        local now = TailCoop_Clock()
        if now > untilAt then
            U.log("TD watch over")
            return true
        end
        local pc = U.playerController()
        local own = require("tc_moves").lastOwnAction
        local c = E.localActorFor(id)
        local running = not c
        if running then
            for _, e in ipairs(E.list()) do if e.id == id then c = e.actor end end
        end
        local st = "?"
        pcall(function()
            local d = c.m_DefenseComponent
            st = string.format("hp %.0f guard %.2f broken %s", c.m_HealthComponent.m_fHealth, d:BPF_GetGuardRatio(),
                tostring(d:BPF_IsGuardBroken()))
        end)
        local act = E.actionNow(id)
        local items = {
            me = own and now - own.at < 3000 and short(own.path) or "-",
            enemy = st,
            action = act and short(act.path) or "-",
            owner = E.ownerOf(id),
            meHp = (function() local ok, h = pcall(function() return pc.Pawn.m_HealthComponent.m_fHealth end) return ok and string.format("%.0f", h) or "?" end)(),
        }
        for k, v in pairs(items) do
            if last[k] ~= v then
                U.log("TD %s: %s -> %s (%s)", k, tostring(last[k]), v, running and "enemy runs here" or "partner runs it")
                last[k] = v
            end
        end
        return false
    end)
    return "watching " .. id .. " for " .. tostring(seconds or 20) .. " s"
end

-- What a character is like right now (takedown tests): place, movement mode, capsule / actor collision, hidden, what
-- it's attached to, the action orders it runs (EOrderType: 8/9 takedown instigator/victim, 10 knocked down,
-- 17 recovery, 18/19 down/standup, 33 structure broken, 63 incapacitated), AI, health.
local function tdDescribe(c)
    if not U.valid(c) then return "gone" end
    local parts = {}
    local function add(k, f)
        local ok, v = pcall(f)
        parts[#parts + 1] = k .. "=" .. (ok and tostring(v) or "?")
    end
    add("at", function() local l = c:K2_GetActorLocation() return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) end)
    add("mm", function() return c.CharacterMovement.MovementMode end)
    add("cap", function() return c.CapsuleComponent:GetCollisionEnabled() end)
    add("col", function() return c:GetActorEnableCollision() end)
    add("hid", function() return c.bHidden end)
    add("par", function()
        local p = c:GetAttachParentActor()
        return U.valid(p) and p:GetFName():ToString() or "-"
    end)
    add("orders", function()
        local oc = c:BPF_GetOrderComponent()
        local ids = oc:BPF_GetRunningAndPendingActionOrders(false)
        local out = {}
        local function one(v)
            local id = type(v) == "number" and v or v:get()
            out[#out + 1] = tostring(oc:BPF_GetOrderTypeFromOrderID(id))
        end
        if type(ids) == "table" then
            for _, v in ipairs(ids) do one(v) end
        elseif ids and ids.ForEach then
            ids:ForEach(function(_, el) one(el) end)
        end
        return #out > 0 and table.concat(out, "/") or "-"
    end)
    add("ai", function() return c.Controller.BrainComponent:IsRunning() end)
    add("hp", function() return string.format("%.0f", c.m_HealthComponent.m_fHealth) end)
    return table.concat(parts, " ")
end
T.td.describe = tdDescribe

-- T.td.track(id, seconds): logs our copy of enemy `id` (running here, or the hidden copy) whenever tdDescribe changes
-- (place rounded to 50 cm), with who runs it ("TDSTATE" lines).
function T.td.track(id, seconds)
    local E = require("tc_enemies")
    id = id or tdState.id
    if not id then return "no id" end
    tdState.id = id
    local untilAt, last = TailCoop_Clock() + (seconds or 30) * 1000, nil
    U.poll("td track", 100, function()
        if TailCoop_Clock() > untilAt then
            U.log("TDSTATE %s: track over", id)
            return true
        end
        local c = E.localActorFor(id)
        local what = c and "hidden copy" or "running here"
        if not c then
            for _, e in ipairs(E.list()) do if e.id == id then c = e.actor end end
        end
        local d = c and tdDescribe(c) or "none here"
        -- (Compared without the exact place: a moving enemy would log every 100 ms.)
        local key = what .. " " .. E.ownerOf(id) .. " " .. d:gsub("at=(%-?%d+),(%-?%d+),(%-?%d+)", function(x, y, z)
            return string.format("at=%d,%d,%d", math.floor(x / 50), math.floor(y / 50), math.floor(z / 50))
        end)
        if key ~= last then
            last = key
            U.log("TDSTATE %s (%s, owner %s): %s", id, what, E.ownerOf(id), d)
        end
        return false
    end)
    return "tracking " .. id
end

-- Weapon kit (lab console): T.wp.near() puts our player next to the nearest weapon lying free in the level;
-- T.wp.comps() lists the components of the weapon we hold (or of `w`) with their classes and active state.
T.wp = {}
function T.wp.near(filter, side)
    local pawn = U.playerController().Pawn
    local offsets = { { 40, 0 }, { 0, 40 }, { -40, 0 }, { 0, -40 } }
    local off = offsets[((side or 1) - 1) % 4 + 1]
    local best, bd
    for _, w in ipairs(FindAllOf("BaseWeapon") or {}) do
        local ok, d = pcall(function()
            local n = w:GetFullName()
            if n:find("Default__", 1, true) or n:find("Expired", 1, true) or w.bHidden then return nil end
            if filter and not n:find(filter, 1, true) then return nil end
            local p = w:GetAttachParentActor()
            if p ~= nil and U.valid(p) then return nil end
            local l, m = w:K2_GetActorLocation(), pawn:K2_GetActorLocation()
            if math.abs(l.Z - m.Z) > 150 then return nil end
            return math.sqrt((l.X - m.X) ^ 2 + (l.Y - m.Y) ^ 2)
        end)
        if ok and d and (not bd or d < bd) then best, bd = w, d end
    end
    if not best then return "no free weapon" end
    local l = best:K2_GetActorLocation()
    pawn:K2_SetActorLocation({ X = l.X + off[1], Y = l.Y + off[2], Z = pawn:K2_GetActorLocation().Z }, false, {}, true)
    -- Facing it (the pickup prompt takes what the player faces).
    pcall(function()
        local yaw = math.deg(math.atan(-off[2], -off[1]))
        pawn:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false)
        U.playerController():SetControlRotation({ Pitch = -20, Yaw = yaw, Roll = 0 })
    end)
    T.wp.last = best
    return string.format("%s (%s) was %.0f cm away", best:GetFName():ToString(), best:GetClass():GetFName():ToString(), bd)
end

-- Our player faces the partner's character (a throw aimed at it lands in view of both screens).
function T.wp.facePartner()
    local pawn, p = U.playerController().Pawn, require("tc_presence").puppetActor()
    if not U.valid(p) then return "no partner" end
    local a, b = pawn:K2_GetActorLocation(), p:K2_GetActorLocation()
    local yaw = math.deg(math.atan(b.Y - a.Y, b.X - a.X))
    pawn:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false)
    pcall(function() U.playerController():SetControlRotation({ Pitch = -10, Yaw = yaw, Roll = 0 }) end)
    return string.format("facing the partner, %.0f cm away", math.sqrt((b.X - a.X) ^ 2 + (b.Y - a.Y) ^ 2))
end

function T.wp.comps(w)
    w = w or require("tc_gear").heldWeapons(U.playerController().Pawn)[1]
    if not U.valid(w) then return "holding nothing" end
    local out = { w:GetFName():ToString() .. " state " .. tostring(pcall(function() return w:BPF_GetThrowableState() end) and w:BPF_GetThrowableState()) }
    local arr = w:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent"))
    local function visit(c)
        pcall(function()
            local okA, a = pcall(function() return c:IsActive() end)
            local okV, v = pcall(function() return c:IsVisible() end)
            out[#out + 1] = string.format("%s(%s a=%s v=%s)", c:GetFName():ToString(), c:GetClass():GetFName():ToString(),
                okA and tostring(a) or "-", okV and tostring(v) or "-")
        end)
    end
    if type(arr) == "table" then
        for _, c in ipairs(arr) do
            local ok, x = pcall(function() return c:get() end)
            visit(ok and x or c)
        end
    elseif arr and arr.ForEach then
        arr:ForEach(function(_, el) local ok, x = pcall(function() return el:get() end) visit(ok and x or el) end)
    end
    return table.concat(out, " | ")
end

-- Synchronized-move watch (lab, every co-op activity): logs each takedown / grab / finisher animation started by our
-- player, by the partner's copy, by an enemy running here, and by a hidden copy here (its local reaction), with the
-- enemy's health in this game - what each game shows of one synchronized move ("SYNC" lines). With "onepunch = 1",
-- every enemy (and every copy) breaks its structure in one blow, so the bots' X presses (takedown) find targets.
local SYNC_WORDS = { "takedown", "finish", "execution", "grab", "throw", "synchron", "structurebroken", "dizzy" }
local function isSync(p)
    p = p and p:lower() or ""
    for _, w in ipairs(SYNC_WORDS) do if p:find(w, 1, true) then return true end end
    return false
end

local function syncWatch()
    if U.config.system == "0" then return end
    local F = require("tc_flow")
    local S = require("tc_session")
    local E = require("tc_enemies")
    local P = require("tc_presence")
    local A = require("tc_anim")
    local seen, punchAt, watchers = {}, -1e9, {}
    local function short(p) return p and (p:match("([^/%.]+)%.[^/]*$") or p:match("[^/]+$") or p) or "-" end
    local function note(key, who, path, extra)
        if not (path and isSync(path)) or seen[key] == path then return end
        seen[key] = path
        U.log("SYNC %s %s%s", who, short(path), extra or "")
    end
    U.poll("sync watch", 50, function()
        if not (S.connected() and F.activity) then
            seen, watchers = {}, {}
            return false
        end
        local now = TailCoop_Clock()
        if U.config.onepunch == "1" and now - punchAt >= 1000 then
            punchAt = now
            for _, e in ipairs(E.list()) do
                for _, c in ipairs({ e.actor, E.localActorFor(e.id) }) do
                    if U.valid(c) then pcall(function() c.m_DefenseComponent:BPF_SetIsOnePunchBreaker(true) end) end
                end
            end
        end
        local own = require("tc_moves").lastOwnAction
        if own and now - own.at < 2000 then note("me", "our player:", own.path) end
        local puppet = P.puppetActor()
        if U.valid(puppet) then
            watchers.puppet = watchers.puppet or A.watcher()
            local ev = watchers.puppet:update(puppet, now)
            if ev and ev.path then note("puppet", "partner's copy here:", ev.path) end
        end
        for _, e in ipairs(E.list()) do
            local a = E.actionNow(e.id)
            local h = "?"
            local c = E.localActorFor(e.id) or e.actor
            pcall(function() h = string.format("%.0f", c.m_HealthComponent.m_fHealth) end)
            if a and now - a.at < 2000 then
                note("e:" .. e.id, string.format("enemy %s (%s, hp here %s):", e.id,
                    E.mine(e.id) and "runs here" or "partner runs it", h), a.path)
            end
            -- The hidden copy here (the partner runs the enemy): its own animation = its local reaction to us.
            local hc = E.localActorFor(e.id)
            if hc then
                watchers[e.id] = watchers[e.id] or A.watcher()
                local ev = watchers[e.id]:update(hc, now)
                if ev and ev.path then note("h:" .. e.id, string.format("hidden copy of %s (hp here %s):", e.id, h), ev.path) end
            end
        end
        return false
    end)
end

-- keyprobe (solo): which keyboard/mouse keys Sifu binds to Guard / Parry / Dodge / Avoid.
local function keyProbe()
    U.poll("keyprobe", 1000, function()
        local pc = U.playerController()
        if not (U.valid(pc) and pc:IsA(StaticFindObject("/Script/Sifu.FightingPlayerController"))) then return false end
        local keys = { "LeftShift", "RightShift", "LeftControl", "LeftAlt", "SpaceBar", "Q", "E", "F", "R", "C", "V", "X",
            "Z", "Tab", "LeftMouseButton", "RightMouseButton", "MiddleMouseButton", "ThumbMouseButton", "ThumbMouseButton2" }
        local actions = { Guard = 6, Dodge = 7, Parry = 9, Avoid = 10 }
        for aName, aVal in pairs(actions) do
            local bound = {}
            for _, k in ipairs(keys) do
                local ok, yes = pcall(function() return pc:BPF_IsKeyBindedToInputAction({ KeyName = FName(k) }, aVal) end)
                if ok and yes then bound[#bound + 1] = k end
            end
            U.log("KEYPROBE %s: %s", aName, table.concat(bound, ", "))
        end
        return true
    end)
end

-- Lab console: <userdir>\cmd.lua is run once on the game thread when it appears (then deleted), its result logged
-- ("CMD: ..."). Lab systems only.
local function labConsole()
    if U.config.system == "0" or not U.config.userdir then return end
    local path = U.config.userdir .. "\\cmd.lua"
    U.poll("lab console", 1000, function()
        local f = io.open(path, "r")
        if not f then return false end
        local code = f:read("a")
        f:close()
        os.remove(path)
        local chunk, err = load(code, "cmd", "t", setmetatable({ U = U, T = T }, { __index = _G }))
        if not chunk then
            U.log("CMD: compile error: %s", tostring(err))
            return false
        end
        local res = table.pack(pcall(chunk))
        local parts = {}
        for i = 2, res.n do parts[#parts + 1] = tostring(res[i]) end
        U.log("CMD: %s %s", res[1] and "ok" or "ERROR", table.concat(parts, " | "))
        return false
    end)
end

function T.run(name)
    labConsole()
    labMonitor()
    syncWatch()
    if name == "arenago" then
        U.log("dev test arenago armed (%s)", U.config.role)
        arenaGo()
        return
    end
    if name == "arenakill" or name == "arenaretry" then
        U.log("dev test %s armed (%s)", name, U.config.role)
        arenaGo()
        arenaKill()
        if name == "arenaretry" then arenaRetry() end
        return
    end
    if name == "pauseprobe" then
        U.log("dev test pauseprobe armed (%s)", U.config.role)
        arenaGo()
        pauseProbe()
        return
    end
    if name == "factory" then
        U.log("dev test factory armed (%s)", U.config.role)
        arenaGo()
        spawnFactory()
        return
    end
    if name == "standinfight" then
        U.log("dev test standinfight armed (%s)", U.config.role)
        arenaGo()
        standInFight()
        return
    end
    if name == "spawnask" then
        U.log("dev test spawnask armed (%s)", U.config.role)
        arenaGo()
        spawnAsk()
        return
    end
    if name == "spawnprobe" then
        U.log("dev test spawnprobe armed (%s)", U.config.role)
        arenaGo()
        arenaKill()
        spawnProbe()
        return
    end
    if name == "arenawaves" then
        U.log("dev test arenawaves armed (%s)", U.config.role)
        arenaGo()
        arenaKill()
        arenaCrowd()
        return
    end
    if name == "arenacrowd" then
        U.log("dev test arenacrowd armed (%s)", U.config.role)
        arenaGo()
        arenaCrowd()
        return
    end
    if name == "arenaprobe" then
        U.log("dev test arenaprobe armed (%s)", U.config.role)
        arenaProbe()
        return
    end
    if name == "keyprobe" then
        U.log("dev test keyprobe armed")
        keyProbe()
        return
    end
    if name == "trainprobe" then
        U.log("dev test trainprobe armed")
        trainProbe()
        return
    end
    if name == "friendly" or name == "friendlyoff" or name == "friendlyfront" then
        U.log("dev test friendly armed (%s)", U.config.role)
        friendlyTest()
        return
    end
    if name == "aggro" then
        U.log("dev test aggro armed (%s)", U.config.role)
        approach()
        aggroTest()
        return
    end
    if name == "changetype" then
        U.log("dev test changetype armed (%s)", U.config.role)
        changeTypeTest()
        return
    end
    if name == "geartest" then
        U.log("dev test geartest armed (%s)", U.config.role)
        gearTest()
        return
    end
    if name == "reset" then
        U.log("dev test reset armed (%s)", U.config.role)
        resetTest()
        return
    end
    if name == "posesync" then
        U.log("dev test posesync armed")
        posesync()
        return
    end
    if name == "bonesprobe" then
        U.log("dev test bonesprobe armed")
        bonesprobe()
        return
    end
    if name == "twincompare" then
        U.log("dev test twincompare armed")
        twincompare()
        return
    end
    if name == "hitreplay" then
        U.log("dev test hitreplay armed")
        hitreplay()
        return
    end
    if name == "enemytwin" then
        U.log("dev test enemytwin armed")
        enemytwin()
        return
    end
    if name == "hittest" then
        U.log("dev test hittest armed")
        hittest()
        return
    end
    if name == "approach" then
        U.log("dev test approach armed (%s)", U.config.role)
        approach()
        return
    end
    if name == "tickdiag" then
        U.log("dev test tickdiag armed")
        tickdiag()
        return
    end
    if name == "singlenode" then
        U.log("dev test singlenode armed")
        singlenode()
        return
    end
    if name == "walkprobe2" then
        U.log("dev test walkprobe2 armed")
        walkprobe2()
        return
    end
    if name == "subprobe" then
        U.log("dev test subprobe armed")
        subprobe()
        return
    end
    if name == "walkprobe" then
        U.log("dev test walkprobe armed")
        walkprobe()
        return
    end
    if name == "animraw" then
        U.log("dev test animraw armed")
        animraw()
        return
    end
    if name == "g5" then
        U.log("dev test g5 armed (%s)", U.config.role)
        g5()
        return
    end
    if name == "animslot" then
        U.log("dev test animslot armed")
        animslot()
        return
    end
    if name == "replayrec" then
        U.log("dev test replayrec armed")
        replayrec()
        return
    end
    if name == "g3probe" then
        U.log("dev test g3probe armed (%s)", U.config.role)
        if U.config.role == "join" then g3probe() end
        return
    end
    if name == "g3" then
        U.log("dev test g3 armed (%s)", U.config.role)
        g3()
        return
    end
    if name == "training" then
        -- Single-system check of the Training Room entry path (no network).
        U.log("dev test training armed")
        U.poll("training test", 1000, function()
            local F = require("tc_flow")
            if F.currentMap and F.currentMap:find("Hideout", 1, true) and FindFirstOf("BP_Menu_Startup_C") then
                U.log("TRAINING test: entering from %s", F.currentMap)
                F.enterLocal("training")
                return true
            end
            return false
        end)
        return
    end
    if name == "g2" then
        U.log("dev test g2 armed (%s)", U.config.role)
        g2()
        return
    end
    if name == "clickdiag" then
        U.log("dev test clickdiag armed")
        clickdiag()
        return
    end
    if name == "retdiag" then
        U.log("dev test retdiag armed")
        retdiag()
        return
    end
    if name == "menudiag" then
        U.log("dev test menudiag armed")
        menudiag()
        return
    end
    if name == "g0" then
        U.log("dev test g0 (listen) armed")
        g0("listen")
    elseif name == "g0control" then
        U.log("dev test g0 control (no listen) armed")
        g0("")
    elseif name ~= "" then
        U.log("unknown dev test '%s'", name)
    end
end

return T
