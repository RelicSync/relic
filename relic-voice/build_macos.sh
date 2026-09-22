#!/usr/bin/env bash
# Relic Voice worker, macOS (Apple Silicon). The mac twin of build.ps1.
#
# Produces relic-voice/dist/relic-voice: a PyInstaller one-dir bundle with its
# own Python runtime, the pinned transcribe.cpp CPU library, ONNX Runtime and
# PortAudio. app/scripts/build_release_macos.sh copies it into
# Relic.app/Contents/Resources/voice and signs every binary inside it.
#
# Usage, from anywhere:
#   relic-voice/build_macos.sh                 # bundle in relic-voice/dist
#   relic-voice/build_macos.sh <output dir>    # ... and a copy at <output dir>/voice
#
# Needs: python3 (3.11 or newer), cmake, git and the Xcode command line tools.
# Models are not part of the build; the worker downloads them on first use.
set -euo pipefail

VOICE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIRECTORY="${1:-}"
RUNTIME_REVISION="ed3468f3881abb9e7b6c7d404f75049aecccb04f"
PYTHON="${RELIC_VOICE_PYTHON:-python3}"
VENV="$VOICE_ROOT/.venv"
SOURCE_ROOT="$VOICE_ROOT/_vendor/transcribe.cpp"
BUILD_ROOT="$VOICE_ROOT/.build"
NATIVE="$BUILD_ROOT/native"

[[ "$(uname -s)" == "Darwin" ]] || { echo "build_macos.sh runs on macOS only" >&2; exit 2; }
[[ "$(uname -m)" == "arm64" ]] || { echo "Only Apple Silicon is supported; Intel needs its own build and validation" >&2; exit 2; }

# --- Python venv with the pinned worker dependencies
if [[ ! -x "$VENV/bin/python" ]]; then
  "$PYTHON" -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install --quiet --upgrade pip
"$VENV/bin/python" -m pip install --quiet -r "$VOICE_ROOT/requirements.txt"

# --- transcribe.cpp at the pinned revision (same pin as build.ps1)
if [[ ! -d "$SOURCE_ROOT/.git" ]]; then
  mkdir -p "$SOURCE_ROOT"
  git init -q "$SOURCE_ROOT"
  git -C "$SOURCE_ROOT" remote add origin https://github.com/handy-computer/transcribe.cpp.git
  git -C "$SOURCE_ROOT" fetch --depth 1 origin "$RUNTIME_REVISION"
  git -C "$SOURCE_ROOT" checkout --detach FETCH_HEAD
fi
[[ "$(git -C "$SOURCE_ROOT" rev-parse HEAD)" == "$RUNTIME_REVISION" ]] || { echo "Unexpected transcribe.cpp revision" >&2; exit 1; }

# --- CPU-only shared library. Metal stays off: the worker protocol promises
#     backend "cpu", and the CPU path is the one the Windows numbers cover.
#     GGML_NATIVE off so the binary is not tuned to the build machine; NEON is
#     baseline on every Apple Silicon Mac. Deployment target 12.0 matches the
#     app.
cmake -S "$SOURCE_ROOT" -B "$BUILD_ROOT" -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DTRANSCRIBE_BUILD_SHARED=ON -DTRANSCRIBE_BUILD_TESTS=OFF \
  -DTRANSCRIBE_BUILD_EXAMPLES=OFF -DTRANSCRIBE_BUILD_TOOLS=OFF \
  -DTRANSCRIBE_METAL=OFF -DTRANSCRIBE_VULKAN=OFF -DTRANSCRIBE_CUDA=OFF -DTRANSCRIBE_HIP=OFF \
  -DTRANSCRIBE_USE_OPENMP=OFF -DTRANSCRIBE_USE_SYSTEM_BLAS=OFF \
  -DGGML_NATIVE=OFF -DGGML_METAL=OFF -DGGML_ACCELERATE=OFF -DGGML_BLAS=OFF
cmake --build "$BUILD_ROOT" --config Release --target transcribe --parallel "$(sysctl -n hw.ncpu)"

