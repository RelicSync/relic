# install-sift.ps1 — zero-setup install of Relic's classification pipeline.
# Builds + installs the `sift` CLI, pre-downloads the local models, and runs
# the self-test. Idempotent; re-run any time.
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$cargo = Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe"
if (-not (Test-Path $cargo)) { $cargo = "cargo" }   # fall back to PATH

Write-Host "[1/3] installing sift (cargo install)…"
& $cargo install --path (Join-Path $repo "relic-sift") --locked
if ($LASTEXITCODE -ne 0) { throw "cargo install failed" }

$sift = Join-Path $env:USERPROFILE ".cargo\bin\sift.exe"
if (-not (Test-Path $sift)) { $sift = "sift" }

Write-Host "[2/3] downloading models (one-time, ~750 MB)…"
& $sift models download
if ($LASTEXITCODE -ne 0) { throw "model download failed" }

Write-Host "[3/3] verifying…"
& $sift doctor
if ($LASTEXITCODE -ne 0) { throw "sift doctor failed" }

Write-Host ""
Write-Host "sift is ready. Try:"
Write-Host '  sift classify --text "AKIAIOSFODNN7EXAMPLE"'
Write-Host '  sift classify some_image.png'
Write-Host '  sift eval relic-sift\corpus\manifest.json'
