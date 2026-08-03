<#
  Build a distributable Relic installer (dist\relic-setup-<version>.exe).

  Usage:
    .\build_release.ps1
        Build + package, unsigned (prints "signing skipped" notices).

    # --- Azure Artifact Signing (formerly Trusted Signing) ---
    .\build_release.ps1 -Azure `
        -AzureEndpoint https://eus.codesigning.azure.net `
        -AzureAccount  <trusted-signing-account> `
        -AzureProfile  <certificate-profile>
        Signs via the Trusted Signing dlib. Auth uses the Azure credential
        chain (run 'az login' first, or set AZURE_* service-principal env vars).
        Alternatively pass -AzureMetadata <metadata.json> instead of the three
        endpoint/account/profile params.

    # --- Traditional cert (OV/EV PFX or cert-store subject) ---
    .\build_release.ps1 -CertSubject "Relic Software"
    .\build_release.ps1 -CertPath relic.pfx -CertPassword "..."

  Requires: Flutter, Inno Setup 6 (ISCC.exe). Signing additionally needs
  signtool.exe (Windows SDK). Azure mode also needs the Trusted Signing dlib
  (NuGet 'Microsoft.Trusted.Signing.Client') and an Azure login.
#>
param(
  [string]$CertSubject = "",
  [string]$CertPath = "",
  [string]$CertPassword = "",
  [switch]$Azure,
  [string]$AzureEndpoint = "",
  [string]$AzureAccount = "",
  [string]$AzureProfile = "",
  [string]$AzureDlib = "",
  [string]$AzureMetadata = "",
  [string]$TimestampUrl = ""
)

$ErrorActionPreference = "Stop"
$appDir  = Split-Path -Parent $PSScriptRoot   # ...\relic\app
$repoDir = Split-Path -Parent $appDir         # ...\relic
Set-Location $appDir

# 1. Version: single source of truth is pubspec.yaml
$verMatch = Select-String -Path "pubspec.yaml" -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)' | Select-Object -First 1
if (-not $verMatch) { throw "Could not read 'version:' from pubspec.yaml" }
$ver = $verMatch.Matches[0].Groups[1].Value
Write-Host "==> Building Relic $ver" -ForegroundColor Cyan

# 2. Flutter release build
function Get-Flutter {
  foreach ($n in @("flutter", "flutter.bat")) {
    $cmd = Get-Command $n -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  foreach ($c in @("C:\src\flutter\bin\flutter.bat", "$env:LOCALAPPDATA\flutter\bin\flutter.bat")) {
    if (Test-Path $c) { return $c }
  }
  return $null
}
$flutter = Get-Flutter
if (-not $flutter) { throw "flutter not found on PATH or in known locations" }
Write-Host "==> flutter build windows --release ($flutter)"
& $flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }

$releaseDir = Join-Path $appDir "build\windows\x64\runner\Release"
$exe = Join-Path $releaseDir "relic_app.exe"
if (-not (Test-Path $exe)) { throw "Build output not found: $exe" }

# 2a. Bundle the VC++ runtime beside the exe. Flutter links it dynamically and
# a clean Windows install does NOT have it (winget's validation VM caught all
# three exes dying with STATUS_DLL_NOT_FOUND). The installer recurses this dir
# into {app} and also copies these three into {app}\cli for the PATH-exposed
# CLI (see relic.iss).
$vcDlls = @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")
if ($vcDlls | Where-Object { -not (Test-Path (Join-Path $releaseDir $_)) }) {
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found; cannot locate the VC++ redist DLLs" }
  $crtDir = & $vswhere -latest -products * -find "VC\Redist\MSVC\*\x64\*.CRT" |
    Sort-Object | Select-Object -Last 1
  if (-not $crtDir) { throw "VC++ redist CRT folder not found via vswhere" }
  Write-Host "==> Bundling VC++ runtime from $crtDir"
  foreach ($d in $vcDlls) {
    $src = Join-Path $crtDir $d
    if (-not (Test-Path $src)) { throw "Missing $d in $crtDir" }
    Copy-Item $src (Join-Path $releaseDir $d) -Force
  }
}

# 2b. Build the bundled `relic` CLI (the agent-facing shim over the local vault).
# It ships in its own {app}\cli subdir and goes on PATH (see installer\relic.iss).
Write-Host "==> cargo build --release -p relic-cli --bin relic"
Push-Location $repoDir
try {
  & cargo build --release -p relic-cli --bin relic
  if ($LASTEXITCODE -ne 0) { throw "cargo build (relic-cli) failed" }
} finally { Pop-Location }
$cliExe = Join-Path $repoDir "target\release\relic.exe"
if (-not (Test-Path $cliExe)) { throw "CLI build output not found: $cliExe" }

# 2c. Build the `sift` on-device ML sidecar (relic-sift — the workspace crate;
# relic-sift-next is a stale out-of-workspace experiment). Building from source
# here guarantees the shipped binary matches the current relic-sift. It ships
# beside relic_app.exe so SiftSidecar.locate() finds it; onnxruntime.dll + the
# ONNX models are fetched at first ML use by `sift models download`.
Write-Host "==> cargo build --release -p relic-sift --bin sift"
Push-Location $repoDir
try {
  & cargo build --release -p relic-sift --bin sift
  if ($LASTEXITCODE -ne 0) { throw "cargo build (relic-sift) failed" }
} finally { Pop-Location }
$siftExe = Join-Path $repoDir "target\release\sift.exe"
if (-not (Test-Path $siftExe)) { throw "sift build output not found: $siftExe" }

# --- tool resolvers ---
function Get-SignTool {
  $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $cand = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
  if ($cand) { return $cand.FullName }
  return $null
}

function Get-ISCC {
  $candidates = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Get-AzureDlib {
  if ($AzureDlib -and (Test-Path $AzureDlib)) { return $AzureDlib }
  $base = Join-Path $env:USERPROFILE ".nuget\packages\microsoft.trusted.signing.client"
  if (Test-Path $base) {
    $all = Get-ChildItem $base -Recurse -Filter "Azure.CodeSigning.Dlib.dll" -ErrorAction SilentlyContinue
    # Prefer the x64 dlib (must match the x64 signtool's bitness), newest version.
    $dll = $all | Where-Object { $_.FullName -match '\\x64\\' } |
      Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $dll) { $dll = $all | Sort-Object FullName -Descending | Select-Object -First 1 }
    if ($dll) { return $dll.FullName }
  }
  return $null
}

# Build (or accept) the Trusted Signing metadata file the dlib reads.
function Resolve-AzureMetadata {
  if ($AzureMetadata) {
    if (-not (Test-Path $AzureMetadata)) { throw "AzureMetadata not found: $AzureMetadata" }
    return $AzureMetadata
  }
  if (-not $AzureEndpoint -or -not $AzureAccount -or -not $AzureProfile) {
    throw "Azure signing needs -AzureEndpoint, -AzureAccount and -AzureProfile (or -AzureMetadata <json>)"
  }
  $obj = [ordered]@{
    Endpoint               = $AzureEndpoint
    CodeSigningAccountName = $AzureAccount
    CertificateProfileName = $AzureProfile
  }
  $tmp = Join-Path $env:TEMP "relic-trusted-signing-metadata.json"
  ($obj | ConvertTo-Json) | Set-Content -Path $tmp -Encoding ascii
  return $tmp
}

# --- signing helper. No-op unless -Azure, -CertPath or -CertSubject is given. ---
function Invoke-Sign([string]$file) {
  $leaf = Split-Path $file -Leaf

  if ($Azure) {
    $st = Get-SignTool
    if (-not $st) { throw "signtool.exe not found (install the Windows SDK); cannot sign" }
    $dlib = Get-AzureDlib
    if (-not $dlib) {
      throw "Trusted Signing dlib not found. Install the NuGet package 'Microsoft.Trusted.Signing.Client' (or pass -AzureDlib <path to Azure.CodeSigning.Dlib.dll>)."
    }
    $meta = Resolve-AzureMetadata
    $ts = if ($TimestampUrl) { $TimestampUrl } else { "http://timestamp.acs.microsoft.com" }
    & $st sign /v /fd SHA256 /tr $ts /td SHA256 /dlib $dlib /dmdf $meta $file
    if ($LASTEXITCODE -ne 0) { throw "Azure signtool failed for $leaf" }
    Write-Host "    signed (Azure Artifact Signing) $leaf" -ForegroundColor Green
    return
  }

  if (-not $CertSubject -and -not $CertPath) {
    Write-Host "    (signing skipped for $leaf : no cert configured)" -ForegroundColor DarkYellow
    return
  }
  $st = Get-SignTool
  if (-not $st) { throw "signtool.exe not found (install the Windows SDK); cannot sign" }
  $ts = if ($TimestampUrl) { $TimestampUrl } else { "http://timestamp.digicert.com" }
  $signArgs = @("sign", "/fd", "sha256", "/tr", $ts, "/td", "sha256")
  if ($CertPath) {
    $signArgs += @("/f", $CertPath)
    if ($CertPassword) { $signArgs += @("/p", $CertPassword) }
  } else {
    $signArgs += @("/n", $CertSubject)
  }
  $signArgs += $file
  & $st @signArgs
  if ($LASTEXITCODE -ne 0) { throw "signtool failed for $leaf" }
  Write-Host "    signed $leaf" -ForegroundColor Green
}

# 3. Sign the app exe + the bundled CLI + the sift sidecar (optional)
Write-Host "==> Sign app executable"
Invoke-Sign $exe
Write-Host "==> Sign relic CLI"
Invoke-Sign $cliExe
Write-Host "==> Sign sift sidecar"
Invoke-Sign $siftExe

# 4. Inno Setup
$iscc = Get-ISCC
if (-not $iscc) {
  throw "Inno Setup 6 (ISCC.exe) not found. Install it (free): https://jrsoftware.org/isdl.php"
}
$iss = Join-Path $appDir "installer\relic.iss"
Write-Host "==> ISCC ($iscc)"
& $iscc "/DMyAppVersion=$ver" $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed" }

$installer = Join-Path $repoDir "dist\relic-setup-$ver.exe"
if (-not (Test-Path $installer)) { throw "Installer not produced: $installer" }

# 5. Sign the installer (optional)
Write-Host "==> Sign installer"
Invoke-Sign $installer

Write-Host ""
Write-Host "Done: $installer" -ForegroundColor Green
Write-Host ""
Write-Host "To publish this release:" -ForegroundColor Yellow
Write-Host "  1) Upload the installer to R2 (served at relic.space/download/windows):" -ForegroundColor Yellow
Write-Host "       npx wrangler r2 object put relic-downloads/windows/relic-setup-$ver.exe ``" -ForegroundColor Gray
Write-Host "         --file dist/relic-setup-$ver.exe --content-type application/octet-stream --remote" -ForegroundColor Gray
Write-Host "  2) Bump website/public/latest.json 'version' to $ver AND set" -ForegroundColor Yellow
Write-Host "     platforms.windows.sha256 to the hash below, then deploy the website" -ForegroundColor Yellow
Write-Host "     (push to main triggers deploy-website.yml, or: cd website; npm run deploy)." -ForegroundColor Yellow
Write-Host "     latest.json drives BOTH the in-app updater and the download route;" -ForegroundColor Gray
Write-Host "     without the sha256 the one-click in-app update falls back to the browser." -ForegroundColor Gray
Write-Host "       sha256: $((Get-FileHash $installer -Algorithm SHA256).Hash)" -ForegroundColor Gray
Write-Host "  3) Submit the winget version update (needs the R2 upload from step 1 live," -ForegroundColor Yellow
Write-Host "     since wingetcreate hashes the served installer):" -ForegroundColor Yellow
Write-Host "       .\app\scripts\submit_winget.ps1" -ForegroundColor Gray
Write-Host "     Never overwrite a published relic-setup-<ver>.exe in R2 afterwards;" -ForegroundColor Gray
Write-Host "     winget re-validates the sha256 in the merged manifest." -ForegroundColor Gray