# --- one flat native/ folder: the file names the libraries ask each other
#     for (@rpath/libggml.0.dylib and friends), all resolving beside each
#     other, no build-tree rpaths left inside. The python binding loads
#     native/libtranscribe.dylib by explicit path (engine.py).
rm -rf "$NATIVE"
mkdir -p "$NATIVE"
cp "$(ls "$BUILD_ROOT"/src/libtranscribe.*.*.*.dylib | head -n1)" "$NATIVE/libtranscribe.dylib"
for lib in libggml libggml-base libggml-cpu; do
  cp "$(ls "$BUILD_ROOT"/ggml/src/$lib.*.*.*.dylib | head -n1)" "$NATIVE/$lib.0.dylib"
done
for lib in "$NATIVE"/*.dylib; do
  for rpath in $(otool -l "$lib" | awk '/LC_RPATH/{getline;getline;print $2}'); do
    install_name_tool -delete_rpath "$rpath" "$lib" 2>/dev/null || true
  done
  install_name_tool -add_rpath @loader_path "$lib"
done
install_name_tool -id @rpath/libtranscribe.dylib "$NATIVE/libtranscribe.dylib"
# install_name_tool invalidates the ad-hoc signature; re-seal so the libraries
# load during the unsigned dev checks. The release build re-signs everything.
for lib in "$NATIVE"/*.dylib; do codesign --force --sign - "$lib" 2>/dev/null; done

# --- freeze
rm -rf "$VOICE_ROOT/dist/relic-voice"
"$VENV/bin/python" -m PyInstaller --noconfirm --clean --onedir --console --name relic-voice \
  --distpath "$VOICE_ROOT/dist" --workpath "$VOICE_ROOT/build" --specpath "$VOICE_ROOT" \
  --paths "$SOURCE_ROOT/bindings/python/src" --hidden-import transcribe_cpp \
  --collect-all onnxruntime --collect-all sentencepiece --collect-all sounddevice \
  --add-data "$VOICE_ROOT/models.json:." \
  --add-binary "$NATIVE/*.dylib:native" \
  "$VOICE_ROOT/worker.py"
BUNDLE="$VOICE_ROOT/dist/relic-voice"
# Wheels ship helper scripts with the execute bit set (onnxruntime/tools,
# numpy's f2py …). Nothing in the bundle is ever run as a script (the
# interpreter imports these modules), and codesign has no business reading
# them as code, so drop the bit from everything that is not a Mach-O binary.
# Only the worker itself stays executable.
find "$BUNDLE" -type f -perm -u+x ! -path "$BUNDLE/relic-voice" -print0 \
  | while IFS= read -r -d '' f; do
      file "$f" | grep -q "Mach-O" || chmod a-x "$f"
    done
# A shebang line is enough for codesign to call a file a script, even with
# no execute bit. Nothing in the bundle is ever run as a script (the
# interpreter imports these modules), so the line goes.
grep -rlI --exclude="*.so" --exclude="*.dylib" '^#!' "$BUNDLE/_internal" 2>/dev/null \
  | while IFS= read -r f; do sed -i '' '1{/^#!/d;}' "$f"; done
cp "$VOICE_ROOT/THIRD_PARTY.md" "$BUNDLE/"
cp -R "$VOICE_ROOT/licenses" "$BUNDLE/"
"$VENV/bin/python" "$VOICE_ROOT/collect_notices.py" "$BUNDLE"

# --- the frozen worker must announce itself before it is worth shipping
HELLO="$(printf '{"op":"shutdown"}\n' | "$BUNDLE/relic-voice" --models "$(mktemp -d)" 2>/dev/null | head -n1 || true)"
[[ "$HELLO" == *'"event": "hello"'* ]] || { echo "frozen worker did not say hello: $HELLO" >&2; exit 1; }

if [[ -n "$OUTPUT_DIRECTORY" ]]; then
  mkdir -p "$OUTPUT_DIRECTORY/voice"
  cp -R "$BUNDLE/." "$OUTPUT_DIRECTORY/voice/"
fi
echo "Voice bundle: $BUNDLE"
