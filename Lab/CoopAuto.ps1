# CoopAuto.ps1 - start a co-op session between the two lab systems without driving the menus by keyboard:
# System 1 runs with -Role host, System 2 with -Role join; the mod goes through the CO-OP menu code itself
# (host -> lobby, join -> lobby, host auto-STARTs when connected). The only key press is Enter on each window to get
# past "PRESS ANY BUTTON".
#   .\Lab\CoopAuto.ps1 -Test g3 -Seconds 90
param([string]$Test = '', [int]$BootSeconds = 45, [int]$Seconds = 90, [string]$Sim = '', [string]$Mode = 'training',
      [switch]$Trace,   # -Trace: log gameplay events (orders, hits, guard...) labelled ME / PUPPET / enemy
      [switch]$Swap,    # -Swap: System 2 hosts and System 1 joins
      [ValidateSet('adaptive', 'fixed')][string]$Buffer = 'adaptive',  # copies' playback lag (fixed = the old 100 ms)
      [long]$Skew = 0)  # -Skew: the joiner's clock runs this many ms ahead of the host's, as on two PCs

$here = $PSScriptRoot
$root = Split-Path -Parent $here
function Log($s) { Join-Path $root "LabData\Sys$s\TailCoop.log" }
function GamePid($s) { [int](Get-Content (Join-Path $root "LabData\Sys$s\game.pid")) }

foreach ($s in 1, 2) {
    $pidFile = Join-Path $root "LabData\Sys$s\game.pid"
    if (Test-Path $pidFile) { Stop-Process -Id ([int](Get-Content $pidFile)) -Confirm:$false -ErrorAction SilentlyContinue }
}
# Any other lab game still running (a PID that changed after launch): stopped by its own PID.
foreach ($game in 'Sifu_Lab', 'Sifu_Lab2') {
    $exe = Join-Path $root "$game\Sifu\Binaries\Win64\Sifu-Win64-Shipping.exe"
    Get-CimInstance Win32_Process -Filter "Name='Sifu-Win64-Shipping.exe'" | Where-Object { $_.ExecutablePath -eq $exe } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Confirm:$false -ErrorAction SilentlyContinue }
}
Start-Sleep 4
foreach ($s in 1, 2) { Remove-Item (Log $s) -ErrorAction SilentlyContinue }
# A lab-console command a game didn't get to (it crashed or was closed) would run in the next game at startup and
# keep its objects across the map change - a crash inside UE4SS (2026-10-10).
foreach ($s in 1, 2) { Remove-Item (Join-Path $root "LabData\Sys$s\cmd.lua") -ErrorAction SilentlyContinue }

$hostSys, $joinSys = if ($Swap) { 2, 1 } else { 1, 2 }
& (Join-Path $here 'Run.ps1') -System $hostSys -Role host -Mode $Mode -Test $Test -Sim $Sim -Buffer $Buffer -NoTrace:(-not $Trace) | Out-Null
Start-Sleep 3
& (Join-Path $here 'Run.ps1') -System $joinSys -Role join -Peer 127.0.0.1 -Mode $Mode -Test $Test -Sim $Sim -Buffer $Buffer -Skew $Skew -NoTrace:(-not $Trace) | Out-Null
Start-Sleep $BootSeconds
foreach ($s in 1, 2) { & (Join-Path $here 'Press.ps1') -System $s -Key Enter | Out-Null }
Start-Sleep $Seconds

foreach ($s in 1, 2) {
    & (Join-Path $here 'Shot.ps1') -System $s -Out (Join-Path $root "LabData\Sys$s\auto_end.png") | Out-Null
    $alive = [bool](Get-Process -Id (GamePid $s) -ErrorAction SilentlyContinue)
    "=== System $s (alive: $alive)"
    Get-Content (Log $s) | Where-Object { $_ -match 'menu: (auto|page lobby)|net: |session: |flow: (step|world|confirm|gave|in the|activity|mode)|arena: |presence: |G\d|ERROR' } |
        ForEach-Object { ($_ -replace '^\S+ \[TailCoop:\d\] ', '') -replace '\(title menu .*\)', '' }
}
