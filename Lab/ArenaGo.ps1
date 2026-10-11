# ArenaGo.ps1 - co-op Arena entry: session in mode arena, one player picks a challenge in the list and presses Start,
# the other game must follow both (tc_devtests arenago). Screenshots of both windows at the end.
#   .\Lab\ArenaGo.ps1 [-Batch 0] [-Challenge 0] [-Picker host|join] [-Swap]
param([int]$Batch = 0, [int]$Challenge = 0, [ValidateSet('host', 'join')][string]$Picker = 'host', [switch]$Swap,
      [string]$Test = 'arenago', [int]$Play = 30, [int]$Seconds = 0,
      [string]$Sim = '', [long]$Skew = 0,  # two-PC-like: -Sim "loss%,delayMs,jitterMs" -Skew <ms the joiner's clock is ahead>
      [ValidateSet('', 'shared', 'each')][string]$Turns = '',  # enemies' attack turns (TailCoop.ini turns)
      [string]$Extra = '')  # more TailCoop.ini lines, ';'-separated (e.g. 'hidetargets = 0')
if ($Seconds -le 0) { $Seconds = $Play + 80 }

$here = $PSScriptRoot
$root = Split-Path -Parent $here
foreach ($s in 1, 2) {
    $ini = Join-Path $root "Sifu_Lab$(if ($s -eq 2) { '2' })\Sifu\Binaries\Win64\ue4ss\Mods\TailCoop\TailCoop.ini"
    Set-Content $ini -Encoding ascii -Value (@("arenabatch = $Batch", "arenachallenge = $Challenge", "arenapicker = $Picker",
        "arenaseconds = $Play") + $(if ($Turns) { @("turns = $Turns") } else { @() }) + $(if ($Extra) { $Extra.Split(';') | ForEach-Object { $_.Trim() } } else { @() }))
}
& (Join-Path $here 'CoopAuto.ps1') -Mode arena -Test $Test -Seconds $Seconds -Swap:$Swap -Sim $Sim -Skew $Skew | Out-Null
foreach ($s in 1, 2) {
    "=== System $s"
    Get-Content (Join-Path $root "LabData\Sys$s\TailCoop.log") |
        Where-Object { $_ -match 'ARENAGO|arena: |flow: (step|world|in the|already|activity|gave)|session: (connected|host picked)|ERROR|presence: (partner (appeared|copy)|spawned|puppet)' } |
        ForEach-Object { $_ -replace '^(\S+) \[TailCoop:\d\] ', '$1 ' }
}


