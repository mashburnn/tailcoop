# TailCoop test log

Gates from the development plan (G0-G11; the later ones are listed under "Open work" in CLAUDE.md). Every gate
must pass with System 1 hosting and with System 2 hosting before moving on. Newest sections come first, after G0-G4.
"The lab" is two copies of the game on one PC (System 1, System 2) - see CLAUDE.md.

## G0 - can this exe host a UE listen server? (2026-10-07) - DONE: NO
- Lua (after the VTableLayout fix): `GameplayStatics:OpenLevel(world, "/Game/Maps/TrainingRoom/TrainingRoom_Main", true, "listen")`.
- Result: TrainingRoom loads, world stays `IsStandalone=true`, `World.NetDriver = none`, and the game process
  owns **no UDP endpoint** (`Get-NetUDPEndpoint -OwningProcess`). Matches the static finding: the exe is a client-only
  build (`WindowsClient` platform name, `WITH_SERVER_CODE=0`). Co-op uses TailCoop's own netcode.

## Lua -> engine calls (2026-10-07) - FIXED
- Symptom: every UFunction call from Lua did nothing and returned 0/false/"" (`Add_IntInt(2,3)=0`), property
  reads/writes worked, hooks fired.
- Cause: UE4SS's built-in UObject vtable layout is one entry short for Sifu; it called the wrong virtual instead
  of `ProcessEvent` (real: vtable index 68, RVA 0x1E9B300).
- Fix: `ue4ss-config\VTableLayout.ini` (deployed to the UE4SS folder). Verified `Add_IntInt(2,3)=5`,
  `Concat_StrStr("a","b")="ab"`, `SetGlobalTimeDilation(0.5)` takes effect, UE4SS log `ProcessEvent address` = RVA 0x1E9B300.
- `TailCoopNative.dll` also checks the layout at load and logs it (`native\TailCoopNative.log`).

## G1 - instrumentation (in progress)
- Native order/guard/health RPC functions fire in single-player (e.g. `DefenseComponent:ServerRepSetGuardGaugeTarget`
  -> `MultiCastSetGuardGaugeTarget` with an int64 tick timestamp, `HealthComponent:BPF_ServerSetHealth(200)`).
- Still to do: a full combat trace (attack / block / parry / dodge / hit / takedown / death / shrine) in the Training Room.

## G2 - transport (2026-10-07) - PASS
- `TailCoopNative.dll`: UDP, reliable-ordered + unreliable channels, ping/RTT, 5 s timeout, handshake that rejects a
  different protocol / game build identity (exe timestamp + image size + pak size) / script version (FNV of the Lua files).
- Lua bridge: UE4SS exports its Lua wrapper (`RC::LuaMadeSimple::Lua`); the DLL links to it via `cpp\UE4SS.def` and
  registers `TailCoop_*` globals. No UE4SS source build or Epic account needed.
- Test: `Run.ps1 -System 1 -Role host -Test g2` + `Run.ps1 -System 2 -Role join -Test g2`. Each side sends 2000 reliable
  + an unreliable stream, then the joiner leaves and rejoins (round 2).
  - localhost: both rounds 2000/2000 in order, 0 resent, host returns to "hosting" when the partner leaves.
  - `-Sim 5,125,20` on both (5% loss, 125 ms each way, 20 ms jitter; RTT ~275 ms): both rounds PASS, 2000/2000 in order.
- Bugs found and fixed by the impaired run: RTO started at 200 ms (< RTT) -> RFC 6298 timer (1 s until the first
  sample); BYE went through the impairment queue and died with the socket -> sent directly; a host now accepts the same
  player reconnecting from a new port (was "session is full" until the old session timed out).
- Known: selective ack covers 32 messages past the cumulative ack, so a lost packet carrying many messages causes extra
  resends. Fine for gameplay rates; revisit if bandwidth matters.

