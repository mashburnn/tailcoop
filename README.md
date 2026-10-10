# TailCoop

Two-player online co-op for **Sifu** (PC), played over **Tailscale**. One player hosts, the other joins from the
in-game CO-OP menu. No port forwarding, no Steam networking.

You need your own copy of Sifu. This mod contains no game files.

## Install

1. Download **TailCoop-x.y.z.zip** from [Releases](https://github.com/mashburnn/tailcoop/releases).
2. Open your Sifu install folder, then `Sifu\Binaries\Win64` (the folder with `Sifu-Win64-Shipping.exe`).
   On Steam: right-click Sifu > Manage > Browse local files.
3. Paste everything from the zip into that folder: `dwmapi.dll` and the `ue4ss` folder.
4. Install [Tailscale](https://tailscale.com) on both PCs, in the same tailnet (or share the host's device with your
   friend).

Both players need the same TailCoop version. Remove other co-op mods first (for example another mod's `dsound.dll`).

## Play

- **Host:** title screen > **CO-OP** > **HOST GAME** > Training Room or Arena.
- **Friend:** **CO-OP** > **JOIN GAME** > the host's device.
- The first time you host, Windows may ask to let Sifu through the firewall: allow it.
- Join list empty? Put the host's Tailscale address in `ue4ss\Mods\TailCoop\TailCoop.ini` (`peer = 100.x.y.z`).

## What works

- **Training Room together:** you see your friend's character with their exact moves. Enemies are shared: each one
  fights one of you and runs in that player's game. Hits land both ways, and there's no friendly fire.
- **Arena challenges together:** the host picks the challenge (the friend's game follows), and you start together.
  The same waves appear on both screens and kills in either game count. You both get the same result and stars, and
  Retry, Back and Main menu apply to both.
- **Weapons:** what each player holds shows in their hands on the other screen, and thrown weapons fly on both
  screens and land in the same place.
  - A player who runs out of lives watches their friend; the challenge fails only when both are out.
  - Enemies take turns attacking the two of you instead of both at once.
- **Pause:** opening the pause menu pauses only your game; meanwhile your enemies go to your friend.

## Not yet

This is an early version.
- Takedowns and grabs on enemies your friend's game runs are untested.
- Weapons: enemies' throws and the bo staff's bend may not show on the other screen yet.
- Arena randomizer, capture-point and target challenges, and kill bonuses aren't shared yet.
- Story mode and the Wuguan aren't co-op.

## Uninstall

Delete `dwmapi.dll` and the `ue4ss` folder from `Sifu\Binaries\Win64`.

## Already using UE4SS?

Copy only `ue4ss\Mods\TailCoop`, `ue4ss\Mods\shared\UEHelpers` and `ue4ss\VTableLayout.ini`. Then set these four
lines to `0` in your `UE4SS-settings.ini`: `HookAActorTick`, `HookGameViewportClientTick`, `HookProcessConsoleExec`
and `HookLoadMap` (Sifu crashes at startup with them on). TailCoop is built against UE4SS v3.0.1 Beta (git 5418fa4e).

## Troubleshooting

Logs: `ue4ss\Mods\TailCoop\TailCoop.log` and `ue4ss\Mods\TailCoop\native\TailCoopNative.log`. Please attach both when
reporting a problem in [Issues](https://github.com/mashburnn/tailcoop/issues).

## Source

| Path | What |
|---|---|
| `TailCoop/lua/Scripts/` | the mod (UE4SS Lua) |
| `TailCoop/cpp/` | `TailCoopNative.dll`: network transport, Tailscale lookup, pose sync, an engine crash fix (`build.ps1`, VS 2022 Build Tools) |
| `TailCoop/ue4ss-config/` | UE4SS settings tuned for Sifu, and `VTableLayout.ini` |
| `TailCoop/package.ps1` | builds the release zip (needs the UE4SS v3.0.1 Beta build in `Tools\UE4SS-experimental`) |

UE4SS, the loader bundled in the release zip, is MIT-licensed (see `ue4ss\LICENSE` in the zip).
