# install.ps1 — copy the ClaudeSurvivor mod into your Project Zomboid mods folder.
# Usage:  pwsh ./install.ps1
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'mods\ClaudeSurvivor'
$zomboid = Join-Path $env:USERPROFILE 'Zomboid'
$dst = Join-Path $zomboid 'mods\ClaudeSurvivor'

if (-not (Test-Path $src)) { throw "mods\ClaudeSurvivor not found next to this script." }
if (-not (Test-Path $zomboid)) {
  Write-Host "Zomboid folder not found at $zomboid — launch Project Zomboid once to create it." -ForegroundColor Yellow
}

New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
Copy-Item $src $dst -Recurse -Force
# ensure the Lua drop-zone exists for the bridge <-> mod files
New-Item -ItemType Directory -Force (Join-Path $zomboid 'Lua') | Out-Null

Write-Host "Installed -> $dst" -ForegroundColor Green
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "  1. cd bridge; node pz-bridge.mjs   (pick a backend — see bridge/README.md)"
Write-Host "  2. Launch Project Zomboid, enable 'Claude Survivor' in Mods, start a Sandbox game."
Write-Host "  3. Take your hands off the keyboard. Watch http://localhost:8799/mind"
