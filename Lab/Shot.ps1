# Shot.ps1 - capture a lab system's game window (works while it is behind other windows).
#   .\Lab\Shot.ps1 -System 1 [-Out path.png]
param(
    [Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$System,
    [string]$Out = ''
)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LabWin {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
}
'@ -ErrorAction SilentlyContinue
[LabWin]::SetProcessDPIAware() | Out-Null

$root = Split-Path -Parent $PSScriptRoot
$gamePid = [int](Get-Content (Join-Path $root "LabData\Sys$System\game.pid"))
$proc = Get-Process -Id $gamePid -ErrorAction SilentlyContinue
if (-not $proc) { Write-Warning "System $System is not running (PID $gamePid)"; exit 1 }
$hwnd = $proc.MainWindowHandle
$r = New-Object LabWin+RECT
[LabWin]::GetClientRect($hwnd, [ref]$r) | Out-Null
$bmp = New-Object System.Drawing.Bitmap ([math]::Max(1, $r.Right)), ([math]::Max(1, $r.Bottom))
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
[LabWin]::PrintWindow($hwnd, $hdc, 3) | Out-Null   # PW_CLIENTONLY | PW_RENDERFULLCONTENT
$g.ReleaseHdc($hdc)
if (-not $Out) { $Out = Join-Path $root ("LabData\Sys$System\shot_" + (Get-Date -Format 'HHmmss') + '.png') }
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
$Out
