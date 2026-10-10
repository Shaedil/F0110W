# Builds M0110HUD for Windows into build\M0110HUD\, with the Swift runtime included.
# Needs the Swift toolchain for Windows.
#   .\build.ps1             build
#   .\build.ps1 -Install    also install to %LOCALAPPDATA%\Programs\M0110HUD and restart it
#   .\build.ps1 -NoRuntime  leave out the Swift runtime (for a PC with Swift on PATH)
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$NoRuntime
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$Name = 'M0110HUD'
$Out = Join-Path $PSScriptRoot "build\$Name"

& (Join-Path $PSScriptRoot 'tools\fetch-webview2.ps1')
if ($LASTEXITCODE) { exit $LASTEXITCODE }

Write-Host '==> Compiling (release)'
# CodeView debug info, so the .pdb next to the exe names the frames in hang.log.
$Flags = @('-Xswiftc', '-g', '-Xswiftc', '-debug-info-format=codeview', '-Xlinker', '-debug')
swift build -c release --product $Name @Flags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$Bin = (swift build -c release @Flags --show-bin-path).Trim()
$Exe = Join-Path $Bin "$Name.exe"
if (-not (Test-Path $Exe)) { throw "expected executable not found at $Exe" }

Write-Host "==> Assembling $Out"
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force $Out | Out-Null
Copy-Item $Exe $Out
$Pdb = Join-Path $Bin "$Name.pdb"
if (Test-Path $Pdb) { Copy-Item $Pdb $Out }
Copy-Item -Recurse (Join-Path $PSScriptRoot 'WindowsUI') (Join-Path $Out 'ui')
$Built = Join-Path $Out "$Name.exe"

# SwiftPM links executables as console programs, which open a console window
# when started from Explorer or at login. Set the PE subsystem field (68 bytes
# into the optional header, for PE32 and PE32+) to GUI instead.
$bytes = [System.IO.File]::ReadAllBytes($Built)
$pe = [BitConverter]::ToInt32($bytes, 0x3C)
if ([BitConverter]::ToUInt32($bytes, $pe) -ne 0x00004550) { throw "$Built is not a PE file" }
$subsystem = $pe + 4 + 20 + 68
$bytes[$subsystem] = 2      # IMAGE_SUBSYSTEM_WINDOWS_GUI
$bytes[$subsystem + 1] = 0
[System.IO.File]::WriteAllBytes($Built, $bytes)

if (-not $NoRuntime) {
    # Copy every DLL in the runtime folder, since Foundation alone needs several.
    $core = (where.exe swiftCore.dll 2>$null | Select-Object -First 1)
    if (-not $core) { throw 'swiftCore.dll is not on PATH; install the Swift runtime, or pass -NoRuntime' }
    $runtime = Split-Path $core
    Write-Host "==> Bundling the Swift runtime from $runtime"
    Get-ChildItem $runtime -Filter *.dll | Copy-Item -Destination $Out
}

if ($Install) {
    $Target = Join-Path $env:LOCALAPPDATA "Programs\$Name"
    Write-Host "==> Installing $Target"
    $running = Get-Process $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($Target, [StringComparison]::OrdinalIgnoreCase) }
    if ($running) {
        Write-Host '    quitting the running copy'
        $running | Stop-Process -Force
        $running | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
    }
    if (Test-Path $Target) { Remove-Item -Recurse -Force $Target }
    Copy-Item -Recurse $Out $Target
    Start-Process (Join-Path $Target "$Name.exe")
    Write-Host "Installed: $Target\$Name.exe"
    Write-Host "Start it at login from its tray menu, or: & '$Target\$Name.exe' --install"
}

Write-Host ''
Write-Host "Built: $Built"
Write-Host ''
Write-Host 'Try the look without the keyboard:'
Write-Host "  & '$Built' --preview"
Write-Host 'Check what Windows reports for the keyboard (pipe it so PowerShell waits):'
Write-Host "  & '$Built' --ble-probe | Out-Host"
