# TailCoop PvP: a player-vs-player mode under CO-OP

> The plan as approved (2026-10-11). Built as described; differences: 5 maps (The Stairs and Data Center dropped,
> rail camera), spots 150 / 550 cm in front of the host's start, and "ready" waits for the challenge's intro to end.
> Results: TESTLOG.md, "PvP".

## Context
The user asked for a PvP version under CO-OP. Their choices:
- **Map:** a real Arena map.
- **Rules:** rounds, first to 3 wins the match.
- **Enemies:** none, only the two players.

The co-op mod already provides almost everything needed:
- the CO-OP menu, sessions over Tailscale and version checking;
- the partner's character shown with their exact moves (pose stream);
- hits forwarded between games and applied with Sifu's own impact function (`BPF_GenerateForeignImpact`), including
  parry and dodge outcomes;
- Arena travel and Start in both games;
- shared pause-menu navigation;
- a HUD text slot (the waves counter).

PvP is therefore mostly new rules on top of existing pieces, plus switching the co-op enemy logic off.

## Approach

### 1. Menu and session (`tc_menu.lua`, `tc_flow.lua`, `tc_session.lua`)
- **Host menu:** HOST GAME gets **PVP**, which opens a page listing PvP maps (the table in step 6). Picking a map hosts
  with mode `"pvp"` and that map's (batch, challenge).
- **Joiner lobby:** shows "HOST PICKED PVP · <MAP>".
- **Starting:** `F.hostStart` sends `start|pvp|batch|challenge`.
- **Entry (`tc_flow.enter`, extended for `"pvp"`):** the same route as Arena into the Arena scene. Then, instead of
  opening the challenge list:
  - the host calls `AR.travel(batch, challenge)` (`tc_arena.lua`);
  - the joiner follows through the existing `arena|go` handler.
- **Auto Start:** once both games are on the title screen (the existing "partner is on the title screen" message), the
  host calls `AR.startBoth()`.
- `M.ENABLED_MODES.pvp = true`; `F.MODE_LABEL.pvp = "PVP"`.

### 2. New module `tc_pvp.lua`: the match
Active while `S.mode == "pvp"` and the Arena challenge has started. It runs in both games, and the host decides
rounds.
- **Empty arena, each game on its own:**
  - Stop the wave director: refill off plus cancel the current wave. This code already exists in `tc_arena.waveTick`;
    move it into a shared `AR.stopWaves()`.
  - Put every enemy away, checked every second: AI stopped, hidden, collision off, lifted out of reach. Expose the
    existing retire logic in `tc_enemies.lua` as `E.putAway(actor)`.
  - Enemies are not killed, so the challenge never moves on, completes or fails.
- **No dying:** our player gets `m_HealthComponent:BPF_SetCanDieByDamage(false)`, the same as `setCanDie` in
  `tc_arena.lua`. A knockout is read as health ≤ 1 (proven in the arena last-life code), so Sifu's death, aging and
  game over never happen.
- **Rounds:**
  - **Knockout:** a game whose player is at ≤ 1 health sends `pvp|ko`.
  - **Scoring:** the host adds a point to the other player and sends `pvp|round|host|join|loser`.
  - **Reset, 2 s later, in both games:**
    - health to max; guard gauge full (`BPF_IncreaseGuardGauge(max)`);
    - orders cancelled (`BPF_CancelAllOrders`), so a knocked-down player stands up;
    - each player placed on their spot, 4 m either side of the host's spawn, facing each other (spots sent by the
      host);
    - 2 s of invincibility (`BPF_SetInvincibility`).
  - **Match end:** at 3 points the match ends, "YOU WIN" / "YOU LOSE" shows for 6 s, then a new match starts at 0–0.
    Players leave through the pause menu; the existing nav hooks take both games to Main menu or Challenge selection.
- **Score display:** the Arena HUD counter, through the text setter in `tc_arena`'s waves section: "2 – 1", with a
  "FIRST TO 3" label and short "ROUND 3" / "YOU WIN" messages.

