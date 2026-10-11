# Input.ps1 - real input to a lab game window, for gameplay tests (posted messages only reach menus).
# Brings the window to the front and uses SendInput. Every input is sent only while that game window is the
# foreground window; if anything else takes the foreground the script stops.
#   .\Lab\Input.ps1 -System 2 -Script "click;wait 400;click;wait 400;rclick;key W 800;key Space 100"
#   steps: click | rclick | hold <ms> (left button held) | rhold <ms> (right: guard) | key <name> <ms> | wait <ms>
#   combo <key> <click|rclick> <ms> (mouse button pressed while the key is held)
#   key names: W A S D Space Shift Ctrl Q E F R 1 2 3 Enter Escape X C V Z
param(
    [Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$System,
    [Parameter(Mandatory = $true)][string]$Script
)
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LabInput {
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUT {
        [FieldOffset(0)] public uint type;
        [FieldOffset(8)] public MOUSEINPUT mi;
        [FieldOffset(8)] public KEYBDINPUT ki;
    }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    public static void Mouse(uint flags) {
        var i = new INPUT[1]; i[0].type = 0; i[0].mi.dwFlags = flags;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Key(ushort vk, bool up) {
        var i = new INPUT[1]; i[0].type = 1; i[0].ki.wVk = vk;
        i[0].ki.wScan = (ushort)MapVirtualKey(vk, 0);
        i[0].ki.dwFlags = 0x0008u | (up ? 0x0002u : 0u);  // KEYEVENTF_SCANCODE | KEYUP
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@ -ErrorAction SilentlyContinue

$root = Split-Path -Parent $PSScriptRoot
$gamePid = [int](Get-Content (Join-Path $root "LabData\Sys$System\game.pid"))
$proc = Get-Process -Id $gamePid -ErrorAction SilentlyContinue
if (-not $proc) { Write-Warning "System $System is not running"; exit 1 }
$hwnd = $proc.MainWindowHandle
[LabInput]::ShowWindow($hwnd, 9) | Out-Null
# Windows only lets the process with the latest input take the foreground: a tap of Alt (sent by us) unlocks it.
for ($try = 0; $try -lt 5 -and [LabInput]::GetForegroundWindow() -ne $hwnd; $try++) {
    [LabInput]::Key([uint16]0x12, $false); [LabInput]::Key([uint16]0x12, $true)
    [LabInput]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Milliseconds 250
}
Start-Sleep -Milliseconds 300

$vk = @{ W = 0x57; A = 0x41; S = 0x53; D = 0x44; Space = 0x20; Shift = 0x10; Ctrl = 0x11; Q = 0x51; E = 0x45; F = 0x46
         R = 0x52; '1' = 0x31; '2' = 0x32; '3' = 0x33; Enter = 0x0D; Escape = 0x1B; X = 0x58; C = 0x43; V = 0x56; Z = 0x5A }

[LabInput]::SetProcessDPIAware() | Out-Null
function Guard {
    if ([LabInput]::GetForegroundWindow() -ne $hwnd) { Write-Warning "System $System lost the foreground: stopping"; exit 2 }
    # Clicks land where the cursor is: keep it inside this window (else the click focuses the other system).
    $r = New-Object LabInput+RECT
    [LabInput]::GetWindowRect($hwnd, [ref]$r) | Out-Null
    [LabInput]::SetCursorPos([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2)) | Out-Null
}
Guard

foreach ($step in $Script.Split(';')) {
    $parts = $step.Trim().Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Count -eq 0) { continue }
    switch ($parts[0]) {
        'click' { Guard; [LabInput]::Mouse(0x0002); Start-Sleep -Milliseconds 60; [LabInput]::Mouse(0x0004) }
        'rclick' { Guard; [LabInput]::Mouse(0x0008); Start-Sleep -Milliseconds 60; [LabInput]::Mouse(0x0010) }
        'hold' { Guard; [LabInput]::Mouse(0x0002); Start-Sleep -Milliseconds ([int]$parts[1]); [LabInput]::Mouse(0x0004) }
        'rhold' { Guard; [LabInput]::Mouse(0x0008); Start-Sleep -Milliseconds ([int]$parts[1]); [LabInput]::Mouse(0x0010) }
        'key' {
            Guard
            $code = $vk[$parts[1]]
            if (-not $code) { Write-Warning "unknown key $($parts[1])"; continue }
            [LabInput]::Key([uint16]$code, $false); Start-Sleep -Milliseconds ([int]$parts[2]); [LabInput]::Key([uint16]$code, $true)
        }
        'wait' { Start-Sleep -Milliseconds ([int]$parts[1]) }
        # combo <key> <button: click|rclick> <ms>: the key held, the mouse button pressed while it's down.
        'combo' {
            Guard
            $code = $vk[$parts[1]]
            if (-not $code) { Write-Warning "unknown key $($parts[1])"; continue }
            $down, $up = if ($parts[2] -eq 'rclick') { 0x0008, 0x0010 } else { 0x0002, 0x0004 }
            [LabInput]::Key([uint16]$code, $false); Start-Sleep -Milliseconds 40
            [LabInput]::Mouse($down); Start-Sleep -Milliseconds ([int]$parts[3]); [LabInput]::Mouse($up)
            Start-Sleep -Milliseconds 40; [LabInput]::Key([uint16]$code, $true)
        }
    }
}
"done"
