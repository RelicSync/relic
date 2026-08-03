<#
  Submit the current release to winget (microsoft/winget-pkgs) as a version
  update of the existing Relic.Relic package.

  Run this AFTER the versioned installer is uploaded to R2 and serving at
  https://relic.space/download/windows/relic-setup-<version>.exe, because
  wingetcreate downloads that URL to compute the manifest sha256. It is the
  last publish step in build_release.ps1's checklist.

  Usage:
    .\submit_winget.ps1                 # version from pubspec.yaml, PR submitted
    .\submit_winget.ps1 -Version 1.0.17 # explicit version
    .\submit_winget.ps1 -DryRun         # generate + validate manifests, no PR

  Auth: a GitHub token with public_repo scope. Taken from -Token, else
  `gh auth token` (the gh CLI login), else wingetcreate's own cached login.

  Gotchas learned submitting 1.0.17 (PR #402901):
  - --display-version is required: the AppsAndFeaturesEntries DisplayVersion
    does not auto-update from the package version.
  - The URL needs the "|x64|user" override: the Inno bootstrapper is an x86
    exe, so wingetcreate fingerprints it as X86 and then can't match the
    manifest's existing x64/user installer node.
  - relic.space/download/* 404s on HEAD requests; liveness must be a GET.
  - Never overwrite a published relic-setup-<ver>.exe in R2: winget
    re-validates the sha256 recorded in the merged manifest.
#>
param(
  [string]$Version = "",
  [string]$Token = "",
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$appDir = Split-Path -Parent $PSScriptRoot   # ...\relic\app

# 1. Version: single source of truth is pubspec.yaml (same as build_release.ps1)
if (-not $Version) {
  $verMatch = Select-String -Path (Join-Path $appDir "pubspec.yaml") `
    -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)' | Select-Object -First 1
  if (-not $verMatch) { throw "Could not read 'version:' from pubspec.yaml" }
  $Version = $verMatch.Matches[0].Groups[1].Value
}
$url = "https://relic.space/download/windows/relic-setup-$Version.exe"
Write-Host "==> winget update Relic.Relic -> $Version" -ForegroundColor Cyan
Write-Host "    installer: $url"

# 2. The installer must already be live (GET, not HEAD: the route 404s on HEAD)
$code = & curl.exe -s -o NUL -w "%{http_code}" -r 0-0 $url
if ($code -ne "200") {
  throw "Installer not live at $url (HTTP $code). Upload it to R2 first (build_release.ps1 step 1), then re-run."
}
Write-Host "    installer is live (HTTP 200)" -ForegroundColor Green

# 3. wingetcreate
$wc = Get-Command wingetcreate -ErrorAction SilentlyContinue
if (-not $wc) {
  throw "wingetcreate not found. Install it: winget install Microsoft.WingetCreate"
}

# 4. Token: explicit param, else the gh CLI's login
if (-not $Token) {
  $gh = Get-Command gh -ErrorAction SilentlyContinue
  if ($gh) {
    try { $Token = (& gh auth token 2>$null) } catch {}
  }
}

$wcArgs = @(
  "update", "Relic.Relic",
  "--version", $Version,
  "--display-version", $Version,
  "--urls", "$url|x64|user"
)
if ($Token) { $wcArgs += @("--token", $Token) }
if (-not $DryRun) { $wcArgs += "--submit" }

& wingetcreate @wcArgs
if ($LASTEXITCODE -ne 0) { throw "wingetcreate failed (exit $LASTEXITCODE)" }

# wingetcreate leaves the generated manifests in .\manifests; they live in the
# PR now, so don't let them clutter the repo checkout.
$stray = Join-Path (Get-Location) "manifests"
if (Test-Path $stray) { Remove-Item $stray -Recurse -Force -Confirm:$false }

if ($DryRun) {
  Write-Host "Dry run done (manifests validated, no PR submitted)." -ForegroundColor Green
} else {
  Write-Host "PR submitted. Updates to an existing package usually auto-merge" -ForegroundColor Green
  Write-Host "after validation (hours to ~2 days); watch: gh pr list -R microsoft/winget-pkgs --author @me" -ForegroundColor Gray
}