### 3. Player-vs-player hits (`tc_aggro.lua`)
- **No friendly-fire block in PvP:** skip `noFriendlyFire` and `guardHits`, and restore the faction table and native
  hit guard if they were set. Players can then target the partner's character with Sifu's own lock-on.
- **Sending a hit:** in `AG.onCaptured`, a hit on the partner's character whose instigator is our own player is
  forwarded as `phit` with id `"player"` (`$I$` = our player, `$T$` = their character).
- **Applying a hit:** the partner applies it in `applyPending` with their copy of us as the instigator. For id
  `"player"`, `localActorFor` resolves to `tc_presence.puppetActor()`.
- **Defense:** parry and dodge use the existing `reportOutcomes` / `onOutcome`. A parried attacker is staggered in their
  own game.
- **Dropped hits:** hits on a paused or downed player.
- **Partner's character after each hit:** its health and guard are reset in our game, as health already is. Its
  structure therefore never breaks here, so no takedown prompt appears on it (v1 limit, below).

### 4. Co-op systems held back in PvP
Each gets an early `if S.mode == "pvp" then return end`:
- `tc_enemies`: syncing, handovers, safety net;
- `tc_aggro.assign` and `tc_turns`;
- `tc_arena`: `outTick`, the result mirroring, the waves counter mirroring, the joiner's start offset.

Still running:
- presence, poses and moves;
- gear: held weapons and throws;
- the Arena nav hooks: pause menu Retry, Challenge selection and Main menu.

### 5. Known v1 limits (said in the README)
- No takedowns or grabs between players.
- Hit reactions show on the attacker's screen about one round-trip later, through the pose stream.
- No Focus vital points on the partner (the focus guard keeps it crash-free).

### 6. PvP map list
- A lab probe walks the challenge list (`AR.travel` plus `AR.current` / `AR.objective`). It picks one challenge per
  Arena map whose objective doesn't end on its own: no timer.
- The result is 4–6 maps in a small table in `tc_pvp.lua`.

## Critical files
- **New:** `TailCoop/lua/Scripts/tc_pvp.lua`. Add it to `SCRIPT_FILES` in `tc_util.lua` (it's part of the version
  hash).
- **Edited:**
  - `tc_menu.lua`, `tc_flow.lua`, `tc_session.lua`: mode and map;
  - `tc_aggro.lua`: player hits; friendly fire off in PvP;
  - `tc_arena.lua`: `AR.stopWaves`, PvP guards, counter text helper;
  - `tc_enemies.lua`: `E.putAway`, PvP guards;
  - `tc_turns.lua`, `main.lua`: start `tc_pvp`.
- **Docs:** `README.md`, `TailCoop-README.txt` (PvP section and limits), `TESTLOG.md`.

## Verification (lab: two games on this PC)
Input is posted to the game windows (`Lab\Press.ps1 -Front`), because RustDesk blocks SendInput. I ask before driving
the lab while the user is at the PC.

1. **Spike first.** The joiner punches the host's copy, and the reverse. Check:
   - the other game's health drops ("phit" applied);
   - a parry staggers the attacker.

   If a player-instigated foreign impact misbehaves, the fallback is damage plus a hit reaction.
2. **Rounds.** Set one player's health low and land a hit. Check:
   - "ROUND", the score the same on both screens;
   - both players reset at their spots with full health, then invincibility ends;
   - after 3 knockouts, match end, then a new match.
3. **Empty arena for 10 minutes.** Check:
   - no visible enemy (GHOST monitor 0);
   - the challenge never completes or fails;
   - no Sifu death or aging (death counter unchanged).
4. **Leaving.** Pause → Main menu in one game takes both; Retry restarts PvP in both.
5. **Co-op regression.** A short Arena co-op run and a Training Room run behave as before: 0 errors, waves, hits.
6. **Release:** ask the user, then publish as v0.2.0 the usual way (`package.ps1`, commit, push, `gh release`).
