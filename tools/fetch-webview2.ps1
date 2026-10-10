# Downloads the WebView2 SDK into .deps\webview2, where Package.swift looks for it.
# Run before `swift build` on Windows (build.ps1 already does).
$ErrorActionPreference = 'Stop'
$Version = '1.0.2903.40'
$Root = Split-Path $PSScriptRoot
$Dest = Join-Path $Root '.deps\webview2'
$Stamp = Join-Path $Dest ".version-$Version"
if (Test-Path $Stamp) { exit 0 }

Write-Host "==> Fetching the WebView2 SDK $Version"
if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
New-Item -ItemType Directory -Force $Dest | Out-Null
$Package = Join-Path $env:TEMP "webview2-$Version.zip"
Invoke-WebRequest "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$Version" -OutFile $Package
Expand-Archive $Package -DestinationPath $Dest -Force
Remove-Item $Package
New-Item -ItemType File $Stamp | Out-Null
