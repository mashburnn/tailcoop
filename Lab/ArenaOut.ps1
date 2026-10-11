# ArenaOut.ps1 - A6: a player out of a co-op Arena challenge watches the partner; it fails only when both are out.
# Session in challenge (Batch, Challenge); the joiner is aged to the limit and dies (out: hidden, camera on the host,
# enemies all on the host, no failure anywhere); later the host too (failure on both).
#   .\Lab\ArenaOut.ps1 [-Batch 0] [-Challenge 0]
param([int]$Batch = 0, [int]$Challenge = 0)
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$job = Start-Job -ScriptBlock { & (Join-Path $using:here 'ArenaGo.ps1') -Batch $using:Batch -Challenge $using:Challenge -Play 400 | Out-Null }
# The previous run's logs are still there until the new games start: wait for those to be replaced first.
Start-Sleep 20
$deadline = (Get-Date).AddSeconds(160)
do {
    Start-Sleep 5
    $started = foreach ($s in 1, 2) {
        [bool](Select-String -Path (Join-Path $root "LabData\Sys$s\TailCoop.log") -Pattern 'ARENAGO: started' -Quiet -ErrorAction SilentlyContinue)
    }
} until (-not ($started -contains $false) -or (Get-Date) -gt $deadline)
Start-Sleep 12
# Joiner: on its last life (age 69), then a fatal amount of damage, as from an enemy's blow.
& (Join-Path $here 'Cmd.ps1') -System 2 -Lua 'U.playerController().Pawn:BPF_GetStatsComponent():BPF_SetCharacterAge(69); return "aged 69"' -WaitSeconds 2
$hit = 'local pawn = U.playerController().Pawn; local hc = pawn.m_HealthComponent; hc:BPF_ApplyDamage(1000); return "damage 1000, health now " .. tostring(hc.m_fHealth)'
& (Join-Path $here 'Cmd.ps1') -System 2 -Lua $hit -WaitSeconds 2
# Host (the joiner out): a real death on its last life.
$kill = 'local pawn = U.playerController().Pawn; local sc = pawn:BPF_GetStatsComponent(); sc:BPF_SetCharacterAge(69); pawn:ServerSuicide(false); return "aged 69, died"'
Start-Sleep 16
foreach ($s in 1, 2) { & (Join-Path $here 'Shot.ps1') -System $s -Out (Join-Path $root "LabData\Sys$s\arenaout_joiner_out.png") | Out-Null }
Start-Sleep 10
& (Join-Path $here 'Cmd.ps1') -System 1 -Lua $kill -WaitSeconds 2
Start-Sleep 25
foreach ($s in 1, 2) { & (Join-Path $here 'Shot.ps1') -System $s -Out (Join-Path $root "LabData\Sys$s\arenaout_both_out.png") | Out-Null }
foreach ($s in 1, 2) {
    "=== System $s"
    Get-Content (Join-Path $root "LabData\Sys$s\TailCoop.log") |
        Where-Object { $_ -match 'arena: (we|our|the partner|partner|both|host)|CMD|presence: puppet|ERROR' -and $_ -notmatch 'hooked' } |
        ForEach-Object { $_ -replace '^(\S+) \[TailCoop:\d\] ', '$1 ' }
}
Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue
