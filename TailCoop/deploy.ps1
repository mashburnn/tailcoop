# deploy.ps1 - install the current TailCoop build into both lab systems (identical copies).
#   .\TailCoop\deploy.ps1            # Lua scripts (+ dlls\main.dll once the C++ module is built)
# A game must be closed for the DLL to be replaced; Lua scripts can be copied while it runs.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $PSScriptRoot 'lua\Scripts'
$dll = Join-Path $PSScriptRoot 'cpp\build\TailCoopNative.dll'

# UE4SS loads main.lua without skipping a UTF-8 byte order mark (the mod then doesn't start at all): strip any.
Get-ChildItem (Join-Path $src '*.lua') | ForEach-Object {
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        [System.IO.File]::WriteAllBytes($_.FullName, $bytes[3..($bytes.Length - 1)])
        Write-Warning "removed a byte order mark from $($_.Name)"
    }
}

foreach ($game in 'Sifu_Lab', 'Sifu_Lab2') {
    # UE4SS experimental builds keep Mods under ue4ss\, the 3.0.1 release keeps it next to the exe.
    $win64 = Join-Path $root "$game\Sifu\Binaries\Win64"
    $mods = if (Test-Path (Join-Path $win64 'ue4ss\Mods')) { Join-Path $win64 'ue4ss\Mods' } else { Join-Path $win64 'Mods' }
    $dst = Join-Path $mods 'TailCoop'
    New-Item -ItemType Directory -Force (Join-Path $dst 'Scripts') | Out-Null
    Copy-Item (Join-Path $src '*.lua') (Join-Path $dst 'Scripts') -Force
    if (Test-Path $dll) {
        # Not in dlls\: UE4SS would try to start anything there as a UE4SS C++ mod. Lua loads it itself.
        New-Item -ItemType Directory -Force (Join-Path $dst 'native') | Out-Null
        $target = Join-Path $dst 'native\TailCoopNative.dll'
        $same = (Test-Path $target) -and ((Get-FileHash $target).Hash -eq (Get-FileHash $dll).Hash)
        if (-not $same) {
            try { Copy-Item $dll $target -Force -ErrorAction Stop }
            catch { Write-Warning "$game is running with an older TailCoopNative.dll; close it and deploy again" }
        }
    }
    # UE4SS layout fix for Sifu's UObject vtable (without it, Lua UFunction calls do nothing). It belongs in the
    # UE4SS directory, which is the parent of Mods for both UE4SS layouts.
    Copy-Item (Join-Path $PSScriptRoot 'ue4ss-config\VTableLayout.ini') (Split-Path $mods) -Force

    # Enable the mod (before the built-in Keybinds entry, which must stay last).
    $modsTxt = Join-Path $mods 'mods.txt'
    $lines = Get-Content $modsTxt | Where-Object { $_ -notmatch '^\s*TailCoop\s*:' }
    $at = [array]::IndexOf($lines, ($lines | Where-Object { $_ -match '^; Built-in keybinds' } | Select-Object -First 1))
    if ($at -lt 0) { $at = $lines.Count }
    $lines = @($lines[0..($at - 1)]) + 'TailCoop : 1' + @($lines[$at..($lines.Count - 1)])
    Set-Content $modsTxt $lines -Encoding ascii
    "deployed to $game ($((Get-ChildItem (Join-Path $dst 'Scripts')).Count) scripts$(if (Test-Path $dll) { ' + dll' }))"

    # A running game keeps the Lua it loaded at startup: say so, or a stale window looks like a bug.
    $exe = Join-Path $win64 'Sifu-Win64-Shipping.exe'
    $running = Get-CimInstance Win32_Process -Filter "Name='Sifu-Win64-Shipping.exe'" |
        Where-Object { $_.ExecutablePath -eq $exe }
    foreach ($p in $running) {
        Write-Warning "$game is running (PID $($p.ProcessId)) with the code it started with: restart it to load this deploy"
    }
}
