# HitTest.ps1 - co-op hit sync check: session in Free Training, the joiner is placed at the dummy and punches with
# real input; reports what crossed (hits sent by the joiner / applied on the host), failures, errors and crashes.
#   .\Lab\HitTest.ps1 [-Swap] [-Sim "5,100,20"] [-Punches 12] [-HostPunches 0]
param([switch]$Swap, [string]$Sim = '', [int]$Punches = 12, [int]$HostPunches = 0, [int]$Seconds = 28)

$here = $PSScriptRoot
$root = Split-Path -Parent $here
$hostSys, $joinSys = if ($Swap) { 2, 1 } else { 1, 2 }
function Log($s) { Join-Path $root "LabData\Sys$s\TailCoop.log" }
function Alive($s) { [bool](Get-Process -Id ([int](Get-Content (Join-Path $root "LabData\Sys$s\game.pid"))) -ErrorAction SilentlyContinue) }

& (Join-Path $here 'CoopAuto.ps1') -Test approach -Seconds $Seconds -Sim $Sim -Swap:$Swap | Out-Null
if (-not ((Alive 1) -and (Alive 2))) { "a game died during startup (1: $(Alive 1), 2: $(Alive 2))"; exit 1 }

$clicks = (1..$Punches | ForEach-Object { 'click;wait 380' }) -join ';'
if ($HostPunches -gt 0) {
    # Both at once: the host punches from a background job while the joiner punches here.
    $hostClicks = (1..$HostPunches | ForEach-Object { 'click;wait 380' }) -join ';'
    $job = Start-Job -ScriptBlock { param($d, $s, $c) Set-Location $d; & ".\Lab\Input.ps1" -System $s -Script $c } `
        -ArgumentList $root, $hostSys, $hostClicks
}
& (Join-Path $here 'Input.ps1') -System $joinSys -Script $clicks | Out-Null
if ($job) { Receive-Job $job -Wait | Out-Null }
Start-Sleep 22   # the next 20 s stats line

"=== host = System $hostSys (alive: $(Alive $hostSys)), joiner = System $joinSys (alive: $(Alive $joinSys))"
foreach ($s in $hostSys, $joinSys) {
    $lines = Get-Content (Log $s)
    "--- System $s"
    $lines | Select-String 'enemies: (host|join),' | Select-Object -Last 1 | ForEach-Object { $_.Line.Substring(22) }
    $lines | Select-String 'ERROR|FAILED|unreadable|no such enemy|isn''t here|can''t watch|sending our hit failed|crashed' |
        Select-Object -First 8 | ForEach-Object { $_.Line.Substring(9) }
}
