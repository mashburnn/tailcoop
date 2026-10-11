# FriendlyTest.ps1 - does the joiner's character attack the partner's character? Session in Free Training; the joiner
# stands beside the host's character (facing away from it) and attacks with real input. Reports the joiner's angle to
# the partner over time (90 = didn't turn, ~0 = locked onto the partner) and our hits that landed on it.
#   .\Lab\FriendlyTest.ps1 [-Off] [-Front]
#   -Off: Sifu's own friendly-fire setting, for comparison; -Front: right in front of the partner, facing them
param([switch]$Off, [switch]$Front, [int]$Attacks = 16)

$here = $PSScriptRoot
$root = Split-Path -Parent $here
$test = if ($Off) { 'friendlyoff' } elseif ($Front) { 'friendlyfront' } else { 'friendly' }
& (Join-Path $here 'CoopAuto.ps1') -Test $test -Seconds 23 | Out-Null
$clicks = (1..$Attacks | ForEach-Object { 'click;wait 380' }) -join ';'
& (Join-Path $here 'Input.ps1') -System 2 -Script $clicks | Out-Null
& (Join-Path $here 'Shot.ps1') -System 2 -Out (Join-Path $root "LabData\Sys2\friendly_$test.png") | Out-Null
Start-Sleep 50
"=== $test"
Get-Content (Join-Path $root 'LabData\Sys2\TailCoop.log') |
    Where-Object { $_ -match 'FRIENDLY|own hit landed|friendly fire' } |
    ForEach-Object { $_ -replace '^\S+ \[TailCoop:\d\] ', '' }
