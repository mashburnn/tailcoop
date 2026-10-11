# TailCoop: guide for agents working on this repo

TailCoop is a two-player online co-op mod for **Sifu** (PC), with a PvP mode. Two players connect over **Tailscale**.
- **Stack:** a UE4SS v3.0.1 Beta Lua mod plus a small native DLL (`TailCoopNative.dll`).
- **Why custom netcode:** Sifu's exe is a client-only build, with no listen server and no server-side replication
  (TESTLOG G0). So each PC runs its own world, and TailCoop keeps the two in step with its own UDP messages.

Read `README.md` for what players see.
- `TailCoop/TESTLOG.md` has every finding with its evidence: read the sections for the systems you touch.
- `docs/SIFU-MAP.md` is an early map of the game's classes. Some of its hypotheses were later proven wrong; the
  TESTLOG wins.

## You can't run the game here
- **Testing needs Windows and Sifu.** The mod can only be tested on Windows with Sifu installed. Testing happens in
  **the lab** on the maintainer's PC (see "Lab" below).
- **How to hand in work:**
  - Work on a branch and open a pull request.
  - Never push to `main`, tag, or create a release.
  - In the PR, write **what to test in the lab**: which `Lab\` script, and which log lines or screen to check.
- **What you can check without the game:**
  - Lua 5.4 syntax: `luac -p file.lua`.
  - That message formats match between sender and receiver.
  - That hooks and polls are registered from `start()`.
  - That new files are listed where they must be (see Rules).
- **Say what's unverified.** Don't claim a change works: say it's untested in the game.

## Rules
- **No game material in the repo.** That means:
  - no game files (exe, paks, assets);
  - nothing extracted or decoded from the game;
  - no reflection or SDK dumps;
  - no keys;
  - nothing about Steam or DRM files.
- **No personal data.** No Tailscale addresses (write `100.x.y.z`), computer names, user names or local paths.
- **Both players must run byte-identical scripts.**
  - The version check is FNV-1a over the files in `SCRIPT_FILES` (`tc_util.lua`). A new gameplay module goes in
    that list, and is started from `main.lua` with `U.try(...)`.
  - Any change makes the next release incompatible with the last one. That's expected: players update together.
  - The reference is the release zip. The repo stores LF, while the maintainer's working copy has some CRLF files.
    So a zip built from a fresh checkout can hash differently: don't hand players self-built zips.
- **Dev-only scripts.** `tc_devtests.lua` and `tc_trace.lua` never go into the player zip (`package.ps1` excludes
  them), and `main.lua` only loads them on lab systems (`system` ≠ 0).
- **No byte order mark** in Lua files: UE4SS won't start `main.lua` with one.
- **Keep diffs minimal:** no reformatting.

## Layout
| Path | What |
|---|---|
| `TailCoop/lua/Scripts/` | the mod (Lua, one module per system, `main.lua` starts them) |
| `TailCoop/cpp/` | `TailCoopNative.dll`: UDP transport (reliable + unreliable), Tailscale lookup, pose sync, ProcessEvent hooks/imported calls, an engine crash fix. `build.ps1` (VS 2022 Build Tools, Windows only) |
| `TailCoop/ue4ss-config/` | UE4SS settings tuned for Sifu; `VTableLayout.ini` (without it every Lua UFunction call does nothing) |
| `TailCoop/package.ps1` | builds `dist\TailCoop-<ver>.zip` (needs the UE4SS v3.0.1 Beta build in `Tools\UE4SS-experimental`, not in the repo) |
| `TailCoop/deploy.ps1` | installs the current scripts + DLL into both lab game copies |
| `TailCoop/TESTLOG.md` | test log: gates, bugs, causes, fixes, lab evidence |
| `Lab/` | lab automation (PowerShell) |
| `docs/` | design notes and plans |

## How the mod works (modules)
Each module is `local X = {}` and has `X.start()`, which registers polls and message handlers.
- **Polls:** `U.poll(label, ms, fn)` runs `fn` on the game thread until it returns true.
- **Messages:** `N.send(reliable, type, field, ...)`, received with `N.on(type, fn(fields))`. A message is text,
  `type|field|field`. Large text goes through `N.sendLarge`.
- **Handlers:** a handler that touches game objects runs through `U.onGameThread(label, fn)`.

| Module | Job |
|---|---|
| `tc_util` | config (`TailCoop.ini`, lab `launch.ini`), log, `U.try`, `U.poll`, `U.valid`, `U.playerController`, profiling, version hash |
| `tc_net` | Lua side of the native transport; message dispatch |
| `tc_session` | who hosts, who's connected, the mode (`training` / `arena` / `pvp`) and PvP map; the version/build handshake itself is native (`transport.cpp`) |
| `tc_menu` | the CO-OP entry in Sifu's title menu (host/join pages, lobby, PvP map list) |
| `tc_flow` | starts the session's mode in both games through Sifu's own menu functions |
| `tc_presence` | the partner's character in our world (spawn, 30 Hz snapshots, pause/down state) |
| `tc_timeline` | how far behind the partner's clock copies play (adaptive lag) |
| `tc_pose` | bone-exact copies: native pose stream onto a PoseableMesh the copy's mesh follows (master pose) |
| `tc_anim`, `tc_moves` | reading what Sifu plays on a character and playing it on another; the partner's actions |
| `tc_enemies` | shared enemies: identity (spawner + spawn order), ownership (each enemy's AI runs in one game, handed over between its actions), the other game's hidden copy + visual twin, health/kill sync, safety net, focus guard |
| `tc_aggro` | which player each enemy fights; hits forwarded between games (`phit`: the hit as Unreal text, replayed with `BPF_GenerateForeignImpact`), parry/dodge outcomes, no friendly fire |
| `tc_hits` | parsing/rewriting a hit's text form |
| `tc_turns` | enemies take turns attacking across both games |
| `tc_gear` | weapons held, thrown, dropped, picked up |
| `tc_training` | Training Room controls run in both games |
| `tc_arena` | Arena challenges: shared pick, Start, waves counter, results, Retry/Back, pause-menu navigation; PvP helpers (`stopWaves`, `showText`, `cameraOnPlayer`) |
| `tc_pvp` | PvP rules: empty arena, no dying (KO at health ≤ 1), rounds, first to 3, spots, score HUD |
| `tc_trace`, `tc_devtests` | lab only: gameplay trace; experiments selected with `-TailCoopTest=<name>`, and the lab console |

## Engine facts learned the hard way
Each of these cost a crash or a day. Details are in TESTLOG.

**Threads and objects**
- **Game thread only.** Loops run through `U.poll`, never `LoopAsync`: it runs Lua on another thread in the same
  state (UE4SS #1445), and silently stopped every loop after ~70 s. Game-thread work also waits 15 s after load.
- **`U.valid(obj)` before touching an object.**
  - UE4SS's own `IsValid` crashes on an object the engine already freed.
  - Lab probes that walk `FindAllOf("FightingCharacter")` must check it too: one that didn't crashed UE4SS.
- **Key tables by `obj:GetAddress()`.** UE4SS returns a new Lua wrapper per lookup, so the wrapper itself is not a
  stable key.
- **Hook parameters** are only valid inside the hook callback: resolve them before deferring work.
- **Never destroy characters mid-world.** That covers enemies, twins, stand-ins and the partner's copy: Sifu keeps
  pointers to them and crashes. Park or retire them instead.
- **Dead characters** go back to the Arena pool and return as new enemies. The pool is ~95 characters at the
  origin; pooled = `m_bIsPooled && !m_bPooledActorActive`.

**Engine quirks**
- **`StaticFindObject` on a path that doesn't exist** costs ~35 ms: cache lookups.
- **Hooking hot engine functions during startup** has crashed the game: register them from the game thread after
  startup.
- **Player controller:** `UEHelpers.GetPlayerController()` breaks in the Arena scene. Use `U.playerController()`.
- **Object full names** read `...:PersistentLevel.Name` (with a colon).
- **`UFunction` ParmsSize** has no trailing padding.
- **`BPF_IsKeyBindedToInputAction`** crashes for some actions.

**Animation and copies**
- **Sifu's anim graph ignores montages, velocity and input from outside.** Copies animate through the pose stream
  (or single-node `PlayAnimation`).
- **Never swap a real enemy's anim instance:** it crashes. Instead, the non-owner keeps a hidden real enemy plus a
  visual twin.
- **Twins have no bones of their own.** Anything of Sifu's that copies a pose from the target crashes on a twin
  (Focus: `UpdatePoseVitalPointsFX_PO`); the focus guard swaps in the hidden copy.

**AI and combat**
- **Auto-aim targets hidden characters.** Anything hidden but alive must be moved out of reach, or players spin in
  place.
- **Hidden copies** must give back attack tickets and leave combat, or Sifu stalls the whole fight.
- **Orders:** read them with `BPF_GetOrderComponent():BPF_GetRunningAndPendingActionOrders(false)` plus
  `BPF_GetOrderTypeFromOrderID`.
  - Victim order types: 9 TakedownVictim, 16 GrabVictim, 26, 35, 41.
  - 33 is StructureBroken.
  - A takedown by one player on an enemy the other game runs plays on our hidden copy. Its kill and damage are sent
    to the owner (`ekill` / `edmg`).
- **Health:**
  - `HealthComponent:BPF_SetCanDieByDamage(false)` lets health reach 0 without a death.
  - `BPF_ServerSetHealth` sets it.
  - The guard gauge goes up with `DefenseComponent:BPF_IncreaseGuardGauge` and down with `BPF_DecreaseGuardGauge`.
- **Enemy health bars:** `TargetableWidgetUpdaterComponent` on the player controller, `BPF_GetAssociatedWidget`.
  - A bar shows when the enemy is hurt; minibosses' bars always show (archetype `m_bForceTargetWidgetDisplay`).
  - Copies must carry the owner's archetype (`AIComponent.m_CurrentAIArchetype`).
- **A downed player:** Sifu holds that game's enemies still until a few seconds after the get-up.

**Pause, camera and HUD**
- **Pause:** UE4SS delayed actions keep running while Sifu is paused, and Sifu closes its pause menu if the game
  unpauses behind it. So a paused player counts as away instead of the game pausing.
- **Camera:**
  - It ignores `SetControlRotation`. Turn it with
    `Pawn.CameraComponentThird1:BPF_AddLookAt({m_eLookATType=1, m_vTargetPosition=..., ...}, {})`.
  - A challenge's intro is over when `PlayerCameraManager.ViewTarget.Target` is our own pawn
    (`AR.cameraOnPlayer`). Some intros run 11 s.
- **Arena HUD counter:** `BP_HUD_Arena_C.ProgressionCurrentNumber` / `TextBlock_Progression`. Its overlay
  `BP_Notif_ArenaNumberTransitionEffect` redraws the challenge's own numbers: collapse it when writing your own text.
- **Arena data:** `ArenaManagerBlueprintHelper:BPF_GetArenaSettings().m_ArenaBatches[i].m_ChallengesList`.
  - A wave objective without a timer (`m_bUseChrono`) never ends on its own.
  - The Stairs and Data Center start in a fixed rail camera, so they're not used for PvP.

**Fixed in the native DLL**
- **Loading crash:** Sifu's own async-loading race on the volumetric-lightmap registry, patched in `enginefix.cpp`.
  The log should say "4/4 applied".

## Lab (maintainer's Windows PC)
The working folder holds this repo plus folders that are not in it:
- `Sifu_Lab\`, `Sifu_Lab2\`: two copies of the game. System 1 hosts, System 2 joins, over 127.0.0.1.
- `LabData\Sys1|2\`: each game's profile folder, `TailCoop.log`, and `cmd.lua` (the lab console).
- `Tools\`: the UE4SS build and the GitHub CLI.

| Script | Use |
|---|---|
| `TailCoop\deploy.ps1` | copy scripts + DLL into both games (a running game keeps its old code: restart it) |
| `Lab\CoopAuto.ps1 -Mode training\|arena\|pvp [-Test name] [-Seconds n]` | start both games and a session end to end |
| `Lab\ArenaGo.ps1 -Batch b -Challenge c -Test arenakill -Play 240` | co-op Arena run with scripted kills |
| `Lab\Cmd.ps1 -System n -Lua '...'` | run Lua in a running game, prints `CMD:` result |
| `Lab\Press.ps1 -System n -Front -Key LMB,RMB,X` | posted input (gameplay keys need the window in front) |
| `Lab\Shot.ps1 -System n -Out x.png` | screenshot of a game window |
| `Lab\Run.ps1` | launch one system (used by the others) |

**Testing rules:**
- **Check screens, not just logs.** Verify with screenshots as well as log lines and counters.
- **Errors:** a run should show 0 `ERROR` lines in both logs.
- **Write it down:** record findings in `TESTLOG.md`, newest first, with the evidence.

Keys in game: light LMB, heavy RMB, takedown X, pick up E, throw R, guard Space, dodge LShift, Focus F.

## Release (maintainer only)
1. `.\TailCoop\package.ps1 -Version x.y.z` (`-NoBuild` when the DLL didn't change).
2. Commit and push.
3. `gh release create vx.y.z dist\TailCoop-x.y.z.zip`.

Both players must update.

## Open work
- **Takedowns on the partner's enemies** count in both games, but the owner's screen doesn't show the move. Grabs
  are untested.
- **Weapons:** enemies' throws and the bo staff's bend (the only weapon with bones) aren't mirrored.
- **Arena:**
  - randomizer challenges (each game rolls its own modifiers);
  - capture-point and target challenges (their counting assumes player 0);
  - kill bonuses (all go to the host);
  - team score in combat-points challenges.
- **"Bodies all over the place"** on the joiner (a real session with a Mac host): not reproduced in the lab. See
  TESTLOG, "Third real session".
- **Performance:** each game's mod time is in its log (`profile:` lines). It's ~35 ms/s in the lab's Arena run and
  up to ~65 ms/s in big fights; the target is ~30.
- **PvP:**
  - takedowns and grabs between players;
  - The Stairs and Data Center: they would need side-by-side spots and our own score widget.
- **Later gates:**
  - G9: Wuguan and travel between maps;
  - G10: story mode.
- **Mac / CrossOver packaging.**
