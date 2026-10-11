# CoopMenuFlow.ps1 - both lab systems through the CO-OP menu, driven by keyboard only:
#   System 1: CO-OP > HOST GAME > TRAINING ROOM (lobby, waiting)
#   System 2: CO-OP > JOIN GAME > JOIN THIS PC (lobby, connected)
#   System 1: START TRAINING ROOM -> both enter the Training Room
# Screenshots land in LabData\Sys1|2\flow_*.png.
param([int]$BootSeconds = 50, [switch]$NoStart, [string]$Test = '', [int]$AfterStartSeconds = 45)

$here = $PSScriptRoot
$root = Split-Path -Parent $here
function Log($s) { "LabData\Sys$s\TailCoop.log" | ForEach-Object { Join-Path $root $_ } }
function Keys($s, [string[]]$k, $delay = 1300) { & (Join-Path $here 'Press.ps1') -System $s -Key $k -DelayMs $delay | Out-Null }
function Shot($s, $name) { & (Join-Path $here 'Shot.ps1') -System $s -Out (Join-Path $root "LabData\Sys$s\$name.png") | Out-Null }
function Mark($s, $text) { Add-Content (Log $s) "---- $text" }

foreach ($s in 1, 2) {
    $pidFile = Join-Path $root "LabData\Sys$s\game.pid"
    if (Test-Path $pidFile) { Stop-Process -Id ([int](Get-Content $pidFile)) -Confirm:$false -ErrorAction SilentlyContinue }
}
Start-Sleep 4
foreach ($s in 1, 2) { Remove-Item (Log $s) -ErrorAction SilentlyContinue }
# Roles here only label the systems for dev tests (-Test); the session itself is made through the menus.
& (Join-Path $here 'Run.ps1') -System 1 -NoTrace -Test $Test -Role $(if ($Test) { 'host' } else { 'none' }) | Out-Null
Start-Sleep 3
& (Join-Path $here 'Run.ps1') -System 2 -NoTrace -Test $Test -Role $(if ($Test) { 'join' } else { 'none' }) | Out-Null
Start-Sleep $BootSeconds

Mark 1 'host via menu'
Keys 1 @('Enter') 2500
Keys 1 @('Back', 'Down', 'Enter', 'Enter', 'Enter')
Mark 2 'join via menu'
Keys 2 @('Enter') 2500
Keys 2 @('Back', 'Down', 'Enter', 'Down', 'Enter', 'Enter')
Start-Sleep 3
Shot 1 'flow_lobby'
Shot 2 'flow_lobby'
if (-not $NoStart) {
    Mark 1 'START'
    Keys 1 @('Enter')
    Start-Sleep $AfterStartSeconds
    Shot 1 'flow_started'
    Shot 2 'flow_started'
}
foreach ($s in 1, 2) {
    $alive = [bool](Get-Process -Id ([int](Get-Content (Join-Path $root "LabData\Sys$s\game.pid"))) -ErrorAction SilentlyContinue)
    "=== System $s (alive: $alive)"
    Get-Content (Log $s) | Where-Object { $_ -match '^----|menu: (page|activated)|net: |session: |flow: |presence: |G3|ERROR' } |
        ForEach-Object { $_ -replace '^\S+ \[TailCoop:\d\] ', '' }
}
