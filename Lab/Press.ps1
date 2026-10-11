# Press.ps1 - post key presses to one lab system's game window (PostMessage: only that window receives them,
# the real keyboard and mouse are not touched, and it works while the window is in the background).
#   .\Lab\Press.ps1 -System 2 -Key Enter
#   .\Lab\Press.ps1 -System 1 -Key Down,Down,Enter -DelayMs 400
param(
    [Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$System,
    [Parameter(Mandatory = $true)][string[]]$Key,
    [int]$DelayMs = 300,
    [int]$HoldMs = 60,  # how long each key stays down (e.g. 2000 to walk)
    [switch]$Front      # bring the window to the front first (gameplay keys and clicks only reach a game in front)
)
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LabKeys {
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
}
'@ -ErrorAction SilentlyContinue

$codes = @{ Enter = 0x0D; Escape = 0x1B; Space = 0x20; Up = 0x26; Down = 0x28; Left = 0x25; Right = 0x27; Back = 0x08 }
$root = Split-Path -Parent $PSScriptRoot
$gamePid = [int](Get-Content (Join-Path $root "LabData\Sys$System\game.pid"))
$proc = Get-Process -Id $gamePid -ErrorAction SilentlyContinue
if (-not $proc) { Write-Warning "System $System is not running (PID $gamePid)"; exit 1 }
$hwnd = $proc.MainWindowHandle
if ($Front) {
    [LabKeys]::ShowWindow($hwnd, 9) | Out-Null
    [LabKeys]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Milliseconds 300
}
foreach ($k in $Key) {
    # Mouse buttons (LMB light attack, RMB heavy): posted at the window's middle. They reach gameplay when the window
    # is in front - also during a remote-desktop session that blocks injected input (SendInput, Lab\Input.ps1).
    if ($k -in 'LMB', 'RMB') {
        $msgDown, $msgUp, $btn = if ($k -eq 'LMB') { 0x0201, 0x0202, 1 } else { 0x0204, 0x0205, 2 }
        $pos = [IntPtr]((360 -shl 16) -bor 640)
        [LabKeys]::PostMessage($hwnd, $msgDown, [IntPtr]$btn, $pos) | Out-Null
        Start-Sleep -Milliseconds $HoldMs
        [LabKeys]::PostMessage($hwnd, $msgUp, [IntPtr]0, $pos) | Out-Null
        Start-Sleep -Milliseconds $DelayMs
        continue
    }
    $vk = if ($codes.ContainsKey($k)) { $codes[$k] } elseif ($k.Length -eq 1) { [int][char]$k.ToUpper() } else { throw "unknown key $k" }
    $scan = [LabKeys]::MapVirtualKey($vk, 0)
    $extended = if ($vk -in 0x25, 0x26, 0x27, 0x28) { 1 -shl 24 } else { 0 }
    $down = [IntPtr](1 -bor ($scan -shl 16) -bor $extended)
    $up = [IntPtr]((1 -bor ($scan -shl 16) -bor $extended -bor (3 -shl 30)) -band 0xFFFFFFFF)
    [LabKeys]::PostMessage($hwnd, 0x0100, [IntPtr]$vk, $down) | Out-Null   # WM_KEYDOWN
    Start-Sleep -Milliseconds $HoldMs
    [LabKeys]::PostMessage($hwnd, 0x0101, [IntPtr]$vk, $up) | Out-Null     # WM_KEYUP
    Start-Sleep -Milliseconds $DelayMs
}
"System ${System}: sent $($Key -join ', ')"
