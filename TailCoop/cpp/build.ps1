# build.ps1 - build TailCoopNative.dll with the VS 2022 Build Tools (x64, Release).
#   .\TailCoop\cpp\build.ps1
# Links against UE4SS.dll through an import library generated from UE4SS.def (UE4SS's exported Lua wrapper).
$ErrorActionPreference = 'Stop'
$vcvars = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) { throw "VS 2022 Build Tools not found ($vcvars)" }
$src = Join-Path $PSScriptRoot 'src'
$out = Join-Path $PSScriptRoot 'build'
$def = Join-Path $PSScriptRoot 'UE4SS.def'
New-Item -ItemType Directory -Force $out | Out-Null
$sources = (Get-ChildItem $src -Filter *.cpp | ForEach-Object { "`"$($_.FullName)`"" }) -join ' '
$cmd = "`"$vcvars`" >nul 2>nul && cd /d `"$out`" && " +
       "lib /nologo /def:`"$def`" /machine:x64 /out:UE4SS.lib >nul && " +
       "cl /nologo /std:c++17 /O2 /MT /EHsc /W4 /LD $sources " +
       "/link /OUT:TailCoopNative.dll UE4SS.lib ws2_32.lib iphlpapi.lib"
cmd /c $cmd
if ($LASTEXITCODE -ne 0) { throw "build failed ($LASTEXITCODE)" }
Get-Item (Join-Path $out 'TailCoopNative.dll') | Select-Object FullName, Length, LastWriteTime
