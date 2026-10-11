TailCoop - two-player online co-op for Sifu, over Tailscale
https://github.com/mashburnn/tailcoop

INSTALL (both players)
1. Find your Sifu folder (Steam: right-click Sifu > Manage > Browse local files) and open
   Sifu\Binaries\Win64 - the folder with Sifu-Win64-Shipping.exe in it.
2. Paste everything from this zip into that folder: dwmapi.dll and the ue4ss folder.
3. Install Tailscale (https://tailscale.com) on both PCs and sign both into the same tailnet
   (or share the host's device with the other player).
4. Remove any other co-op mod first (for example another mod's dsound.dll in the same folder).

PLAY
- Title screen > CO-OP > HOST GAME, pick Training Room or Arena. The other player:
  CO-OP > JOIN GAME and picks the host's device from the list.
- In the Arena the host picks the challenge; the other player's game follows.
- The first time you host, Windows may ask to let Sifu through the firewall: allow it
  (Tailscale traffic only reaches it through your tailnet).
- If the join list is empty, put the host's Tailscale address in
  ue4ss\Mods\TailCoop\TailCoop.ini (peer = 100.x.y.z).

UNINSTALL
Delete dwmapi.dll and the ue4ss folder from Sifu\Binaries\Win64.

ALREADY USING UE4SS?
Copy only ue4ss\Mods\TailCoop, ue4ss\Mods\shared\UEHelpers and ue4ss\VTableLayout.ini, and in
your UE4SS-settings.ini set HookAActorTick, HookGameViewportClientTick, HookProcessConsoleExec and
HookLoadMap to 0 (Sifu crashed at startup with them on). TailCoop needs this UE4SS build
(v3.0.1 Beta, git 5418fa4e).

NOTES
- Made for Sifu on PC (tested with the December 2024 game build). Both players need the same
  game version and the same TailCoop version.
- Logs, if something goes wrong: ue4ss\Mods\TailCoop\TailCoop.log and
  ue4ss\Mods\TailCoop\native\TailCoopNative.log.
- Not done yet: takedowns on enemies the other game runs count in both games but show only on
  your screen, grabs are untested; Arena randomizer,
  capture-point and target challenges and kill bonuses aren't shared; story mode and the Wuguan
  aren't co-op.

UE4SS (the loader in this zip) is MIT-licensed: ue4ss\LICENSE.
