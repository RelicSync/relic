# M5 smoke test: boots the Worker locally (wrangler dev + local R2/D1),
# seeds the schema and a dev token, then drives the Rust client flow
# (relic-core/examples/smoke.rs) against it.
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$workerDir = Join-Path $root "worker"
$token = "relic-dev-token"

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    $env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
}

# token_hash = sha256(token), matching the Worker's auth
$sha = [System.Security.Cryptography.SHA256]::Create()
$hash = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($token)) | ForEach-Object { $_.ToString("x2") }) -join ""

Push-Location $workerDir
try {
    if (-not (Test-Path "node_modules")) { npm install --no-audit --no-fund | Out-Null }

    # fresh local state each run so the smoke test is deterministic
    if (Test-Path ".wrangler/state") { Remove-Item -Recurse -Force ".wrangler/state" }

    npx wrangler d1 execute relic --local --file=schema.sql | Out-Null
    npx wrangler d1 execute relic --local --command="INSERT INTO tokens (token_hash, account_id, device_label, tier) VALUES ('$hash', 'smoke-account', 'smoke', 'free')" | Out-Null

    $devLog = Join-Path $workerDir "dev-out.log"
    $devErr = Join-Path $workerDir "dev-err.log"
    $wrangler = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "npx wrangler dev --port 8787" `
        -WorkingDirectory $workerDir -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $devLog -RedirectStandardError $devErr

    # wait for the Worker to come up (auth'd request → any HTTP answer counts)
    $up = $false
    foreach ($i in 1..90) {
        Start-Sleep -Seconds 1
        try {
            Invoke-WebRequest -Uri "http://127.0.0.1:8787/account" -Headers @{ Authorization = "Bearer $token" } -UseBasicParsing -TimeoutSec 2 | Out-Null
            $up = $true; break
        } catch {
            if ($_.Exception.Response) { $up = $true; break }  # responded with an error status = up
        }
    }
    if (-not $up) {
        Write-Host "--- wrangler stdout ---"; Get-Content $devLog -ErrorAction SilentlyContinue | Select-Object -Last 20
        Write-Host "--- wrangler stderr ---"; Get-Content $devErr -ErrorAction SilentlyContinue | Select-Object -Last 20
        throw "wrangler dev did not come up on :8787"
    }

    $env:RELIC_URL = "http://127.0.0.1:8787"
    $env:RELIC_TOKEN = $token
    Push-Location $root
    cargo run -p relic-core --example smoke
    $code = $LASTEXITCODE
    Pop-Location
    exit $code
}
finally {
    if ($wrangler -and -not $wrangler.HasExited) { taskkill /PID $wrangler.Id /T /F 2>$null | Out-Null }
    # wrangler dev spawns workerd children; sweep any stragglers
    Get-Process -Name "workerd" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Pop-Location
}
