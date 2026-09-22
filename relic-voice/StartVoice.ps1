param([switch]$UseExistingProfile)
$ErrorActionPreference = 'Stop'
$VoiceRoot = $PSScriptRoot
$AppDirectory = [IO.Path]::GetFullPath((Join-Path $VoiceRoot '..\app\build\windows\x64\runner\Release'))
$AppExe = Join-Path $AppDirectory 'relic_app.exe'
if (-not (Test-Path -LiteralPath $AppExe)) { throw 'Build the Windows app first. See relic-voice/README.md.' }
if (-not (Test-Path -LiteralPath (Join-Path $AppDirectory 'voice\relic-voice.exe'))) { throw 'Build and bundle the Voice worker first.' }
if (-not $UseExistingProfile) {
    $env:RELIC_DATA_DIR = Join-Path $env:LOCALAPPDATA 'RelicVoicePreview'
    New-Item -ItemType Directory -Force -Path $env:RELIC_DATA_DIR | Out-Null
    $PreviewPrefs = Join-Path $env:RELIC_DATA_DIR 'prefs.json'
    if (-not (Test-Path -LiteralPath $PreviewPrefs)) {
        # Keep the preview focused on Voice, with no unrelated AI model download.
        [IO.File]::WriteAllText($PreviewPrefs, '{"ml_enrich":false,"launch_at_login":false}', [Text.UTF8Encoding]::new($false))
    }
}
Start-Process -FilePath $AppExe -ArgumentList '--voice-settings' -WorkingDirectory $AppDirectory
