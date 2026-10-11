# ArenaCrowd.ps1 - co-op Arena fight measured for crowding and attack turns (tc_devtests arenacrowd): both players stay
# near the start (kept alive), each game logs "CROWD" every 5 s. Screenshots of both windows during the fight.
#   .\Lab\ArenaCrowd.ps1 [-Play 60] [-Swap] [-Shots 3]
param([int]$Play = 60, [switch]$Swap, [int]$Shots = 3, [int]$Batch = 0, [int]$Challenge = 0, [string]$Turns = '')
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$job = Start-Job -ScriptBlock { param($h, $p, $s, $b, $c, $tu) & (Join-Path $h 'ArenaGo.ps1') -Test arenacrowd -Play $p -Swap:("$s" -eq 'True') -Batch $b -Challenge $c -Turns $tu | Out-Null } -ArgumentList $here, $Play, "$Swap", $Batch, $Challenge, $Turns
# Screenshots once the fight is on: first the previous run's logs must be gone (CoopAuto deletes them once the old
# games are stopped - their CROWD lines fooled this before), then both new logs must show the start.
$deadline = (Get-Date).AddSeconds(300)
$gone = @{ 1 = $false; 2 = $false }
while ((Get-Date) -lt $deadline) {
    Start-Sleep 2
    $n = 0
    foreach ($s in 1, 2) {
        $l = Join-Path $root "LabData\Sys$s\TailCoop.log"
        if (-not (Test-Path $l)) { $gone[$s] = $true; continue }
        if ($gone[$s] -and (Select-String -Path $l -Pattern 'ARENAGO: started' -Quiet)) { $n++ }
    }
    if ($n -eq 2) { break }
}
Start-Sleep 10
for ($i = 1; $i -le $Shots; $i++) {
    foreach ($s in 1, 2) { & (Join-Path $here 'Shot.ps1') -System $s -Out (Join-Path $root "LabData\Sys$s\crowd_$i.png") | Out-Null }
    Start-Sleep ([int]($Play / ($Shots + 1)))
}
Wait-Job $job | Out-Null
Receive-Job $job | Out-Null
foreach ($s in 1, 2) {
    "=== System $s"
    $lines = Get-Content (Join-Path $root "LabData\Sys$s\TailCoop.log")
    $start = ($lines | Select-String -Pattern 'ARENAGO: started' | Select-Object -First 1).LineNumber
    if (-not $start) { $start = 1 }
    $lines | Select-Object -Skip ($start - 1) |
        Where-Object { $_ -match 'CROWD|ARENAGO: (started|done)|profile:|hitches:|ERROR|crash' } |
        ForEach-Object { ($_ -replace '^(\S+) \[TailCoop:\d\] ', '$1 ') -replace '^(.{0,700}).*$', '$1' }
}


