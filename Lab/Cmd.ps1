# Cmd.ps1 - run a Lua snippet in a running lab game (tc_devtests lab console) and show what it returned.
#   .\Lab\Cmd.ps1 -System 2 -Lua 'return require("tc_arena").current()'
param([Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$System, [Parameter(Mandatory = $true)][string]$Lua,
      [int]$WaitSeconds = 4)
$root = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $root "LabData\Sys$System"
$log = Join-Path $dir 'TailCoop.log'
$before = (Get-Content $log -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
[IO.File]::WriteAllText((Join-Path $dir 'cmd.lua'), $Lua)
Start-Sleep $WaitSeconds
Get-Content $log | Select-Object -Skip $before | Where-Object { $_ -match 'CMD: |ERROR' } | ForEach-Object { $_ -replace '^(\S+) \[TailCoop:\d\] ', '$1 ' }
