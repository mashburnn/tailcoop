# Burst.ps1 - a quick sequence of frames from both lab game windows (PrintWindow, works behind other windows), tiled
# into one contact sheet per system: frames left to right, top to bottom. For motion you can't see in one screenshot
# (a character spinning, a copy snapping).
#   .\Lab\Burst.ps1 [-Frames 12] [-IntervalMs 150] [-Name burst]   -> LabData\SysN\<Name>.png
param([int]$Frames = 12, [int]$IntervalMs = 150, [string]$Name = 'burst', [int]$Columns = 4)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LabBurst {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
}
'@ -ErrorAction SilentlyContinue
[LabBurst]::SetProcessDPIAware() | Out-Null
$root = Split-Path -Parent $PSScriptRoot
$wins = @{}
foreach ($s in 1, 2) {
    $proc = Get-Process -Id ([int](Get-Content (Join-Path $root "LabData\Sys$s\game.pid"))) -ErrorAction SilentlyContinue
    if ($proc) { $wins[$s] = $proc.MainWindowHandle }
}
$thumbW, $thumbH = 400, 225
$rows = [math]::Ceiling($Frames / $Columns)
$sheets = @{}
foreach ($s in $wins.Keys) {
    $sheets[$s] = New-Object System.Drawing.Bitmap ($thumbW * $Columns), ($thumbH * $rows)
}
for ($i = 0; $i -lt $Frames; $i++) {
    $t0 = Get-Date
    foreach ($s in $wins.Keys) {
        $r = New-Object LabBurst+RECT
        [LabBurst]::GetClientRect($wins[$s], [ref]$r) | Out-Null
        $bmp = New-Object System.Drawing.Bitmap ([math]::Max(1, $r.Right)), ([math]::Max(1, $r.Bottom))
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $g.GetHdc()
        [LabBurst]::PrintWindow($wins[$s], $hdc, 3) | Out-Null
        $g.ReleaseHdc($hdc)
        $g.Dispose()
        $sg = [System.Drawing.Graphics]::FromImage($sheets[$s])
        $x = ($i % $Columns) * $thumbW
        $y = [math]::Floor($i / $Columns) * $thumbH
        $sg.DrawImage($bmp, $x, $y, $thumbW, $thumbH)
        $sg.DrawString("$($i + 1)", (New-Object System.Drawing.Font 'Arial', 14), [System.Drawing.Brushes]::Yellow, $x + 4, $y + 4)
        $sg.Dispose()
        $bmp.Dispose()
    }
    $left = $IntervalMs - ((Get-Date) - $t0).TotalMilliseconds
    if ($left -gt 0) { Start-Sleep -Milliseconds ([int]$left) }
}
foreach ($s in $wins.Keys) {
    $out = Join-Path $root "LabData\Sys$s\$Name.png"
    $sheets[$s].Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $sheets[$s].Dispose()
    $out
}
