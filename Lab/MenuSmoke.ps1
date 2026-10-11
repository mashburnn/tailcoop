# MenuSmoke.ps1 - G2b smoke test of the CO-OP title menu on one lab system.
# Boots the system, walks CO-OP > HOST GAME > TRAINING ROOM > (lobby) > Back x3, and reports what the mod logged.
#   .\Lab\MenuSmoke.ps1 -System 1
param([Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$System, [int]$BootSeconds = 50)

$here = $PSScriptRoot
$log = Join-Path (Split-Path -Parent $here) "LabData\Sys$System\TailCoop.log"
$shots = Join-Path (Split-Path -Parent $here) "LabData\Sys$System"

$old = Join-Path (Split-Path -Parent $here) "LabData\Sys$System\game.pid"
if (Test-Path $old) { Stop-Process -Id ([int](Get-Content $old)) -Confirm:$false -ErrorAction SilentlyContinue; Start-Sleep 3 }
Remove-Item $log -ErrorAction SilentlyContinue

& (Join-Path $here 'Run.ps1') -System $System -NoTrace | Out-Null
Start-Sleep $BootSeconds
$gamePid = [int](Get-Content $old)
function Alive { [bool](Get-Process -Id $gamePid -ErrorAction SilentlyContinue) }
if (-not (Alive)) { "FAIL: crashed during boot"; exit 1 }

function Step($label, [string[]]$keys, $delay = 1500) {
    Add-Content $log "---- $label"
    & (Join-Path $here 'Press.ps1') -System $System -Key $keys -DelayMs $delay | Out-Null
}
Step 'press start' @('Enter') 2500
Step 'close story submenu' @('Back')
Step 'focus CO-OP' @('Down')
Step 'open CO-OP' @('Enter')
& (Join-Path $here 'Shot.ps1') -System $System -Out (Join-Path $shots 'smoke_coop.png') | Out-Null
Step 'HOST GAME' @('Enter')
Step 'TRAINING ROOM' @('Enter')
& (Join-Path $here 'Shot.ps1') -System $System -Out (Join-Path $shots 'smoke_lobby.png') | Out-Null
Step 'back x3' @('Back', 'Back', 'Back')
& (Join-Path $here 'Shot.ps1') -System $System -Out (Join-Path $shots 'smoke_back.png') | Out-Null

$lines = Get-Content $log | Where-Object { $_ -match 'menu: (page|activated|back)|^----|ERROR' }
$lines
$pages = ($lines | Where-Object { $_ -match 'menu: page' } | ForEach-Object { ($_ -split 'page ')[1] }) -join ' > '
"pages: $pages"
"alive: $(Alive)"
if ((Alive) -and $pages -eq 'root > host > lobby_host > host > root' -and ($lines -match 'activated CO-OP')) {
    "PASS (menu closes on the third Back: check smoke_back.png shows the original title menu)"
} else { "CHECK: unexpected sequence" }
