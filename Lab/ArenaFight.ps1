# ArenaFight.ps1 - a real co-op Arena fight, played by the lab: session, challenge picked and started on both
# (tc_devtests arenacrowd: crowd / turn measurements, players kept alive), then both players fight with real input
# (Lab\Input.ps1), taking turns on the keyboard and mouse: a burst of light attacks, a heavy attack and a guard in one
# window, then the other. Every lab game also runs the ghost / spin monitor (GHOST / SPIN lines).
# Takes over the keyboard and mouse while it runs.
#   .\Lab\ArenaFight.ps1 [-Play 150] [-Swap] [-Shots 4]
param([int]$Play = 150, [switch]$Swap, [int]$Shots = 4, [int]$Batch = 0, [int]$Challenge = 0, [string]$Turns = '', [string]$Extra = '',
      [string]$Burst = '')
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$hostSys, $joinSys = if ($Swap) { 2, 1 } else { 1, 2 }
$job = Start-Job -ScriptBlock { param($h, $p, $s, $b, $c, $tu, $x) & (Join-Path $h 'ArenaGo.ps1') -Test arenacrowd -Play $p -Swap:("$s" -eq 'True') -Batch $b -Challenge $c -Turns $tu -Extra $x | Out-Null } -ArgumentList $here, ($Play + 30), "$Swap", $Batch, $Challenge, $Turns, $Extra

# Wait for the fight: the previous run's logs gone first (CoopAuto deletes them once the old games are stopped).
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
Start-Sleep 6

# Moving between attacks, as a player does (walking onto other spots of the arena). -Burst replaces it.
$burst = if ($Burst) { $Burst } else { 'key W 700;click;wait 260;click;wait 260;key A 500;click;wait 260;click;wait 380;hold 500;wait 300;key D 700;click;wait 260;click;wait 260;rhold 450;key S 600;click;wait 260;click' }
$end = (Get-Date).AddSeconds($Play)
$shotEvery = [int]($Play / ($Shots + 1))
$nextShot = (Get-Date).AddSeconds($shotEvery)
$shot = 0
$bursts = @{ 1 = 0; 2 = 0 }
while ((Get-Date) -lt $end) {
    foreach ($s in $hostSys, $joinSys) {
        $r = & (Join-Path $here 'Input.ps1') -System $s -Script $burst 2>&1
        if ("$r" -match 'done') { $bursts[$s]++ }
        if ((Get-Date) -ge $nextShot -and $shot -lt $Shots) {
            $shot++
            & (Join-Path $here 'Burst.ps1') -Frames 12 -IntervalMs 150 -Name "fight_$shot" | Out-Null
            $nextShot = (Get-Date).AddSeconds($shotEvery)
        }
    }
}
Wait-Job $job | Out-Null
Receive-Job $job | Out-Null

"=== host = System $hostSys, joiner = System $joinSys; input bursts: System 1 $($bursts[1]), System 2 $($bursts[2])"
foreach ($s in $hostSys, $joinSys) {
    $l = Get-Content (Join-Path $root "LabData\Sys$s\TailCoop.log")
    $pidFile = Join-Path $root "LabData\Sys$s\game.pid"
    $alive = [bool](Get-Process -Id ([int](Get-Content $pidFile)) -ErrorAction SilentlyContinue)
    "--- System $s (alive: $alive): GHOST $(($l | Select-String 'GHOST:').Count), SPIN $(($l | Select-String 'SPIN:').Count), " +
        "enemy deaths $(($l | Select-String 'died').Count), our hits on the partner's enemies $(($l | Select-String 'our hit on').Count), " +
        "handovers $(($l | Select-String 'handed over to').Count), no-copy $(($l | Select-String 'no copy of it').Count), " +
        "aimed at invisible $(($l | Select-String 'AIM: our attacks aim at an INVISIBLE').Count), invisible targets near $(($l | Select-String 'AIM: invisible but targetable').Count), AI restarted by the game $(($l | Select-String 'AI again').Count), running with movement off $(($l | Select-String 'movement off').Count), out of combat (sent back in) $(($l | Select-String "was in nobody's fight").Count), stand-ins kept by the host $(($l | Select-String 'the host keeps it').Count), errors $(($l | Select-String -CaseSensitive 'ERROR').Count)"
    $l | Select-String 'ARENAGO t=' | Select-Object -Last 1 | ForEach-Object { $_.Line -replace '^(\S+) \[TailCoop:\d\] ', '$1 ' }
    $l | Select-String 'turns: attacks' | Select-Object -Last 1 | ForEach-Object { $_.Line -replace '^(\S+) \[TailCoop:\d\] ', '$1 ' }
    $l | Select-String 'arena: (the host''s challenge|end|result)|CHALLENGE|objective' | Select-Object -Last 2 | ForEach-Object { $_.Line -replace '^(\S+) \[TailCoop:\d\] ', '$1 ' }
    $l | Select-String 'GHOST:|SPIN:' | Select-Object -First 8 | ForEach-Object { $x = $_.Line -replace '^(\S+) \[TailCoop:\d\] ', '$1 '; $x.Substring(0, [Math]::Min(260, $x.Length)) }
    $l | Select-String 'profile:' | Select-Object -Skip 3 -Last 2 | ForEach-Object { $x = $_.Line -replace '^(\S+) \[TailCoop:\d\] ', '$1 '; $x.Substring(0, [Math]::Min(240, $x.Length)) }
}
foreach ($s in 1, 2) {
    Get-ChildItem (Join-Path $root "LabData\Sys$s\Saved\Crashes") -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-($Play / 60 + 6)) } | ForEach-Object { "CRASH System $s $($_.LastWriteTime)" }
}
