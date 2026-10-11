# ArenaProbe.ps1 - both lab games enter the same Arena challenge (session up, no arena sync) and log what's there
# (tc_devtests arenaprobe). Each player then walks toward the first enemies (they wait until a player comes close).
#   .\Lab\ArenaProbe.ps1 [-Batch 0] [-Challenge 0]
param([int]$Batch = 0, [int]$Challenge = 0, [int]$Seconds = 150)

$here = $PSScriptRoot
$root = Split-Path -Parent $here
foreach ($s in 1, 2) {
    $ini = Join-Path $root "Sifu_Lab$(if ($s -eq 2) { '2' })\Sifu\Binaries\Win64\ue4ss\Mods\TailCoop\TailCoop.ini"
    Set-Content $ini -Encoding ascii -Value @("arenabatch = $Batch", "arenachallenge = $Challenge")
}
& (Join-Path $here 'CoopAuto.ps1') -Mode arena -Test arenaprobe -Seconds 30 | Out-Null
# Wait for the challenge to start on both (the probe presses Start), then walk each player in.
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline) {
    $started = foreach ($s in 1, 2) { [bool](Select-String -Path (Join-Path $root "LabData\Sys$s\TailCoop.log") -Pattern 'ARENAPROBE pressing Start' -Quiet) }
    if (-not ($started -contains $false)) { break }
    Start-Sleep 2
}
Start-Sleep 4
foreach ($s in 1, 2) { & (Join-Path $here 'Input.ps1') -System $s -Script 'key W 2500' | Out-Null }
Start-Sleep 10
foreach ($s in 1, 2) { & (Join-Path $here 'Shot.ps1') -System $s -Out (Join-Path $root "LabData\Sys$s\arenaprobe_fight.png") | Out-Null }
Start-Sleep $Seconds
foreach ($s in 1, 2) { & (Join-Path $here 'Shot.ps1') -System $s -Out (Join-Path $root "LabData\Sys$s\arenaprobe_end.png") | Out-Null }
foreach ($s in 1, 2) {
    "=== System $s"
    Get-Content (Join-Path $root "LabData\Sys$s\TailCoop.log") |
        Where-Object { $_ -match 'ARENAPROBE (title|pressing|pooled|active|killed|called|t=)|ERROR' -and $_ -notmatch 'called (BPF_RaiseTag|LaunchArena|Launch )' } |
        ForEach-Object { $_ -replace '^\S+ \[TailCoop:\d\] ARENAPROBE ', '' } | Select-Object -Unique
}
