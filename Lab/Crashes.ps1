# Crashes.ps1 - every crash report of both lab systems, grouped by where it crashed (first game frames).
#   .\Lab\Crashes.ps1 [-Frames 4] [-Detail]
param([int]$Frames = 4, [switch]$Detail)
$root = Split-Path -Parent $PSScriptRoot
$rows = foreach ($s in 1, 2) {
    $dir = Join-Path $root "LabData\Sys$s\Saved\Crashes"
    foreach ($c in (Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue)) {
        $x = Join-Path $c.FullName 'CrashContext.runtime-xml'
        if (-not (Test-Path $x)) { continue }
        $t = Get-Content $x -Raw
        $err = [regex]::Match($t, '<ErrorMessage>([\s\S]*?)</ErrorMessage>').Groups[1].Value.Trim() -replace '\s+', ' '
        $err = $err -replace 'Unhandled Exception: EXCEPTION_ACCESS_VIOLATION ', 'AV '
        if ($err.Length -gt 70) { $err = $err.Substring(0, 70) }
        $stack = [regex]::Match($t, '<PCallStack>([\s\S]*?)</PCallStack>').Groups[1].Value
        $all = [regex]::Matches($stack, '(\S+)\s+0x[0-9a-fA-F]+\s+\+\s+([0-9a-fA-F]+)') | ForEach-Object {
            ($_.Groups[1].Value -replace 'Sifu-Win64-Shipping', 'S') + '+' + $_.Groups[2].Value
        }
        [pscustomobject]@{
            Sys = $s; Time = $c.LastWriteTime; Error = $err
            Top = ($all | Select-Object -First $Frames) -join ' < '
            HasUE4SS = [bool]($all -match '^UE4SS'); HasTailCoop = [bool]($all -match 'TailCoop')
            Stack = $all
        }
    }
}
$rows | Sort-Object Time | Format-Table Sys, @{ n = 'Time'; e = { $_.Time.ToString('MM-dd HH:mm') } }, Error, Top, HasUE4SS, HasTailCoop -AutoSize |
    Out-String -Width 260
if ($Detail) { $rows | Sort-Object Time | ForEach-Object { "== Sys$($_.Sys) $($_.Time) $($_.Error)"; $_.Stack -join "`n" } }
