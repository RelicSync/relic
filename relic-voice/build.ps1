param([string]$OutputDirectory = "")
$ErrorActionPreference = "Stop"
$VoiceRoot = $PSScriptRoot
$RuntimeRevision = "ed3468f3881abb9e7b6c7d404f75049aecccb04f"
$PythonExe = Join-Path $VoiceRoot ".venv\Scripts\python.exe"
$SourceRoot = Join-Path $VoiceRoot "_vendor\transcribe.cpp"
$BuildRoot = Join-Path $VoiceRoot ".build"
function Run-Checked {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed ($LASTEXITCODE)" }
}
if (-not (Test-Path -LiteralPath $PythonExe)) {
    Run-Checked "python" @("-m", "venv", (Join-Path $VoiceRoot ".venv"))
}
Run-Checked $PythonExe @("-m", "pip", "install", "-r", (Join-Path $VoiceRoot "requirements.txt"))
if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot ".git"))) {
    New-Item -ItemType Directory -Force -Path $SourceRoot | Out-Null
    Run-Checked "git" @("init", $SourceRoot)
    Run-Checked "git" @("-C", $SourceRoot, "remote", "add", "origin", "https://github.com/handy-computer/transcribe.cpp.git")
    Run-Checked "git" @("-C", $SourceRoot, "fetch", "--depth", "1", "origin", $RuntimeRevision)
    Run-Checked "git" @("-C", $SourceRoot, "checkout", "--detach", "FETCH_HEAD")
}
$ActualRevision = & git -C $SourceRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $ActualRevision -ne $RuntimeRevision) { throw "Unexpected transcribe.cpp revision" }
$VsWhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$VsRoot = & $VsWhere -latest -products "*" -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $VsRoot) { throw "Install Visual Studio C++ build tools" }
$CmakeExe = Join-Path $VsRoot "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
$VsVersion = & $VsWhere -latest -products "*" -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationVersion
$Generator = if ($VsVersion.StartsWith("18.")) { "Visual Studio 18 2026" } else { "Visual Studio 17 2022" }
Run-Checked $CmakeExe @("-S", $SourceRoot, "-B", $BuildRoot, "-G", $Generator, "-A", "x64",
    "-DTRANSCRIBE_BUILD_SHARED=ON", "-DTRANSCRIBE_BUILD_TESTS=OFF", "-DTRANSCRIBE_BUILD_EXAMPLES=OFF",
    "-DGGML_NATIVE=OFF", "-DGGML_AVX=ON", "-DGGML_AVX2=ON", "-DGGML_FMA=ON", "-DGGML_F16C=ON",
    "-DGGML_AVX512=OFF", "-DGGML_AVX512_VBMI=OFF", "-DGGML_AVX512_VNNI=OFF", "-DGGML_AVX512_BF16=OFF", "-DGGML_AVX_VNNI=OFF",
    "-DTRANSCRIBE_USE_SYSTEM_BLAS=OFF", "-DTRANSCRIBE_USE_OPENMP=OFF", "-DTRANSCRIBE_VULKAN=OFF",
    "-DTRANSCRIBE_CUDA=OFF", "-DTRANSCRIBE_METAL=OFF", "-DTRANSCRIBE_HIP=OFF")
Run-Checked $CmakeExe @("--build", $BuildRoot, "--config", "Release", "--target", "transcribe", "--parallel", "8")
Run-Checked $PythonExe @("-m", "PyInstaller", "--noconfirm", "--clean", "--onedir", "--console", "--name", "relic-voice",
    "--distpath", (Join-Path $VoiceRoot "dist"), "--workpath", (Join-Path $VoiceRoot "build"), "--specpath", $VoiceRoot,
    "--paths", (Join-Path $SourceRoot "bindings\python\src"), "--hidden-import", "transcribe_cpp",
    "--collect-all", "onnxruntime", "--collect-all", "sentencepiece", "--collect-all", "sounddevice",
    "--add-data", "$(Join-Path $VoiceRoot 'models.json');.",
    "--add-binary", "$(Join-Path $BuildRoot 'bin\Release\*.dll');native", (Join-Path $VoiceRoot "worker.py"))
$Bundle = Join-Path $VoiceRoot "dist\relic-voice"
Copy-Item -LiteralPath (Join-Path $VoiceRoot "THIRD_PARTY.md") -Destination $Bundle -Force
Copy-Item -LiteralPath (Join-Path $VoiceRoot "licenses") -Destination $Bundle -Recurse -Force
Run-Checked $PythonExe @((Join-Path $VoiceRoot "collect_notices.py"), $Bundle)
if ($OutputDirectory) {
    $Target = Join-Path $OutputDirectory "voice"
    New-Item -ItemType Directory -Force -Path $Target | Out-Null
    Copy-Item -Path (Join-Path $Bundle "*") -Destination $Target -Recurse -Force
}
Write-Host "Voice bundle: $Bundle"
