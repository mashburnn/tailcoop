# package.ps1 - the player download: one zip whose contents are pasted into Sifu\Binaries\Win64 (the folder with
# Sifu-Win64-Shipping.exe). It holds UE4SS (the loader, MIT), its settings tuned for Sifu, and the mod.
#   .\TailCoop\package.ps1 [-Version 0.1.0] [-NoBuild]   -> dist\TailCoop-<Version>.zip
param([string]$Version = '0.1.0', [switch]$NoBuild)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$ue4ss = Join-Path $root 'Tools\UE4SS-experimental'

# The UE4SS build the mod was tested with (v3.0.1 Beta, git 5418fa4e): TailCoopNative.dll links against its exports
# (cpp\UE4SS.def), another build may not load it.
$expected = @{
    'dwmapi.dll'      = 'A29DD4F014DC47DC842DE32B0A939D5FACA7130D7399E5594E23EE4AFBAFBACA'
    'ue4ss\UE4SS.dll' = 'F176DC36FD2BC7B8211DDE6BA54ADE6F66DA5C8F3A79E3017A85B45C215E8242'
}
foreach ($f in $expected.Keys) {
    $h = (Get-FileHash (Join-Path $ue4ss $f)).Hash
    if ($h -ne $expected[$f]) { throw "$f is not the tested UE4SS build ($h)" }
}

if (-not $NoBuild) { & (Join-Path $PSScriptRoot 'cpp\build.ps1') | Out-Null }
$dll = Join-Path $PSScriptRoot 'cpp\build\TailCoopNative.dll'

$dist = Join-Path $root 'dist'
$out = Join-Path $dist "TailCoop-$Version"
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
$mod = Join-Path $out 'ue4ss\Mods\TailCoop'
foreach ($d in 'ue4ss\Mods\shared\UEHelpers', 'ue4ss\Mods\TailCoop\Scripts', 'ue4ss\Mods\TailCoop\native') {
    New-Item -ItemType Directory -Force (Join-Path $out $d) | Out-Null
}

Copy-Item (Join-Path $ue4ss 'dwmapi.dll') $out
Copy-Item (Join-Path $ue4ss 'ue4ss\UE4SS.dll') (Join-Path $out 'ue4ss')
Copy-Item (Join-Path $ue4ss 'ue4ss\LICENSE') (Join-Path $out 'ue4ss\LICENSE')
Copy-Item (Join-Path $ue4ss 'ue4ss\Mods\shared\UEHelpers\UEHelpers.lua') (Join-Path $out 'ue4ss\Mods\shared\UEHelpers')
Copy-Item (Join-Path $PSScriptRoot 'ue4ss-config\UE4SS-settings.ini') (Join-Path $out 'ue4ss')
Copy-Item (Join-Path $PSScriptRoot 'ue4ss-config\VTableLayout.ini') (Join-Path $out 'ue4ss')
# (Not the development-only scripts: main.lua loads them only in development builds.)
Copy-Item (Join-Path $PSScriptRoot 'lua\Scripts\*.lua') (Join-Path $mod 'Scripts') -Exclude 'tc_devtests.lua', 'tc_trace.lua'
Copy-Item $dll (Join-Path $mod 'native')
# UE4SS starts any mod folder with an enabled.txt: no mods.txt to edit.
Set-Content (Join-Path $mod 'enabled.txt') -Encoding ascii -Value 'TailCoop'
Set-Content (Join-Path $mod 'TailCoop.ini') -Encoding ascii -Value @(
    '; TailCoop settings (all optional). Remove the ";" in front of a line to use it.',
    ';',
    '; The host''s Tailscale address, shown in CO-OP > JOIN GAME when the tailnet can''t be listed:',
    '; peer = 100.x.y.z',
    '; UDP port the host listens on (both players must use the same):',
    '; port = 7777',
    '; Enemies take turns attacking the two players (shared), or attack each player as in single player (each):',
    '; turns = shared'
)
Copy-Item (Join-Path $PSScriptRoot 'TailCoop-README.txt') $out

# The game reads Lua with or without a byte order mark, but UE4SS doesn't start main.lua with one (deploy.ps1).
Get-ChildItem (Join-Path $mod 'Scripts') -Filter *.lua | ForEach-Object {
    $b = [IO.File]::ReadAllBytes($_.FullName)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { throw "$($_.Name) has a byte order mark" }
}

$zip = Join-Path $dist "TailCoop-$Version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
# (.NET's writer: entry paths with "/" - Compress-Archive in PowerShell 5 writes "\", which some unzip tools keep as
# part of the file name.)
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem $out -Recurse -File | ForEach-Object {
        $name = $_.FullName.Substring($out.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $name,
            [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally { $archive.Dispose() }
Get-Item $zip | Select-Object FullName, Length
