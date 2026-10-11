# Run.ps1 - launch System 1 or System 2 of the local co-op lab.
#
#   .\Lab\Run.ps1 -System 1                         # plain launch (title screen, CO-OP menu)
#   .\Lab\Run.ps1 -System 1 -Role host              # dev shortcut: auto-host
#   .\Lab\Run.ps1 -System 2 -Role join -Peer 127.0.0.1
#   .\Lab\Run.ps1 -System 2 -Role join -Peer 100.x.y.z   # through this PC's Tailscale address (tailscale ip -4)
#
# Each system runs its own game copy (Sifu_Lab / Sifu_Lab2) with its own profile folder
# (LabData\Sys1 / Sys2, via UE's -userdir), so saves and config never touch %LOCALAPPDATA%\Sifu or each other.
# The TailCoop Lua mod reads the -TailCoop* switches from the command line.
param(
    [Parameter(Mandatory = $true)][ValidateSet(1, 2)][int]$System,
    [ValidateSet('none', 'host', 'join')][string]$Role = 'none',
    [string]$Peer = '127.0.0.1',
    [int]$Port = 7777,
    [ValidateSet('training', 'arena', 'pvp', 'story')][string]$Mode = 'training',
    [string]$Test = '',
    [string]$Bind = '',   # host bind address; default: 127.0.0.1 when -Peer is 127.0.0.1, else this PC's Tailscale IP
    [string]$Sim = '',    # test network impairment of this system's outgoing packets: "loss%,delayMs,jitterMs"
    [ValidateSet('adaptive', 'fixed')][string]$Buffer = 'adaptive',  # copies' playback lag (fixed = the old 100 ms)
    [long]$Skew = 0,      # ms this game's clock runs ahead, as if on another PC (the two lab games share one clock)
    [switch]$NoTrace,
    [int]$Width = 1280,
    [int]$Height = 720,

    [ValidateSet('left', 'main')][string]$Monitor = 'left'
)

$root = Split-Path -Parent $PSScriptRoot
$game = if ($System -eq 1) { 'Sifu_Lab' } else { 'Sifu_Lab2' }
$exe = Join-Path $root "$game\Sifu\Binaries\Win64\Sifu-Win64-Shipping.exe"
$userDir = Join-Path $root "LabData\Sys$System"
New-Item -ItemType Directory -Force $userDir | Out-Null

# Side by side: System 1 on the left, System 2 on the right.
# Both on the left monitor (x -2560..0): System 1 at its left edge, System 2 ending at its right edge (the frames
# overlap a little: two 1280 windows plus borders are wider than 2560). -Monitor main: the old place on the main one.
# (No monitor left of the main one - e.g. a remote session with one screen: the main one.)
Add-Type -AssemblyName System.Windows.Forms
if (-not ([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.X -lt 0 })) { $Monitor = 'main' }
$x = if ($Monitor -eq 'main') { if ($System -eq 1) { 20 } else { 40 + $Width } }
     else { if ($System -eq 1) { -2560 } else { -16 - $Width } }
$y = 80

$gameArgs = @(
    '-windowed', "-ResX=$Width", "-ResY=$Height", "-WinX=$x", "-WinY=$y",
    "-userdir=`"$userDir`"",
    "-TailCoopSystem=$System", "-TailCoopRole=$Role", "-TailCoopPeer=$Peer",
    "-TailCoopPort=$Port", "-TailCoopMode=$Mode"
)
if ($Test) { $gameArgs += "-TailCoopTest=$Test" }
# Per-launch settings for the TailCoop Lua mod (the engine's command line is not readable early enough).
$win64 = Join-Path $root "$game\Sifu\Binaries\Win64"
$mods = if (Test-Path (Join-Path $win64 'ue4ss\Mods')) { Join-Path $win64 'ue4ss\Mods' } else { Join-Path $win64 'Mods' }
$modDir = Join-Path $mods 'TailCoop'
New-Item -ItemType Directory -Force $modDir | Out-Null
Set-Content (Join-Path $modDir 'launch.ini') -Encoding ascii -Value @(
    "system = $System", "role = $Role", "peer = $Peer", "port = $Port", "mode = $Mode", "test = $Test",
    "userdir = $userDir", "trace = $(if ($NoTrace) { 0 } else { 1 })", "bind = $Bind", "sim = $Sim",
    "buffer = $Buffer", "skew = $Skew"
)

$p = Start-Process -FilePath $exe -ArgumentList $gameArgs -WorkingDirectory (Split-Path $exe) -PassThru
$gamePid = $p.Id
# The game can restart itself under a new PID: record the newest process of this exe once it has settled.
Start-Sleep 2
$newest = Get-CimInstance Win32_Process -Filter "Name='Sifu-Win64-Shipping.exe'" | Where-Object { $_.ExecutablePath -eq $exe } |
    Sort-Object CreationDate -Descending | Select-Object -First 1
if ($newest) { $gamePid = $newest.ProcessId }
Set-Content (Join-Path $userDir 'game.pid') $gamePid
"System $System ($game) started: PID $gamePid, role=$Role peer=${Peer}:$Port mode=$Mode"
"Profile: $userDir"