## G2b - CO-OP title menu (2026-10-07) - PASS on both systems, keyboard
- `Lab\MenuSmoke.ps1 -System 1`: CO-OP sits between STORY and ARENAS with the game's own button style and focus
  highlight; keyboard Down/Enter/Backspace work; CO-OP > HOST GAME > TRAINING ROOM > lobby ("CANNOT HOST: NETWORK
  MODULE NOT INSTALLED" until G2) > Back x3 restores the full original menu. No crash.
- How clicks work: Sifu binds each title button's `m_OnClick` (button, bool) in the menu Blueprint. TailCoop binds
  its buttons' `m_OnClick` to `MenuBox:HasChild` (same parameter layout, no side effects) and hooks `HasChild`.
- Back: hook on the Blueprint override `BP_Menu_Startup_C:BPE_HandleNavigationBack` (the native declaration's hook
  never fires).
- System 2 also passes (an older System 2 window started before the click fix looked broken: deploy.ps1 now warns
  when a lab game is running stale code).
- Live lobby (`Lab\CoopMenuFlow.ps1`): System 1 CO-OP > HOST GAME > TRAINING ROOM shows "HOSTING TRAINING ROOM ON
  127.0.0.1:7777 / WAITING FOR PARTNER"; System 2 CO-OP > JOIN GAME lists online Tailscale devices + "JOIN THIS PC";
  after joining, host shows "PARTNER: SYSTEM 2 / START TRAINING ROOM", joiner shows "CONNECTED TO SYSTEM 1 / HOST
  PICKED TRAINING ROOM, WAITING FOR START".
- To do: mouse click and gamepad runs by hand; Tailscale-address run (needs a Windows Firewall allow for the game).

## Session start -> Free Training on both (2026-10-07) - PASS
- Host START sends `start|training`; both run the player's own path with the game's handlers:
  ARENAS (title menu `BtnArena` click event; if the story isn't finished the game asks "We advise that you complete
  the Story...", confirmed via the menu's `BPE_OnActionButtonPressed`, which calls `OpenArenaMenuMap`) ->
  `ArenaMode_Menu` -> `OpenTrainingRoom` -> Training Mode screen (`BP_Menu_TrainingModeSelection_C`) -> FREE TRAINING
  click event (widget `FreeTraining`). Both systems end in Free Training (screenshots `LabData\Sys1|2\flow_free.png`).
- Notes: calling `OpenTrainingRoom` from the story title scene only fades to black (it expects the Arena scene);
  Sifu's menus live in its own menu stack, so `IsInViewport()` is always false (use `IsVisible()`); FindFirstOf can
  return a Blueprint template (pick the instance that isn't `Default__` / has children).

## G3 - presence (2026-10-07) - PARTIAL: position + visibility PASS, animation/facing TODO
- `tc_presence.lua`: 30 Hz unreliable snapshots (map, activity, sender clock, position, yaw, velocity, pawn class);
  the receiver spawns a puppet of the same class (`GameplayStatics:BeginDeferredActorSpawnFromClass` +
  `FinishSpawningActor`, no collision, `MOVE_None`) and places it every 16 ms from snapshots interpolated 100 ms in
  the past (clock-offset estimate; extrapolates up to 200 ms on loss).
- Automated session (`Lab\CoopAuto.ps1`): `-Role host|join` makes the mod go through the CO-OP menu code itself; host
  auto-STARTs; both reach Free Training; each spawns the other's character.
- Bot test (`-Test g3`, System 2 walks a square via `AddMovementInput`): System 1's puppet traced the same path ~100 ms
  behind (e.g. -563 2305 -> -876 435), and ended where the bot ended. Screenshot `LabData\Sys1\g3_view.png`: the
  partner's character visible next to System 1's player.
- Not done yet:
  - The puppet slides in a neutral idle pose: Sifu's locomotion isn't velocity-driven (GetVelocity, the movement
    component's GetRealVelocity and m_vVelocity all read 0 while moving), so the animation needs Sifu's own animation
    state (G4: orders + PlayerAnim variables, the data Sifu's replay system records).
  - Facing: actor yaw is sent; correct for real input still to verify (the AddMovementInput bot never rotates).
  - Real input can't be injected into a background window: posted WASD reaches menus but not gameplay. Next real-input
    tests need a person on the keyboard/gamepad (or permission to drive the foreground window).
- Free Training runs inside the `ArenaMode_Menu` world (no map change): presence keys on an activity flag set by the
  flow after FREE TRAINING, so no puppet appears in title scenes.

## G4 - partner's moves (2026-10-08) - BUILT, needs a hands-on test
- Finding: attack/dodge starts never go through the order UFunctions in single player (a user session logged only
  `CancelOrderByID` RPCs); orders start in native code (`PlayOrder` RVA 0x18072C0; buffer-based replay entry
  RVA 0x191AC90 reached only via the MultiCastPlayOrder RPC). Instead of native order replay, TailCoop mirrors the
  animation, as the earlier SifuCoop attempt's log shows it did ("cosmetic sequence").
- `tc_anim.lua` + `tc_moves.lua`: the sender reads its `UPlayerAnim` (`m_AttackStruct`/`m_DodgeStruct` containers with
  `m_bInProgress1/2`, `m_animInfo1..4` with `m_bActionInProgress`) at 30 Hz and sends the playing action's sequence path,
  rate and cursor when it changes; the puppet plays it via `PlaySlotAnimationAsDynamicMontage` in `DefaultSlot`, started
  at cursor + measured one-way delay. Stance (`m_eMoveStatus`, combat/exploration) rides in the presence snapshot.
  The puppet also gets a velocity derived from its synced motion (Sifu's own velocity getters read 0 for players).
- Verified without input (`-Test animslot`): a test character switched into the fighting guard when the player's
  fighting-idle sequence was played on it through DefaultSlot (`LabData\Sys1\anim_step2.png`).
- Unknown until someone plays: whether every attack shows up in those structs, the walk animation from velocity, and
  mirrored moves (the dynamic montage can't mirror, so left/right-mirrored attacks show unmirrored).

## G4 rework - actions detected, mirrored, walking puppet (2026-10-08)
- Why the first hands-on run sent 0 actions: UE4SS's Lua doesn't see struct fields inherited from a parent struct
  (`m_AttackStruct` is FAnimStructAttack : FAnimStructBase : FSwapperStructBase, so `m_bInProgress*` /
  `m_AnimContainer*` read as nil), and `m_animInfo1..4` only exist on UAnimInstanceWithDependancy, not UPlayerAnim.
- Fix: `TailCoopNative 5` adds `TailCoop_Peek` (SEH-guarded raw read), `TailCoop_ObjectPath` (pointer -> asset path
  through UE4SS's exported `UObject::GetFullName`) and `TailCoop_PokeFloats`. `tc_anim.watcher` reads the swapper
  structs and UPlayerAnim's `m_LastActionAnim` (0xE68) / mirror (0xE70) / cursor ratio (0xE74) every frame.
  Enemies (`Wuguan_Grunt_AnimationBlueprint_Child_C`) are UPlayerAnim too, so the same reader serves G5.
- `-Test animraw` (solo): player and grunt readable, paths resolve, bad addresses return nil.
- Hands-on run: in practice actions arrive through `m_LastActionAnim` (attacks such as
  `MainChar_Attack_Man_Barehands_Pressure_Hook_BL`, every hit reaction, the dummy's `RollUppercut` and dash); the cursor
  is a 0..1 ratio that reads 0.00 at the start. 15 + 5 actions crossed, all played. Same move twice in a row is caught
  by the cursor jumping back.
- Most moves are mirrored (hit reactions 15/15). A dynamic montage can't mirror, so the puppet's mesh is reflected
  across its side axis (mesh yaw 90 -> scale X = -1) while a mirrored move plays; it stays until the next move.
- Walk/run: the anim's owner velocity equals `CharacterMovement.Velocity` (real player 165 -> 165). The puppet had 0
  because MOVE_None + no controller. Now: MOVE_Walking, `bRunPhysicsWithNoController`, no braking/friction, velocity
  written raw (0xD4) every frame. g3 run: puppet anim velocity follows. Players send their real velocity; enemy copies
  use motion-derived velocity (capped).
- Exit crash fixed: the transport `Session` is never destroyed (a joinable std::thread in a global destructor called
  std::terminate -> 0xC0000409 when the game closed).

## G4/G5 - copies really animate (2026-10-08, late) - PASS with automated real input
- User report after the rework: partner and enemies "just sliding with idle animation", no attacks or reactions.
- Measured (`-Test walkprobe2`, distance between the copy's feet): Sifu's anim graph ignores everything played from
  outside. Montages in any slot (its graph has no DefaultSlot; "Cinematic" exists but has no effect), Velocity /
  Acceleration writes, AddMovementInput, an AIController MoveTo: feet frozen while the body moves.
- Single-node playback works: `Mesh:PlayAnimation(seq, loop, false, false, false)` (Sifu's engine has a 5-argument
  version; with "keep script instance" = true no player is created and nothing plays, `-Test tickdiag`).
- `tc_anim` copy animator: actions play once at the sender's rate/start, then Sifu's own cycles take over by speed and
  direction (combat: 8-way Lockmove V1 cycles; exploration: V1 walk / V2 run / V3 sprint) or the V0 idle; mirrored
  moves flip the mesh. Partner puppet: stride range 57-109 cm/s while walking (was 0).
- Enemies: replacing a real enemy's anim instance CRASHES the game (null read at +0x630 in Sifu's order code). So on
  the joiner the real enemy stays (AI stopped, MOVE_None, placed from the host's snapshots, hidden every frame since
  Sifu re-shows it) and a visual twin of the same class with no AI controller (`AutoPossessAI = 0`) shows the host's
  enemy. Our hits still register on the hidden real enemy (`-Test hittest`: dummy reactions in every takeover phase),
  and its local hit reactions are shown on the twin at once (joiner sees its hits land).
- Real input in the lab: `Lab\Input.ps1` (SendInput to one lab window, cursor kept inside it, stops if it loses the
  foreground). Results:
  - System 2 combo / skill / guard / dodge: all detected (sub anim instances `GenericPlayAnimBP_C`, sequence at
    +0x630) and played on System 1's puppet.
  - System 1 combo on the dummy: 9 attacks + 16 dummy hit reactions crossed; screenshots of System 2 show the partner
    lunging and the dummy twin recoiling.
  - System 2 punching its dummy copy: 30 local hit reactions shown on the twin, no crash.
- Free Training dummies don't lose health, so "damage sent 0" there is expected.
- Not done: the host's real enemy doesn't react to the joiner's hits (needs a real hit on the host:
  `AFightingCharacter:Hitted(FHitDescription)` exists, but the 0x5A0-byte description holds process-local pointers);
  no blending between copy animations (pops between moves); enemies spawned later (Reset Situation) not mirrored.

## PvP: CO-OP > HOST GAME > PVP (2026-10-11, lab) - PASS
New mode (tc_pvp.lua): the two players fight on an Arena map, no enemies, rounds, first to 3.
- Entry: the host picks a map (one challenge per Arena map, batch/challenge in tc_pvp.MAPS); both games go to the
  Arena scene and travel to that challenge (AR.travel), the host presses Start in both once both are on its title
  screen. Each game stops the wave director (AR.stopWaves: refill off + current wave cancelled) and keeps every enemy
  away (E.putAway / E.keepAway, checked every second); no enemy is killed, so the objective never ends.
- No dying: our player can't die by damage; health <= 1 is a knockout (`pvp|ko`), the host scores and sends the round
  (`pvp|round`), both games reset 2 s later: orders cancelled, health and guard full, each player on their spot (150 /
  550 cm in front of the host's start), camera turned to the opponent (CameraComponentThird1 BPF_AddLookAt: Sifu's
  camera ignores the control rotation), 2 s invincible. At 3 points "YOU WIN" / "YOU LOSE" for 6 s, then 0-0 again.
- Hits: tc_aggro forwards our hit on the partner's character ("phit", id "player"), the other game applies it with
  its copy of us as the instigator (BPF_GenerateForeignImpact: their block/parry/dodge decides); friendly-fire blocks
  are off in PvP; the partner's character here is refilled after each hit (no structure break, no takedown prompt).
  Hits on a paused or downed player, or between rounds, are dropped.
- Lab (the user played the joiner for the hit spike, the rest automated): hits both ways, host 120 -> 0 -> KO -> round
  1; reset to spots with full health in both games; a full match 1-3 with the banners, then a new match at 0-0; HUD
  "0 - 0 | FIRST TO 3" (Sifu's number-transition overlay on the counter is collapsed: it drew "3 - 14" over our text);
  pause menu Retry restarts PvP in both games; objective never complete, death counter 0, 0 errors.
- Maps (one run each, both games: round 1 reached, players on their spots facing each other, no enemy in reach, HUD,
  0 errors): The Streets, The Pit, Rooftop, Wuguan, Snow Garden pass. The Stairs and Data Center dropped: their
  start area has a fixed rail camera (black bars, camera yaw -90 in both games) that turns both players the same way
  (both actors at yaw -90 after our reset: one can't see the other), and the HUD counter isn't shown there (Age/deaths
  instead). Their intros are also longer (11 s): "ready" now waits until the camera has been on our own player for
  1 s (AR.cameraOnPlayer; was a fixed 4 s, which reset the players mid-intro - the Data Center joiner ended 5.6 m
  off its spot). Co-op's joiner placement beside the host (150 cm) waits the same way.
- Lab probes that read every FightingCharacter must check U.valid first: one that didn't crashed UE4SS (lab only).
- Limits: no takedowns or grabs between players; a hit's reaction shows on the attacker's screen one round trip late
  (through the pose stream); Focus vital points on the partner are skipped (focus guard).

## Third real session (v0.1.2, joiner; host a MacBook): dying, weapons, bodies (2026-10-10) - 2 of 3 FIXED
TheRain challenge 5, ~6.5 min, failed with both out (joiner: death count 10, age 65). Connection fine (handshake 35 ms,
1 extrapolation in 194 checks); the v0.1.1 join attempt was refused by the version check, as meant. User: "a lot of
bugs", "bodies all over the place at the joiner side", "no weapon interaction, can't pick up dropped weapons".
- Dying: when a player goes down (health 0: Sifu's death, then the get-up) their game holds the enemies it runs still
  (movement off) - those fighting the partner too - and tc_turns forced them walking again (47 times, all in the
  seconds after a death); the partner's enemies' hits kept landing on the downed player ("our health 0 -> 0"). Fix:
  "down" is sent with the pause state (ppause field 2): the downed player counts as away (tc_aggro: their enemies go to
  the partner, nothing assigned to them), forwarded hits are dropped while down, tc_turns and the safety net leave
  the enemies alone; until 4 s after the health came back (Sifu still held one 3 s after the get-up in the lab).
  Lab: joiner set to 0 -> "our player is down", host "the partner is down", all 4 joiner-run enemies handed over
  within 3 s; host player's own deaths: 0 forced moves with the 4 s grace.
- Weapons: an enemy's pickup of a world weapon went through tc_gear's "the partner holds it: ours hidden" (setTaken),
  which also turned the hidden weapon's collision off. (a) A weapon our own copy of that enemy was about to pick up
  got hidden - our enemy then held a hidden bat; (b) a hidden weapon lying loose, or dropped when its holder died,
  fell through the floor (lab: bat 4.4/5.6 km down, pipe 1 km, stick 1.4 km); (c) a drop as an enemy died was never
  seen in the air by the throws scan (0 throws streamed in the user's session), so the partner's copy was never shown
  again. Fix (tc_gear): only loose weapons are hidden, and their collision stays on; one that turns up in a hand here
  is ours again; the owner tells where a weapon it let go of without a throw came to rest (1.2 s and 3 s after:
  "wrest"), the other game shows its copy there (detached from a dead holder, falling stopped); one no partner
  character holds any more is back after 4 s; a fallen one is put back where it was dropped (G.rescue). tc_enemies:
  our dead copy's weapons get collision before it dies and are shown, usable, after. Lab: bat dropped as the joiner's
  enemy died lies at the same spot in both games, visible and usable; final arenakill run (20 deaths each): every
  loose weapon fine in both games, 0 errors.
- Bodies: not reproduced. Lab body watch (every 3 s, both games): each body at the same place in both (within a few
  cm). Difference found: the non-owner's copy of a dead enemy (its twin) goes ~3.4 s after the death, the owner's body
  stays until the arena pool takes it - may look odd, not "all over". 50 handovers in 6.5 min in the user's session
  (lab: 15) - enemies changing hands can jump. Needs the user's description / the Mac host's log.

## Focus (F) crash, and missing enemy health bars on the joiner (2026-10-10, lab with the user playing) - FIXED
- "When I pressed F the game crashed" (joiner, lab): read of address 0 under PoseableMeshComponent
  CopyPoseFromSkeletalComponent. BP_FightingPlayer UpdatePoseVitalPointsFX_PO copies the pose of the focused enemy
  (FocusCurrentActorSelected.Mesh) onto the vital-points effect; on an enemy the partner runs that's our twin, whose
  mesh follows a master pose (tc_pose) and has no bones of its own. Fix (tc_enemies "focus guard"): hooks on
  SetFocusCurrentActorSelected and UpdatePoseVitalPointsFX_PO put our hidden copy of the enemy in its place (same
  spot, its own pose); any other character of ours with no pose of its own is skipped for that call. Lab: F held on a
  host-run enemy from the joiner - "our hidden copy of it is the target", focus attack played, its hits reached the
  host (60 -> 15), the takedown kill too ("ekill"), no crash.
- "I'm not able to see the health of certain enemies" (joiner): the joiner's copies of the host's later-wave enemies
  (sent out by a free level spawner, makeCopy) took that spawner's AI archetype (AIComponent m_CurrentAIArchetype): an
  arena miniboss came out with the servant/grunt archetype and its max health (330 on the host, 60/100 on the joiner),
  others swapped too (60 <-> 100). Health is copied from the host, so it sat at or over the copy's max: the bar counted
  it as full and stayed hidden, or showed the wrong fill; the minibosses' always-shown bar (archetype
  m_bForceTargetWidgetDisplay) was missing too - and the copy fought with the wrong archetype once the joiner ran it.
  Fix: "einfo" carries the owner's archetype path; the joiner puts the host's archetype and max health on its copy.
  Lab: 6/6 copies corrected ("now the host's ...", "had max health 60: now the host's 330"), both games agree on
  every enemy's max health, the joiner's bar on a copy shows the right fill when hit. (Bars only appear when an enemy
  is hurt or structure-damaged - Sifu's own rule; the minibosses' always-on bar after the fix not yet seen.)
- Lab note: a lab-console cmd.lua left from a crashed game ran in the next game at startup and crashed UE4SS:
  CoopAuto.ps1 now deletes them. Lifting enemies 50 m (lab isolate) makes the safety net kill them after 2 tries.

## Arena stuck at wave 3: a takedown on the partner's enemy (2026-10-10, second real session, v0.1.0) - FIXED
User (joiner) and friend (host), TheRain challenge 1: "killed all the enemies, stuck at wave 3, no enemy,
nothing to do". Both logs: the last enemy (BP_AIWaveSpawner5#1, health 21) stood at -489 -275 for 3.5 minutes,
never moved or acted in either game, passed back and forth between the games 8 times (every handover took the 3 s
limit: never quiet), invisible to both (the joiner stood 1 m from its spot). It started 4 s after the joiner's bat
takedown (ArmKey) on its hidden copy of it, while the host ran it; the host's copy knocked the joiner down mid-takedown
and the enemy was handed to the joiner at that moment.
- Lab repro (arena, joiner takedown on a host-run enemy via posted input, the other enemies lifted away): the takedown
  kills the HIDDEN COPY in the joiner's game (health 30 -> 0) - not a hit we capture, so the host's enemy lives on -
  and the health sync then set the dead copy back to the host's health a second later (a dead character revived).
  Handed to the joiner mid-takedown (order 9 TakedownVictim still running), it jumped 14 m in one frame. The exact
  frozen-out-of-sight end didn't reproduce in 3 runs; the chain to it did.
- Fix (tc_enemies): a copy dead here is never revived, its owner is told ("ekill") and kills its enemy the game's way;
  damage a synchronized move takes off our copy goes to the owner ("edmg"); an enemy isn't taken over while our copy
  is dead or in a victim order (9/16/26/35/41: given back), nor handed over while ours is in one (waits up to 15 s).
  Safety net: an enemy this game runs that's 6 m+ off both players' level and not moving for 3 s, or (Arena) in the
  fight before and frozen for 40 s, is put back (orders cancelled, shown, solid, walking, last good spot, AI
  restarted); still stuck after two tries, killed so the wave goes on.
- Lab after the fix (user playing the joiner in the lab, takedowns included): "our player finished X here ... the
  host's dies too" x3, host "our X died, partner told"; "X goes to the host once the takedown is over" x2; waves 4 ->
  3 -> 2 -> Last Wave -> challenge complete. Safety net only fired on enemies a lab script had lifted 50 m (put back
  twice, then killed - by design).
- Also reported: "the wave number at the top is incorrect sometimes and glitches" - the joiner's stopped wave
  director still starts a wave now and then and its HUD redraws its own count until the host's next counter message
  (up to 5 s). The joiner now puts the host's counter back every 250 ms. "The wait before a new wave is uncertain":
  the host's director sends wave enemies out a second apart; the joiner's copies came another ~1 s behind (the 800 ms
  wait for stand-ins) - now 150 ms for wave spawners' enemies. Lab scripts lifting enemies also stretched waves then.
- Lab notes: RustDesk's remote session blocks injected input (SendInput, `Lab\Input.ps1`); posted messages still reach
  a game in front (`Lab\Press.ps1 -Front -Key LMB,X`). Run.ps1 falls back to the main screen with no left monitor.

## First real two-PC session, and its bugs (2026-10-10, v0.1.0)
The user's own install joined a friend's PC over Tailscale: connected, Arena challenge
played together. Reported, and found in the joiner's log:
- **Challenge pick not shared.** The challenge list's TravelToArena hook failed at the title screen ("no UFunction with
  the specified name": the Blueprint class was already loaded there, its function not yet) and was dropped, never
  retried - the host's pick never reached the joiner (both picked the first challenge by hand). In the lab the class
  loaded later and the hook took. Now: hooks retried every second until they take, also by a live widget's own
  function name. And the host alone picks (user: "let the host control the rest of the menu"): the joiner gets no
  challenge list at all ("waiting for the host to pick a challenge") and follows the host's pick; a joiner's pick is
  ignored. Lab, both role assignments: the joiner travels to the host's pick and starts with it.
- **Thrown weapons invisible on the partner's screen.** Only the weapon in a hand was mirrored (meshes on the copy):
  a throw showed as the weapon vanishing from the hand and reappearing ~2 s later where it landed - no flight, no
  spin, no throw trail (FX_Throw particle on the weapon), a broken bottle stayed whole. Now every game watches the
  throwables of its world (AThrowableActor state: flying / dropped / bouncing) and streams one in the air ("wthrow",
  "wfly" 30 Hz, "wrest" at rest / broken / picked up); the other game flies its own copy (trail on, collision off)
  or a stand-in of the class for objects only one game has, then leaves it where it came to rest. Lab (Training
  Room, host throws a bo staff at the dummy): the joiner's frames show the staff flying from the host's copy and
  landing where it did on the host. Weapons' own skeletal animation: only the bo staff has bones (9, an anim
  blueprint); pipes, bats, machetes are rigid - not mirrored yet (the copy's staff stays in its reference pose).
- **Training Room "passive" enemies attacked** (user, playing the lab): the room's passive mode switches the enemies'
  attack tickets, reactions and defense off (BP_TrainingManager SetAIBehaviour); TailCoop's turn gate turned tickets
  back on every 2 s and its "nobody is attacking, send one at the player" fix pushed them into the fight. Both now
  respect tc_training.passive(): lab, 30 s with both players next to the dummy: 0 attacks, never sent into a fight.
- Lab: `BPF_IsKeyBindedToInputAction` crashes the game for some actions (null mapping); safe for 0 (light = LMB),
  3 (heavy = RMB), 96 (takedown = X), 98 (pick up = E), 99/100 (throw = R), 6/7/9/10.

## Arena finish: real copies instead of stand-ins, waves in step, pause, cost (2026-10-10)
- Same enemy in both games: the joiner's copy of a host enemy it doesn't have is now sent out the game's own way - a
  free level spawner of its own is moved to the host's enemy, given its class (BPF_SetSpawningClass), asked to spawn
  (BPF_WantsSpawn) and put back (lab -Test factory / spawnask: such an enemy is alerted and takes combat roles; one
  spawned from the class never did; wave spawners only answer their director; a spawner spawned at runtime sends
  nothing). The joiner can run those, so the host no longer keeps them.
  | `-Test arenawaves` (kills every 12 s), joiner | before | now |
  |---|---|---|
  | copies of host wave enemies | stand-ins (can't fight), 7-11 a run | 11-13 made by spawners, 0-1 stand-ins (fallback) |
  | stand-ins refused / kept by the host | yes | 0 |
  A copy whose class or position hadn't arrived yet was given up at once (enemy invisible on the joiner): retried
  5 times, a second apart.
- Waves in step: the joiner's own wave director is switched off (refill off from the start, a wave it starts anyway
  is cancelled): its random enemies were put aside and it advanced only as they died, so its HUD showed the first
  wave all challenge. Its HUD waves counter ("3 | Waves", "Last Wave": ProgressionCurrentNumber +
  TextBlock_Progression + ActualWave, drawn by the HUD's nativized code for its own director only) copies the host's.
  Replaying the host's HUD wave events instead moved the joiner's counter by its own count ("Last Wave" in wave 2).
  Frames: both HUDs "3 | Waves" at the same moment, then "Last Wave" on both; challenge complete on both.
- Pause: Sifu closes its pause menu when the game is unpaused behind it (9 ms after), so "no pause in co-op" can't be
  done that way. The mod DOES keep running in a paused game (loops, network: the earlier note that it stops was
  wrong), but that world is frozen: its player and the enemies it ran stood still on the partner's screen. Now each
  game reports its pause state ("ppause"); a paused player counts as away (tc_aggro: like a player who is out),
  enemies leave them and the ones their game ran are handed to the partner within ~3 s; back to normal on resume.
  Lab (Escape on one window for 10 s, each role): the Arena pause menu stays open on the paused game, the other game
  goes on fighting every enemy (frames).
- Pause menu Retry / Challenge selection / Main menu: hooked from the challenge's start (was: only "while paused",
  checked by a loop - never hooked).
- Cost: our own action tracks read 30 times a second instead of every frame (every frame for 400 ms after a hit on us,
  for the defense outcome); lab monitor's spin check on the two players only. Fight with 7-10 enemies: ~60-72 ->
  ~51-65 ms/s (lab, both games on one PC; the lab monitor is ~6-7 of that). Still above the 30 target: spread over
  many small items (enemy pose/snapshot/drive, partner copy, net pump).
- Lab windows now open on the left monitor (`Run.ps1 -Monitor main` for the old place).
- Regression: `-Test arenaretry` both role assignments (clear, Retry, clear, Back: all followed, 0 stand-ins, 24
  copies made by spawners), ArenaFight both ways: aimed at thin air 0, SPIN 0, errors 0.

## Players spinning in place right after a kill (2026-10-10, second cause) - FIXED
- User (playing System 2, the joiner, during a lab probe): "the character still spins sometimes". Lab monitor at
  06:07:56: our player turned 570 deg (body) in 1.5 s, moving 26 cm, mid-combo (Pressure Hook) - 4 s after the user's
  combo killed BP_AIWaveSpawner12#1, which on the joiner was a stand-in.
- Cause: when an enemy dies, its copies here stayed for the ~3.4 s the owner still reports the death. Stand-ins aren't
  killed (a dead character goes back into the arena pool and comes out again as a new enemy), so an alive, hidden
  stand-in stood under the body, and the body itself (the twin) is a live character to Sifu. The player's auto-aim
  took them: attacks went for the corpse's spot, the player turned in place there. The monitor had missed it: it
  counted a dead enemy's visible body as "something there" (fixed: aims at a dead enemy are counted on their own).
- Fix: at the death message the stand-in is lifted out of reach at once (no longer placed at the body), and the twin
  gets health 0 written straight into its health component (no death of its own; the owner's pose stream shows it).
  | `-Test arenakill` (each game kills an enemy it runs every 5 s, players idle among the enemies) | aim at a dead enemy (joiner) |
  |---|---|
  | before | 61 of 271 aim checks (22%), the hidden stand-in under the body |
  | stand-in lifted only | 11 / 21 log lines (System 1 / 2 hosting), now the body (twin) 1.3-4 m away |
  | stand-in lifted + body health 0 | 0 in all four logs (both role assignments), thin air 0 |
  Frames after kills: the body stays down; the challenge still completes on both.
- SPIN monitor now skips our own death and getting up (the body rolls over: seen at 06:12:57, health 8 -> 0).

## Players spinning in place, punching air (2026-10-10) - FIXED
- User (playing the left window): "they spin when I press buttons"; right window "spun for a couple of seconds until
  an enemy moved me". Cause: Sifu's player auto-aim (UAttackComponent BPF_GetTargetForInput) takes hidden characters.
  TailCoop left some hidden, alive, collision off where they stood: parked twins (an enemy's copy kept for reuse after
  a handover) and enemies the joiner put aside. Walking onto one's spot, the player attacked a target at its own feet
  (2-5 cm away) and turned in place, punching air, until a hit knocked them off the spot.
- `-Test` lab monitor "AIM" (what our light attack would aim at, every 200 ms; "thin air" = hidden with nothing
  visible within 80 cm), `Lab\ArenaFight.ps1 -Extra 'hidetargets = 0'` for the old behaviour:
  | | aimed at thin air (host / joiner) |
  |---|---|
  | before (hidetargets = 0) | 78 / 208 checks, parked twins 2-5 cm from the player |
  | targetable flag cleared (m_TargetLocation m_bIsValidTarget) | still aimed at: the auto-aim doesn't read it |
  | lifted out of reach (+200 m, like the partner's parked character) | 0 / 0, both role assignments |
- Crash found on the way (inside Sifu, read of a freed object): destroying an enemy's twin right after the enemy died
  (new "dead copy removed" step) while the player's aim/finisher pointed at it. Twins and stand-ins are never
  destroyed mid-world any more: retired (hidden, no collision, AI stopped, lifted out of reach, never an enemy again).
- Also found: a stand-in killed with its enemy went into the arena's pool and came back as a new live enemy only the
  joiner had. Stand-ins aren't killed now (their twin shows the death, then they're retired); the joiner's own
  put-aside enemy for that id is killed instead so its wave director counts the death.
- The lab monitor's level filter had been wrong (".PersistentLevel." - names read ":PersistentLevel."), so its
  GHOST/SPIN results before this round watched nothing; fixed, and SPIN now needs a 540 deg turn within 1.5 s while
  moving < 60 cm. Remaining SPIN lines in the last runs: an enemy's 540 kick, and the bot's own player mid-combo among
  visible enemies (Sifu turning between targets; the bot attacks without moving).

## Arena fights: crashes, ghosts, stuck fights, shared attack turns, cost (2026-10-09/10)
User reports while playing the lab: both games crashing; enemies standing like ghosts, lifeless, not on the other
screen; enemies not visible hitting the partner; characters stuck, spinning, attacks sped up; "make enemies take turns
and not congested". New lab tools: `-Test arenacrowd` (CROWD lines every 5 s: overlaps, attacks at once per player,
tickets, roles, split), a lab monitor in every co-op activity (GHOST: visible characters that shouldn't be; SPIN: a
full turn in place within 1.5 s), `Lab\ArenaCrowd.ps1`, `Lab\ArenaFight.ps1` (both players fight with real input,
alternating windows), `Lab\Burst.ps1` (12-frame contact sheets of both windows).
- Crash (both games, UE4SS reading a freed object): the joiner kept the world weapon it hid while the host's enemy held
  its own (a pipe); the pipe wore down and was replaced, the host's enemy let go, the joiner moved its long-gone pipe.
  Weapons kept by tc_gear are checked live first; enemy lists handed out (E.list, the joiner's roster) hold live actors
  only (a stand-in removed between two scans could be "put aside" -> same crash). 0 crashes in 12 runs since.
- Ghosts: (1) a dead enemy's copy on the host stood up again once the pose stream stopped (fell back to idle) - now
  removed 0.4 s after the owner stops reporting it, never re-created; (2) stand-ins the joiner spawned (other variant
  than the host's) can't fight - Sifu never takes them into combat (role None whatever they're told) - and were handed
  to the joiner to run: they stood idle on both screens. The joiner now hands those back at once and the host keeps
  them (they fight the joiner through its character there). (3) Handover loop: given an enemy whose only copy was the
  stand-in, the joiner's own other-variant copy replaced it, the stand-in was deleted, nothing ran the enemy (invisible
  on the joiner) and the host took it back / handed it over every 3 s, restarting its AI each time. Fixed.
- Stuck fights (nobody attacks for minutes, next wave never comes): hidden copies kept Sifu attack tickets and stayed
  registered as attackers of the local player (Sifu gave them the "direct opponent" places); now they give tickets back,
  perception off, checked every second (and stopped again if the game restarts their AI). Enemies demoted while held
  back are promoted (nearest made a direct opponent) when nobody has come for a player for 2 s; an enemy running here
  in nobody's fight is ordered at its target again.
- Lifeless after the partner's game crashed: every enemy was told to forget its target; now only those fighting the
  partner's character, and they turn on our player. Enemies started again after a session ends are aimed at us.
- Turns (`turns = shared` in TailCoop.ini, default; `each` = Sifu's own per player): while one player is attacked
  (ticket held or an attack animation under way, either game), the other player's enemies can't take a ticket; then
  they get 1.2 s priority. Enemies split evenly between players (cap = half, rounded up), changes of target kept rare
  (6 s hold, 40% closer, a hit switches at most every 4 s) - each change hands the enemy to the other game.
  | | before | now (ArenaFight, both role assignments) |
  |---|---|---|
  | both players attacked at the same moment | up to 44% of the time | 0-8% (overlap at hand-offs) |
  | split host/joiner | 0/6 for 2 minutes | 4/3, 3/4 |
  | attacks over a fight | one side only when stuck | 34/34, 29/36 (alternating ~50 times) |
- Cost (7-10 enemies alive): 76-82 ms/s -> ~46-58 ms/s; with few enemies ~34 ms/s. Owner reads actions with its 30 Hz
  snapshot (not every frame), hidden copies' actions read only after our hit, pose/mesh addresses cached, cheaper enemy
  scan, net pump without per-message allocations, profiling off outside the lab.
- Note on "spinning": the lab tests drive the players - arenacrowd leaves them idle while enemies beat them,
  ArenaFight spams attacks without moving (Sifu turns each attack toward another enemy) - which looks like a character
  stuck in place, turning, attacking fast. The SPIN monitor found no character turning in place in the last 8 runs.
- Open: stand-ins can't fight (the host keeps those enemies; the joiner's copies of them are visual + hit targets);
  syncing the wave's random variant choice would remove stand-ins altogether. Synchronized moves (takedowns, grabs)
  between a player and an enemy run in the other game are untested.

## G8 - co-op Arena challenges (2026-10-09) - PASS (A0-A7, both role assignments, two-PC-like run)
- A6 out & spectate (`.\Lab\ArenaOut.ps1`): Sifu ends a challenge natively at the death that passes the age limit
  (UStatsComponent m_iMaxAge 70) - clearing the game-over flag, raising m_iMaxAge or hooking DeathMenu
  BPF_IncrementAge (never called through ProcessEvent) all failed: "CHALLENGE FAILED" anyway. Working rule: a death
  ages the player by the new death count, so "last life" = age + deaths + 1 >= limit; on it, with the partner still
  in, HealthComponent BPF_SetCanDieByDamage(false), and the blow that would kill puts the player out instead.
  Result: joiner on its last life takes 1000 damage -> health 0.0001, "we sit it out": hidden, invincible, no input,
  camera on the host's character (screenshot: the host fighting, seen from the joiner's game); host: partner's
  character gone, every enemy now fights the host. Host then dies on its last life -> its own game over -> "both
  players are out" -> the joiner's challenge fails the same second; both show CHALLENGE FAILED.
Challenge used: batch 0 / challenge 0 = TheRain_CHAL01 "Night Call" (Survival, 4 waves, Age score).
- A0 probe (`.\Lab\ArenaProbe.ps1`): picking from Lua works (BPF_SetCurrentArena + game flow tags + BPF_GoToNextMap,
  as the list's TravelToArena does); the challenge's first group (7 spawners C1_*) is identical in both games;
  the arena keeps a pool of ~95 characters waiting at the origin; the first group waits until a player comes close;
  ServerSuicide on an enemy is counted by the wave director (OnSituationAIDeathDetected / OnAIDownDetected).
- A1/A2 (`.\Lab\ArenaGo.ps1`): the session's mode entry opens the challenge list on both; the host's pick (the list's
  own TravelToArena, hooked) takes the joiner to the same challenge; both reach the title screen the same second;
  Start on one presses it on the other (81 ms apart); the joiner stands 150 cm beside the host.
- A3 enemies: pooled characters are not enemies (ASCCharacter m_bIsPooled && !m_bPooledActorActive - not by place:
  live enemies crossed the origin and briefly reported it at the fight's start, which re-numbered them). A joiner
  enemy of another variant than the host's (waves pick a random archetype per spawn) is put aside for a stand-in of
  the host's class (was: pose "mismatch" thousands of times, wrong-looking twin); 0 mismatches since.
- A4 deaths (`-Test arenakill`, each game kills one enemy it runs every 5 s): "edead" both ways, the copy dies by
  ServerSuicide; both wave directors advance in step (wave on/4 -> 3 -> 2 -> 1 -> off -> next group, same second on
  both); the host's challenge completes (all 4 waves) from kills made in either game.
- A5 result: the host's objective complete -> "arena|end" -> the joiner's objective BPF_UnlockAchievement: both
  show CHALLENGE COMPLETE (host age 21, joiner age 20: an Age score stays each player's own), stars saved on both.
- A7 (`-Test arenaretry`): result screen and pause menu buttons hooked from a live instance by the function's own
  name (by class path: "no UFunction"); Retry -> both restart (the partner with BP_GameFlow_Library RestartMap, the
  way the button does it; a game whose own choice didn't leave the map within 4 s does the same), Start again on both,
  second clear, Back -> both in the Arena scene.
- Crashes found and fixed on the way:
  - Destroying the partner's character while enemies fight it (partner crashed / left) crashed the host (AI read
    at +0xb0; in the arena destroying a fighting player also took 1 s and crashed a minute later): it's now parked
    (enemies forget it, hidden, lifted away) and reused.
  - UE4SS's IsValid on an object the engine already freed crashes (read at 0xffffffffffffffff; Lua kept a destroyed
    stand-in in a list). TailCoopNative 12 adds TailCoop_Live: the object's index read under SEH and the engine's
    object array must still hold that address there; U.valid uses it (self-check at start: "liveness check ok").
  - Enemies whose game-side actor changed behind an id (pool, stand-ins) kept a stale animation watcher: rebuilt.
  - The host takes back an enemy the joiner ran once the joiner's reports stop for 3 s (left the map, crashed).
- Lab: `Lab\Cmd.ps1 -System N -Lua '...'` runs Lua in a running lab game (lab console); Run.ps1 records the game's
  real PID (it can restart itself) and CoopAuto stops any leftover lab game by its PID.
- System 2 hosting (`.\Lab\ArenaGo.ps1 -Test arenaretry -Swap`): clear, Retry on both, clear, Back on both - PASS.
  Found first: the joiner sent poses for its own put-aside enemy (another variant) under the same id as its stand-in
  (host: pose "mismatch" 22000, waves 3.5x slower); the owner tick now skips put-aside / wrong-variant enemies: 0.
- Two-PC-like run (`-Sim 2,40,15 -Skew 500000000`): waves in step, the host completes, the joiner's result follows,
  0 mismatches, copies ~60-70 ms past the fastest transit.
- Hitch fixed: every Arena enemy variant is its own class, and finding its Hitted override walked the class chain with
  StaticFindObject (~35 ms per level without it): 280 ms stalls at the start of the fight. tc_hits now takes the
  function from the object itself (the engine's own lookup); worst single call in the fight 5-10 ms.
- Cost: 55-75 ms/s of game thread while the most enemies are alive (training ~30): many enemies with pose
  capture/send/apply each. To optimize next.
- Open: randomizer modifiers (each game rolls its own), hardpoint/target challenges (counting assumes player 0),
  kill bonuses all go to the host's player, a team score for combat-points challenges, the pause menu pauses.

## Two-PC readiness: clock difference, Tailscale address without the CLI (2026-10-09) - PASS (lab)
- Found while preparing a run with a Mac (CrossOver): the adaptive playback lag was clamped to 0..400 ms, but the lag
  is "our clock - their clock", which between two PCs includes the uptime difference (any size). Lab games share one
  clock, so it never showed. Now limited to the fastest transit (clock difference + fastest path) + 0..400 ms, and the
  fastest transit is taken over the 4 s sample window, so two PCs' clocks drifting apart is followed.
- Lab check: `.\Lab\CoopAuto.ps1 -Test aggro -Skew 500000000` (the joiner's clock runs ~6 days ahead): copies
  45-52 ms past the fastest transit, out of data 0-0.6% of frames, 6 enemy hits crossed and applied - as unskewed.
- Hosting under Wine/CrossOver (no tailscale.exe): the host's address falls back to the adapter in 100.64.0.0/10
  (TailCoopNative 11 logs "platform=... tailnet-adapter=..."; here the same address `tailscale ip -4` gives).
  `peer = <address>` in TailCoop.ini adds JOIN <address> to the JOIN list when the tailnet can't be listed.

## No friendly fire (2026-10-09) - PASS
- User: "make it so my character doesn't attack my partner". Cause: Sifu's faction table (UFactionsManager
  m_FactionsTargetTable, GameInstance+0x3d0 -> +0x28, 6x6 bytes, row = attacker): players are TMP_Neutral (5,
  BP_TPSCharacter), enemies Faction2 (1, BP_AICharacter_Base) - the only factions set in the game's data - and neutral
  may target everyone including neutral, so the partner's character was a valid target (we turned to it and hit it).
- Two parts, both only while a session runs:
  - Targeting: the one entry neutral -> neutral is set to 0 (TailCoop_PokeU8), restored when the session ends.
    Enemies' rows are untouched (they still go for both players). Enough to stop locking onto the partner, not to stop
    a punch that physically reaches them: Sifu's hit detection doesn't ask the table.
  - Hits: TailCoopNative's ProcessEvent post-callback answers false for the partner's character's
    HitComponent:BPE_ValidateHit when the request's instigator (FHitRequest+0xE4 object index) is our player.
- `.\Lab\FriendlyTest.ps1 [-Off] [-Front]`, 16 attacks by the joiner:
  | case | setting | result |
  |---|---|---|
  | in front, facing the partner | Sifu's own | 9 of our hits landed on the partner |
  | beside, facing away | Sifu's own | turned to the partner (17 deg), lunged, hit it |
  | beside, facing away | ours | stayed off the partner, went for the dummy; 0 hits on the partner |
  | partner between us and the dummy | ours | 12 hits reached the partner, all 12 refused; 0 landed |
- Regression `-Test aggro`: enemies' hits on both players still cross (12 / 6, applied, 0 failures); `HitTest`: the
  joiner's punches still hit the dummy (16 hit reactions).

## Adaptive playback lag for copies (2026-10-09) - PASS
- User: "do you think latency coming from bone to bone copy?" Not the copy itself (capture / apply ~35 us each): the
  fixed 100 ms buffer every copy played behind, on top of the network.
- `tc_timeline.lua`: the lag follows what the connection needs. For each timed message from the partner ("p", and
  each enemy's "e"), how long after the previous one was stamped it became usable here (send interval + transit +
  jitter + loss in one number); the lag covers 95% of the last 4 s + 4 ms, rises at half speed, falls at 2% (never a
  visible jump). Partner and enemy copies (position and exact pose) all use it. Enemy position snapshots now go at
  30 Hz with their pose (same timestamp) instead of 20 Hz on their own.
- Lab switch to compare: `.\Lab\CoopAuto.ps1 -Buffer fixed` (old 100 ms). "timeline:" lines every 20 s. Both lab
  games share one clock (steady_clock), so "ms behind" is the real delay. `-Test aggro`, 2 runs each:
  | connection | buffer | copies behind | out of data |
  |---|---|---|---|
  | clean (lab) | fixed (old) | 100 ms | 0% of frames |
  | clean (lab) | adaptive | 45-48 ms | 0-0.2% of frames, longest 5 ms |
  | 2% loss, 40 +/- 15 ms | fixed (old) | 140-142 ms | 0-0.1%, longest 7 ms |
  | 2% loss, 40 +/- 15 ms | adaptive | 101-104 ms | 0.4-1.3%, longest 15-37 ms (lost packets) |
- Trade-off kept on purpose: with packet loss a copy holds its last pose for about a frame now and then (~1% of frames)
  instead of always playing 40 ms later. Raising PERCENTILE (0.95) covers loss too, at about +1 send interval of lag.

## Loading crash fixed, optimization round 3 (2026-10-09) - PASS
- Loading crash ("write to 0x8 at +1ea9871", 3 times, no mod code running yet): a race inside Sifu's engine, not ours.
  Sifu adds a global registry (TMap at 0x1458799b0, keyed by FPrecomputedVolumetricLightmap*) that the ULevel
  constructor fills on the async loading thread (`s.AsyncLoadingThreadEnabled=True`) while the game thread reads it in
  `ULevel::InitializeRenderingResources` -> `FPrecomputedVolumetricLightmap::AddToScene` and in a per-frame update,
  with no lock; a lookup that misses (-1) is then used as an index -> write at null+8. Fixed in TailCoopNative
  (`enginefix.cpp`): four one-byte jump patches skip the registry use (only on the exact 1.28 exe; each byte is checked
  first). Log: "engine fixes: volumetric lightmap registry 4/4 applied". Can also hit the unmodded game.
- Game-thread time spent by TailCoop (20 s windows, `-Test aggro`, one enemy changing hands 4 times):
  | | before (round 2) | now |
  |---|---|---|
  | System 1 (host) | 51.3 ms/s, worst call 36 ms | 31.6-33.7 ms/s, worst 2-4 ms |
  | System 2 (joiner) | 48.3 ms/s, worst call 36 ms | 29.7-30 ms/s, worst 2-4 ms |
  - Copies are placed by one native call (`TailCoop_Place`: K2_SetActorLocationAndRotation through ProcessEvent with
    the parameter block built in C++): 18 us per move instead of 100-130 us through UE4SS (most of it was converting
    the hit result back to Lua). A copy standing still isn't moved at all (re-placed every 250 ms).
    UE's ParmsSize has no trailing padding (0xAA here, not 0xAC): the first try refused every call and fell back.
  - Handover hitch (35-38 ms each time an enemy changed hands): not the twin spawn but `Hits.functionFor` -
    StaticFindObject on "<BP class>:Hitted" for every Blueprint level that doesn't declare it costs ~35 ms. Cached per
    class and looked up when the enemy first appears. Twins are also kept (hidden, poseable idle) when an enemy comes
    to us and reused when it goes back. Handovers now cost 3-5 ms.
  - Order sub-instances come from the mesh's own `LinkedInstances` (6 per character) instead of
    FindAllOf("PlayAnimSubAnimInstance") every 2 s (5-9 ms spikes).
  - Title-menu search (FindAllOf of the menu class, up to 17 ms) skipped while in a level; per-character held-weapon
    scan at most once a second; enemy action reads don't look up the anim instance every frame.
  - Profile report lists any section that took >= 10 ms once ("hitches:"), whatever its average.
- Copies no longer replay the enemy's own leftover action as "our hit" right after a takeover (0.5 s settle).
- Still to do: hidden real enemies are placed at 30 Hz through the same native call; the remaining cost is mostly
  UE4SS's per-call overhead (presence send ~210 us, action reads ~17 us each).

## Dynamic enemy ownership (2026-10-09) - PASS
- User: "left screen character sped up". Cause: `a.Budget.Enabled 0` (added for the frozen-enemy fix) turned the
  animation budget allocator off mid-game; budgeted meshes (every Sifu character) then got ticked twice. Removed; the
  per-mesh AlwaysTickPoseAndRefreshBones alone keeps off-screen senders animating.
- Ownership (`tc_enemies` handover section, `tc_aggro`): each enemy's AI runs in the game of the player it fights.
  The owner sends snapshots / exact pose (stream id "<enemy>@<role>": each game's clock is its own) / actions / gear;
  the other game follows with its hidden real copy (hit target) + twin. The host picks the target (nearer player,
  3 s stickiness, last player to hit it for 4 s) and ownership follows: the owner hands over once the enemy is quiet
  (no action for 300 ms, at most 3 s wait) with "eown|id|to|x|y|z|yaw|health"; the new owner's copy appears there with
  its AI restarted (BrainComponent:RestartLogic) and aimed (BPF_ForceEnemy). Hits on a follower copy go to the owner
  ("ehit"), the owner's enemy hits on the partner's character go to the partner ("phit") - both directions now.
- `-Test aggro`: dummy turns on the joiner -> "handed over to the joiner" / joiner "is ours now"; it then attacked the
  joiner in the joiner's game (24 attacks) and the joiner's parries staggered it for real (ParryPunish_..._parried on
  the dummy itself, 4x) - parries are local now, no replay needed. Host comes back and hits it (8 hits applied in the
  joiner's game) -> provoked -> handed back to the host. Joiner killed while owning it: host released its copy (AI
  running, visible) and the dummy went for the host.
- Room-control fix: the AIChangeBehaviour hook runs after the switch, so it sent the opposite state; now it sends the
  room's state a moment later (game-thread loop, not ExecuteWithDelay: that runs Lua on another thread).
- Crash found and fixed: the partner's character is hittable now, so Sifu's order code runs on it; when the pose
  stream stopped (partner disconnecting) the animation-copy fallback swapped its animation instance -> crash
  (null read at +0x630, as before with real enemies). Characters Sifu's combat code runs on are now protected
  (tc_anim.protect): only the exact pose drives them, otherwise Sifu's own animation.
- Seen twice, unexplained: a crash while System 1 is still loading (write to 0x8 at +1ea9871), before the mod does
  anything in game. Root-caused and fixed later the same day (see "Loading crash fixed").
- Not done: Sifu's AI director in each game only knows the enemies that game runs, so enemies run by different games
  don't take turns attacking (group fights can feel busier than single player).

## Room controls shared, rack weapons, frozen copies, parry feedback (2026-10-09)
- Frozen enemy (user: "enemy froze in some weird pose" while its hits kept landing): an enemy off the host's screen
  stops animating (VisibilityBasedAnimTickOption, update-rate optimization, animation budget allocator), so the host
  sent a frozen pose. Every character whose pose is sent now always ticks; `a.Budget.Enabled 0` on the sender.
- Training room controls (`tc_training.lua`, `-Test trainprobe` mapped keys: 1 = AIChangeBehaviour, 2 =
  ResetTrainingRoom, 3 + confirm = ChangeArchetypes(archetype, version, number)): hooked in both games and run in the
  other one too (no echo), so both spawn the same enemies and ids match. Real keys pressed on the joiner -> host did
  "behaviour active", "change 0 0 1", "reset"; no stand-ins needed. On the joiner, local enemy AI is held stopped
  during a session (as soon as seen, and for 2 s after any room action, which restarts it).
- Rack weapons: the held-weapon description carries its world identity (training rack name, or level-placed actor
  name); the other game hides its copy while the partner holds it and, when they let go, puts it where theirs came
  to rest. Test: joiner logged "our spawner:BP_WeaponSpawner2 is in the partner's hands: hidden" ... "is back"; the
  joiner's screen shows only the partner's machete meanwhile.
- Guard keys (`-Test keyprobe`, BPF_IsKeyBindedToInputAction): Guard / Parry / Avoid = SpaceBar, Dodge = LeftShift.
  With the dummy attacking the joiner: joiner's blocks (Guard_Hitted) and parries (ParryDeflect, its copy of the
  dummy plays ParryPunish_..._parried) work locally, and are reported to the host ("pout").
- Parry on the host: the hit is replayed on the joiner's character with its DefenseComponent in guard type Deflect
  (EGuardType 2; auto-deflect alone did nothing) -> 2 of 7 replays gave the real ParryVictim stagger on the host's
  dummy; the rest arrive ~125 ms after the hit, when the dummy is already in its next attack and Sifu ignores a parry
  of the previous one. Partial: the real fix is per-enemy ownership (the AI runs on the machine of the player it fights).

## Optimized pose sync, weapons, host-owned enemy roster, enemies fight both players (2026-10-09) - PASS
- Pose deltas (TailCoopNative 7, wire 'Q'): only bones whose packed rotation changed (> 1 quantization step) are sent,
  with a keyframe every 15 poses (~0.5 s) that repairs anything a lost packet left stale; late packets are dropped.
  ~65 of 232-239 bones per pose: ~470 bytes instead of ~1150 (host with player + 1 enemy: ~15 KB/s, was ~70).
- Fixed: in master-pose mode the hidden poseable sometimes didn't refresh its bones (40-86 cm spikes);
  `VisibilityBasedAnimTickOption = AlwaysTickPoseAndRefreshBones` on it -> 0.4-0.9 cm average, <= 2.4 cm max.
- Weapons (`tc_gear.lua`): the holder describes held ABaseWeapon actors (attach parent = the character) as their
  visible meshes + placement relative to the hand socket ("gear" message on change, every 3 s again); the copy gets
  plain mesh components on the same socket (no weapon actor: no pickups/AI/physics), following the exact pose.
  Changes compared with a tolerance (1 cm / 0.01 quat) - exact-string comparison rebuilt the copy's weapon ~4x/s
  and it never showed. Test `-Test geartest`: host picks up the training machete -> joiner sees it in the host's
  right hand (screenshot), drop -> gone. Enemies' weapons use the same path (twin gets them, hidden real enemy's hidden).
- Host decides which enemies exist (`tc_enemies`): a host enemy the joiner lacks gets a stand-in (a real enemy of the
  same class spawned on the joiner, then hidden + driven like the others, so the joiner's hits still land); a joiner
  enemy the host doesn't have is put aside (hidden, AI off, no collision) until the session ends. `-Test changetype`
  (host calls BP_TrainingManager:ChangeArchetypes, 2 BigGuys): joiner spawned 2 stand-ins, put its grunt aside, both
  screens show the same two BigGuys.
- Enemies fight both players (`tc_aggro.lua`, G6): on the host the joiner's character is hittable and each enemy
  is pointed at a player with UAIFightingComponent:BPF_ForceEnemy (nearer one, 3 s stickiness, 30% margin; an enemy
  the joiner hits turns on the joiner for 4 s). An enemy's hit on that character (captured Hitted) is forwarded and
  applied to the joiner's real player through its own hit pipeline 100 ms later (when the copy visibly connects).
  `-Test aggro`: dummy turned on the joiner; 14 hits forwarded, 14 applied, 0 failed; joiner shows hit reactions and
  its structure gauge fills (Free Training doesn't take health).
- Packaging bug found: PowerShell wrote a UTF-8 BOM into main.lua and UE4SS then didn't start the mod at all
  (required modules tolerate it). deploy.ps1 now strips BOMs.
- Still open: the joiner's block/parry/dodge outcome isn't fed back to the host's enemy (it isn't staggered by a
  parry); a weapon the host takes from a rack still shows on the joiner's rack; the joiner's own training-menu
  actions (Change enemy type / Reset) aren't forwarded to the host.

## Bone-exact copies (2026-10-09) - PASS
- User: copies "don't appear the exact same, stances are flipped"; asked for a sync "exact same to the bone".
- Stance first: UPlayerAnim::m_eAnimQuadrant (0x930, FrontLeft/FrontRight/...) picks one of four combat idles
  (m_IdleAnimContainerFL/FR/BR/BL; for grunts one sequence, FR/BL mirrored). The animation copy now sends it and uses
  the matching idle (+ mirrored 8-way cycles for right-foot-forward stances); hand positions matched (-Test twincompare).
- Then full pose sync (TailCoopNative 7, `cpp/src/pose.*`, `tc_pose.lua`): the owner calls
  SkeletalMeshComponent:SnapshotPose (local transform of every bone) 30x/s and sends rotations as smallest-three
  quaternions (4 bytes/bone) + translations only where they differ from the reference pose; IK/camera/VFX helpers
  skipped (grunt 232 of 249 bones, player 239 of 273). Parts sized to the 1100-byte message limit (2 per pose, ~1.15 KB,
  ~35 KB/s per character); a skeleton hash guards against different meshes. The receiver interpolates on the 100 ms
  timeline and applies with Sifu's PoseableMeshComponent:ApplyPoseFromSnapshot on a poseable added to the copy; the
  copy's own mesh follows it (SetMasterPoseComponent), so Sifu's materials stay. No pose for 0.5 s -> animation copy.
- `-Test posesync` (solo, full encode/decode path): bone error 0.4 cm average, <= 2.5 cm max during fast moves, both
  with master pose and with the poseable shown directly; 3256 poses, 0 errors.
- Co-op: partner puppets and enemy twins on both systems "show the owner's exact pose"; 5% loss + 100 ms: ~98% of
  poses complete, no flapping. The joiner's own hits still show instantly (the twin leaves the pose stream for the
  length of the local reaction, then rejoins).
- Edge cases run: roles swapped (System 2 hosting) - hits 53/53 applied; 5% loss / 100 ms / 20 ms jitter - hits applied,
  poses OK; host killed mid-session - joiner times out after 5 s, puppet removed, its enemy visible again with AI
  running, no crash; host Reset Situation - same enemy repositioned, identical pose on both screens; closing both games
  normally mid-session - no crash.
- Gaps found: a weapon the host picks up (staff) doesn't appear on the joiner's copy of them; "Change enemy type"
  (new enemies) not mirrored yet.

## G5 - joiner's hits reach the host's enemy (2026-10-09) - PASS (confirmed by the user on both screens)
- User report: the joiner hits the enemy, the host's enemy doesn't react; the joiner's enemy reacts in slow motion.
- Hit path found with `-Test hitreplay` (solo): `FightingCharacter:Hitted(FHitDescription)` fires on every hit but
  is only a notification (replaying it changes nothing). `HitComponent:BPF_GenerateForeignImpact(FHitResult,
  FHitRequest)` called on the VICTIM's HitComponent runs Sifu's whole hit pipeline: the dummy reacted to a replayed
  hit with nobody pressing anything (on the attacker's HitComponent: nothing).
- TailCoopNative 6: a ProcessEvent pre-callback (UE4SS export) captures watched calls and exports their first
  parameter as Unreal text (`PPF_IncludeTransient`: all FHitDescription members are Transient, export was "()"
  without it); `TailCoop_CallImported` imports text into parameters and calls through ProcessEvent. Parameters are
  built/destroyed through FProperty::InitializeValue/DestroyValue (UStruct::InitializeStruct is a UObject-side
  virtual, shifted in Sifu: crashed, caught).
- Co-op: the joiner watches Hitted on its hidden real enemies, replaces its character's and the enemy's paths with
  $I$ / $T$, sends the ~4.7 KB text in pieces (`tc_net.sendLarge`); the host puts in the partner's puppet and its
  real enemy and calls BPF_GenerateForeignImpact. The host's own defense/AI decides the outcome; the old "edmg"
  damage report is gone (would double the damage).
- Result: every joiner hit "applied, 0 warnings" on the host; the host's enemy reacts; user confirmed both screens.
- Slow motion: hit reactions start at play rate 0.20 (Sifu's hit-freeze) and speed up after ~0.1 s; the copy played
  the whole reaction at 0.20. Starting rates < 0.5 now play at 1.0 (twin `playRate 1.00` after the fix). Same fix
  covers the partner puppet's hit reactions.
- The host's version of a reaction to the joiner's own hit is skipped for 0.7 s (the joiner already shows its local
  one; restarting it stuttered).

## G5 - shared enemies (2026-10-08) - PASS for identity, position and health; hands-on test pending
- `tc_enemies.lua`: enemy id = spawner name + spawn order (`BP_AISpawner_Grunt_Base_1#1` on both systems for the
  training dummy). Host sends 20 Hz snapshots + action animations; the joiner stops its copy's behaviour tree, turns
  off its movement physics, places it from the host's data, plays the host's actions on it, and keeps its health equal
  to the host's. Damage the joiner deals to its copy is reported and applied to the host's enemy.
- `-Test g5`: joiner -25 on its copy -> host "partner hit ... 144 -> 119"; host -10 -> joiner's copy 119 -> 109.
  Both ended at 109.
- `BPF_ApplyDamage` does nothing on the training dummy; the host falls back to `BPF_ServerAddHealth(-amount)`.
- Not yet: the AI only ever targets the host's player (G6); enemies the host spawns later (Reset Situation / Change
  enemy type) have no copy on the joiner yet (logged as "host has X but this game doesn't").

## Threading (2026-10-07) - FIXED
- One system's mod went silent ~70 s into a session (all loops stopped, game still fine). UE4SS runs `LoopAsync` on a
  second OS thread in the same Lua state as game-thread hooks, without a shared lock (UE4SS issue #1445).
- All TailCoop loops now use `LoopInGameThreadWithDelay` / `LoopInGameThreadAfterFrames` (game thread only; the
  network pump runs every frame). A 150 s session afterwards ran to the end on both systems.

## Stability notes
- `UEHelpers.GetPlayerController()` breaks in Sifu's Arena scene (a Blueprint controller has a number variable named
  `IsPlayerController`): TailCoop finds the controller whose `Player` is set instead.
- Registering hooks on hot engine functions (e.g. `PanelWidget:HasChild`, `KismetMathLibrary:Add_IntInt`) during
  the first seconds of startup has crashed the game twice; TailCoop registers those from the game thread after
  startup. Game-thread work also waits 15 s after mod load.
- Hook parameters (`ctx:get()`, params) are only valid inside the hook callback; resolve them before deferring work.
- UE4SS returns a new Lua wrapper per object lookup: key tables by `:GetAddress()`, never by the wrapper.
