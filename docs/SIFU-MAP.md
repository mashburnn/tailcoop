# Sifu inner-workings map (for a symmetric Tailscale co-op mod)

> Early notes (2026-10-06/07), written while decoding the game. Paths below (`reflection\`, `index\`, `logic\`,
> `ghidra\`, `config\`, `build.hashes.txt`) point to a local extraction of the game that is **not** in this repo and must
> never be added (game material). Some hypotheses here were later proven wrong - notably the listen server: the exe
> is client-only (TESTLOG G0). UE4SS can regenerate the header dumps from a running game (its `DumpCXXHeaders` /
> UHT dump keybinds).

Build: Sifu 1.28 (`DefaultGame.ini [Version]`), UE 4.26 Shipping, one pak (V11, AES, 79,246 files).
Both PCs must run the same game build: the native handshake compares exe timestamp, image size and pak size.

**Headline (corrected):** Sifu is built on Sloclap's **SCCore** framework, inherited from **Absolver** (an online
game), so the C++ classes still declare replicated properties and Server/Client/Multicast RPCs. **But the
shipping exe is a client-only build** (`WITH_SERVER_CODE=0`): its platform name is `WindowsClient` (the string
`WindowsNoEditor` is absent) and Saved\Config is `WindowsClient`. UE's listen server and server-side actor
replication are compiled out, so the replication metadata most likely only serves the **replay recorder**
(`SCDemoNetDriver`). Co-op therefore needs **custom netcode** (each PC runs its own world, synced over UDP).
The replication metadata is still useful: it shows which state the developers considered essential to
reproduce a fight (orders with `FBuffer` payloads + tick times, guard, health, age, anim state).
The **Blueprint layer was written single-player**: 166 Blueprints look up "the player" by index, and only one
checks authority.

## Where things are
| What | Where |
|---|---|
| Native class API (UHT headers, flags incl. Replicated/Server/Client/NetMulticast) | `reflection\UHTHeaderDump\{Sifu,SCCore,...}\Public\*.h` |
| Same as compilable-ish SDK with offsets | `reflection\CXXHeaderDump\` |
| Every live object + native thunk RVA (`[f: rva]`) | `reflection\ObjectDump.txt` |
| Lua type stubs for UE4SS mods | `reflection\LuaTypes\` |
| Class index (class, parent, module, #Replicated, #RPC) | `index\classes.tsv` (1,247 classes) |
| Blueprints/DataTables/BTs as JSON (Kismet bytecode included) | `logic\Sifu\Content\...` |
| Which assets were treated as logic | `index\logic_assets.tsv` |
| Blueprints calling player lookups / authority checks | `index\player_lookups.tsv` |
| Configs (DefaultEngine/Game/Input/WuguanAI/Save/Replay...) | `config\` |
| Native exe with UE4SS thunk names (`exec_<Pkg>_<Class>_<Func>`) | `ghidra\` project `Sifu` |
| Mappings for FModel/UAssetGUI/kismet-analyzer | `reflection\Mappings.usmap` |

## Game framework (who spawns what)
- **GameInstance** `ThePlainesGameInstanceBP_C` : `UThePlainesGameInstance` : `USCGameInstance`.
  Owns `m_sessionManager` (`USCSessionManager`) and `m_SessionTimeManager`. Map flow: `TravelToNextMap`,
  `TravelToLoadedMap`, `LoadMapAsync`, `GoToMapInGameFlow`, and the `UWGGameFlow*` graph classes.
- **GameMode** `DefaultGameMode_C` : `AThePlainesGameMode` : `ASCGameMode` : `AGameMode` (match-based, not GameModeBase).
  CDO: `DefaultPawnClass=BP_FightingPlayer_C`, `PlayerControllerClass=FightingPlayerControllerBP_C`,
  `GameStateClass=BP_ThePlainesGameState_C`, `HUDClass=SCHUD`, `SpectatorClass=SCSpectatorPawn`,
  `m_ForcedPlayerStart=SpawnServer`, `MinRespawnDelay=5`. `AThePlainesGameMode::BPF_GetPlayers()` returns
  every PlayerController (already multi-player-shaped). `AArenaGameMode` is a subclass for Arena maps.
- **GameState** `BP_ThePlainesGameState_C` : `AThePlainesGameState` (6 Replicated + 1 RepNotify).
- **PlayerController** `FightingPlayerControllerBP_C` : `AFightingPlayerController` : `ASCPlayerController` : `ASCBasePlayerController`.
- **PlayerState** `AFightingPlayerState` (replicated; `BroadcastDeath` multicast, `InformAboutKill` client RPC).
- **Pawn** `BP_FightingPlayer_C` : `BP_TPSCharacter_C` : `AFightingCharacter` : `ABaseCharacter` : `ASCCharacter` : `ACharacter`.
  Components: `PlayerFighting` (UPlayerFightingComponent), `Attack` (BPAttackComponent), `BPStatsComponent`
  (MainChar stats), `CameraComponentThird1`, `ASMPlayer`, `InteractionDetection`, `ScoringComponent`,
  `MCDialogComponent`, `OptionListener`. Has a `Server Teleport` reliable server RPC and OnRep vars
  (attached props, rain/snow/ashes FX).
- **Local player / viewport:** `USCLocalPlayer`, `USCGameViewportClient`. Split-screen is off
  (`bUseSplitscreen=False`) but supported by the engine.

## Networking in the binary (client-only build: listen server unavailable)
- `GameNetDriver` = `OnlineSubsystemSteam.SteamNetDriver`, fallback `OnlineSubsystemUtils.IpNetDriver`
  (DefaultEngine.ini). Client-side connect code exists, but there is no server code to host. The co-op mod
  (TailCoop) uses its own UDP transport over Tailscale instead.
  `DefaultPlatformService=Steam`, and the OnlineSubsystemRedpointEOS plugin is present. The co-op mod must not depend on either.
- `DemoNetDriver` = `/Script/Sifu.SCDemoNetDriver` (replay system; same replication paths are used for replays,
  which is why many components are replication-ready).
- `GameNetworkManager`: distance-based relevancy on. IpNetDriver client rates 20000.
- **Time sync:** `AFightingPlayerController::ServerRequestTimeSync / ClientRequestTimeSync` (+ "First" variants).
  The order system timestamps attacks with `int64` ticks, so it relies on this server clock.
- **Absolver co-op leftovers:** `USocialComponent` (12 Server, 5 Client, 8 Multicast RPCs: `ServerApplyCoop`,
  `MulticastStopCoop`, `ServerPrepareForCoopMatchMaking`, relationship changes...), `USocialManager`
  (`m_NbNeededPlayersPerGameMode[3]`, `m_NbMaxPlayersPerGameMode[3]`), `FCoopGroup`
  (`ServerSendLocalCoopGroup`, `ClientSendNewCoopGroup`...), `EGameModeTypes {Mode1v1, Mode3v3, ModePVEMine}`.
  These are worth probing, but probably only partly wired up in Sifu.

## Replication readiness (native layer)
Counts are from UHT headers (`Rep` = Replicated/ReplicatedUsing UPROPERTYs). Full list: `index\classes.tsv`.

| System | Class | Rep | RPCs | Notes |
|---|---|---|---|---|
| Character core | `AFightingCharacter` | 6 | 5 Server, 5 Multicast | faction, weapon pull-out, effects add/remove (tick-stamped), ragdoll, suicide |
| Base character | `ASCCharacter` (SCCore) | 5 | `ServerSetGender` | |
| Movement | `UFightingMovementComponent` | - | `ServerPopDesyncFromServer` | has a desync/resync path |
| Attacks / moves ("orders") | `UOrderComponent` | - | 5 Server, 6 Multicast, 1 Client | **the combat pipeline**: Play/Cancel/Update order, `ClientPlayOrderRejected`; payload `FBuffer` + caller net id |
| Attack targeting | `UAttackComponent` | 3 | `ServerSetTarget`, `MulticastOrderAttackTrackingOver` | |
| Guard / defense | `UDefenseComponent` | 5 | 2 Server, 1 Multicast, 1 Client | guard gauge target w/ time; `ClientNotifyIsTargettedByAttack` |
| Health | `UHealthComponent`, `UCharacterHealthComponent` | 1 / 5 | 3 Server | `BPF_ServerSetHealth/AddHealth` |
| Player fighting | `UPlayerFightingComponent` | 10 | `BPF_ServerSetIsInDialog` | |
| Stats (GAS) | `UCharacterStatAttributeSet` | 4 | - | **Age** and **DeathCounter** are `ReplicatedUsing` GAS attributes |
| Animation | `UPlayerAnim` (84 rep), `UAnimInstanceWithDependancy` (14), `UAnimInstanceReplicationComponent`, `ULevelSequenceAnimReplicationComponent`, `UPlayAnimSubAnimInstance` | many | - | animation state is heavily replicated |
| AI fighting | `UAIFightingComponent` | 6 | - | idle index, phase scenario + node index, carried props |
| AI base | `UAIComponent` | 2 | - | spawner ref |
| Destructibles / physics props | `UReplayable*Component`, `ALockableDoor`, `AKeyPass`, `ASpawnerGroup` | yes | - | |
| Player state | `AFightingPlayerState` | 7 | Client + Multicast | kill/death broadcast |
| Game state | `AThePlainesGameState` | 7 | - | |
| Camera | `UCameraComponentThird` | 1 | - | per local player |

**Not replicated (host-only by default, so needs work):** `AAIDirectorActor`, `AAISpawner`/`AAIWaveSpawner`/
`AAIWaveRefillDirector` (encounter spawning), `UGameFlow*` (map progression), the save system
(`USCSaveGameComponent`, `USCSaveObject*`), `UInputManager`, `UCinematicManager`/level sequences
(only `UInGameSequenceReplication` and `ULevelSequenceAnimReplicationComponent` exist), most UI.

## AI and targeting (two players vs the same enemies)
- `AAIDirectorActor::BPF_GetAIsForEnemy(enemyActor, combatRole, out AIs)` keys the director **per enemy
  actor**, and alert levels plus `BPE_OnEnemy*` events are per enemy. Built for more than one opponent.
- Attack-ticket system (`/Script/Sifu.TicketSettings` in `DefaultWuguanAI.ini`): tickets are scored by
  `IsOnScreen`, `FlyDistance`, `TimeSinceLastAttack`. **Unverified hypothesis:** `IsOnScreen` probably tests
  the local camera, which on a listen server is the host's, so the client player might get fewer attacks.
  Confirm in Ghidra (ticket scoring) before relying on it.
- `UAIFightingComponent::BPF_GetEnemy / BPF_ForceEnemy / BPF_ForgetEnemy`: each AI holds one current enemy.
- Targeting evaluation: `UBaseTargetEvaluation` and subclasses, `UTargetDB`, `UTargetSettingsDB`,
  `UTargetableComponent`, `UTargettingHelper`.
- AI death counter hooks: `m_iDeathCounterDecreaseWhenKilled` (on AI + spawner) feed the player's DeathCounter.

## Death / aging
- GAS attributes on `UCharacterStatAttributeSet`: `Age` (RepNotify), `DeathCounter` (RepNotify),
  `DeathCounterMax`, `Experience`, `XPMultiplier`, combo XP. Since they replicate, each player's age shows on both machines for free.
- `UDeathAbility` (GAS), `UDeathDB`, `UDeathLevelSequence`, `UDeathMenu` (UI), the shrine/upgrade flow in Blueprints.
  `BP_FightingPlayer` has `CharacterDied`, `BPE_OnDeath`, `CE_DeathCounterUpdated`, `m_OnDeathCounterDecrement_Event_0`.
- Co-op decision for later: per-player aging (natural, already replicated) vs shared. The death menu and
  death sequence are local UI and must run only on the dying player's machine.

## Single-player assumptions (Blueprint layer)
From `index\player_lookups.tsv` (name-map scan of 9,148 logic assets):
- `GetPlayerController` 69, `GetPlayerCameraManager` 65, `BPF_GetFirstLocalPlayerPawn` 56, `GetPlayerPawn` 52,
  `GetPlayerCharacter` 23, `BPF_GetMainCharacter` 16, `GetOwningPlayer` 72 (UI, usually fine).
- Most of these are in UI (20), TU_3 environments (16), TrainingRoom (14), Situations_H3 (14), achievement
  conditions (14), LD ingredients (12), Hideout4 map (11), AI Blueprints (10), gameplay sequences (9).
- **Highest-risk hits for co-op** (host-side gameplay that picks "the first local player"):
  `Blueprints/AI/BP_AICharacter_Base`, `BP_AIDirectorActor`, `BP_AISpawner`, `Spawner/BP_AIWaveSpawner`,
  `Bosses/BP_AISituation_Boss` (+ Yang, Fajar), `EQS/Context/EnvQueryContext_Player` (EQS "player" context),
  `Actions/Attacks/Vanish/BP_AiAction_Vanish`, `Arena/BP_HardpointAreaActor`, `Arena/Objectives/BP_ArenaTargetsObjective`,
  `TU_3/Common/BPs/BP_ArenaPhaseTransitionManager_Base`, the `LevelDesign/Situations_H3/BP_AiSituation_*` and
  `Maps/Hideout*/…_Situation` encounter scripts, `LDIngredients/Weapons/BPWeapon` (+ makeshift and meteor-hammer families),
  `LDIngredients/Throwable/BP_Throwable`, `LDIngredients/Breakables/BP_BaseBreakable`, `Scripting/BP_TRG_MakeBehaviourChange`.
  Each needs "nearest/most relevant player" or "instigator" in place of "player 0".
  **Confirmed example:** `BP_AIDirectorActor` ubergraph, on a new domination step, calls
  `SCGameplayStatics::BPF_GetFirstLocalPlayerPawn` and passes it to `PickRandomAIActor`, which sets `SelectedAI`.
  On a listen server that is always the host's pawn, so the director would never pick the client as the target.
  Fix options: hook `BPF_GetFirstLocalPlayerPawn` (native, `SCCore`) to return the director's current enemy,
  or hook `PickRandomAIActor`. Readable bytecode for each one is in
  `logic_cfg\Blueprints\...\<name>.txt`.
- On a **listen server**, index 0 is the host and on the **client** it's the local player. So "local
  player" lookups are mostly right for presentation (UI, camera, FX), but **wrong for gameplay
  decisions made on the host** (AI picking "the player", triggers, level scripting). Each AI and
  LDIngredient hit needs a review. Only `BP_FightingPlayer` (`HasAuthority`, `IsLocallyControlled`),
  `BP_TPSCharacter` (`IsServer`), `FightingPlayerControllerBP` and a few interactables check authority or locality.

## Host/client role notes (either player can host)
- **Authority-only (runs on whoever hosts):** GameMode, AI director and spawners, AI behavior trees, game flow
  and map travel, damage resolution via `Server*` RPCs on Order/Health/Defense, GameState.
- **Local-only (runs on each machine for its own player):** camera (`ASCPlayerCameraManager`, camera BTs),
  UI and HUD, input (`UInputManager`), death menu, Wwise audio, post-process FX.
- **Save/profile:** `USCSaveObjectGameData` / `USCSaveObjectPlayerProfile` (WG variants), `DefaultSave.ini`.
  Rule: the host's save drives progression, and the client never writes its save while connected (enforce in the mod).
- Map travel: the host must use server travel (`ServerTravel`/seamless) so the client follows, and
  `TravelToLoadedMap`/`LoadMapAsync` on the client must be suppressed or redirected.

## Hooking notes (UE4SS)
- Working UE4SS settings for Sifu are in `TailCoop/ue4ss-config/` (LoadMap hook off, VTable engine tick). Without the LoadMap
  hook, detect map changes via `InitGameState`/`BeginPlay` hooks or `NotifyOnNewObject` on the GameState class.
- Native thunk addresses for every UFunction: `reflection\ObjectDump.txt` (`[f: rva]`), already named in Ghidra.
