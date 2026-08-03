# Build the relic-sift classification sidecar (`sift.exe`) and bundle it next to
# the built app, so the on-device ML pipeline is available at runtime.
#
# Run AFTER `flutter build windows --release`:
#   pwsh app/tool/build_sidecar.ps1
#
# In dev (running build\...\Release\relic_app.exe directly) the app also finds
# target\release\sift.exe via a relative fallback, so a bare
# `cargo build --release -p relic-sift --bin sift` is enough while iterating.
$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot\..\.."
cargo build --release -p relic-sift --bin sift --manifest-path "$root\Cargo.toml"
$rel = Join-Path $PSScriptRoot "..\build\windows\x64\runner\Release"
if (Test-Path $rel) {
    Copy-Item "$root\target\release\sift.exe" (Join-Path $rel "sift.exe") -Force
    Write-Host "sift.exe bundled into $rel"
} else {
    Write-Host "Release dir not found ($rel) — run 'flutter build windows --release' first."
}
