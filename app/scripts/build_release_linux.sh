#!/usr/bin/env bash
# Relic — Linux release build (docs/linux-port.md Phase 6).
# The Linux twin of build_release.ps1 / build_release_macos.sh: version from
# pubspec → flutter build → cargo sift/cli → bundle → tarball (+ AppImage) in
# dist/.
#
# There is no signing wall here, which is the point: unlike Windows and macOS,
# anyone — including CI — can build the artifact we ship.
#
# Usage (run on x86_64 Linux, from anywhere):
#   app/scripts/build_release_linux.sh                  # tarball only
#   app/scripts/build_release_linux.sh --appimage       # tarball + AppImage
#
# Options:
#   --appimage        also build relic-<ver>-x86_64.AppImage (self-update needs
#                     it; appimagetool is fetched on demand)
#   --ort <path>      libonnxruntime .so to ship beside sift
#                     (default: fetched from the official onnxruntime release)
#   --skip-sift       ship without the ML sidecar (a much smaller tarball; the
#                     app degrades to the deterministic pipeline)
#   --stage-ort       print the one-time model-mirror upload command and exit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
ROOT="$(dirname "$APP_DIR")"
DIST="$ROOT/dist"

WANT_APPIMAGE=0
ORT_SO=""
SKIP_SIFT=0
STAGE_ORT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --appimage) WANT_APPIMAGE=1; shift ;;
    --ort) ORT_SO="$2"; shift 2 ;;
    --skip-sift) SKIP_SIFT=1; shift ;;
    --stage-ort) STAGE_ORT=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ "$(uname -m)" == "x86_64" ]] || {
  echo "Relic ships x86_64 Linux only; this is $(uname -m)" >&2; exit 1; }

# --- version: single-sourced from pubspec.yaml (same regex as the other two)
VER="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$APP_DIR/pubspec.yaml" | head -n1)"
[[ -n "$VER" ]] || { echo "could not read version from pubspec.yaml" >&2; exit 1; }
echo "==> Relic $VER (linux-x64)"

# --- ONNX Runtime for the sift sidecar (ort api-24 ⇒ 1.24.x). The release
#     tarball carries it beside sift, so a packaged install never downloads a
#     runtime; pipeline::init_ort probes beside the executable first.
ORT_VERSION="1.24.2"
if [[ -z "$ORT_SO" && "$SKIP_SIFT" == "0" ]]; then
  ORT_CACHE="$ROOT/target/ort-linux-x64-$ORT_VERSION"
  ORT_SO="$ORT_CACHE/onnxruntime-linux-x64-$ORT_VERSION/lib/libonnxruntime.so.$ORT_VERSION"
  if [[ ! -f "$ORT_SO" ]]; then
    echo "==> fetching onnxruntime $ORT_VERSION (linux-x64)"
    mkdir -p "$ORT_CACHE"
    curl -fsSL -o "$ORT_CACHE/ort.tgz" \
      "https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VERSION/onnxruntime-linux-x64-$ORT_VERSION.tgz"
    tar -xzf "$ORT_CACHE/ort.tgz" -C "$ORT_CACHE"
  fi
fi

if [[ "$STAGE_ORT" == "1" ]]; then
  cat <<EOF
One-time, so 'sift models download' works for Linux users who build from
source (a packaged install already carries the library):

  wrangler r2 object put "<model-mirror-bucket>/relic-sift/v1/linux-x64/libonnxruntime.so" \\
    --file "$ORT_SO"

The key must match relic-sift/src/models.rs (MIRROR_BASE + linux-x64/).
EOF
  exit 0
fi

# --- builds
echo "==> flutter build linux --release"
(cd "$APP_DIR" && flutter config --enable-linux-desktop >/dev/null && flutter build linux --release)
BUNDLE="$APP_DIR/build/linux/x64/release/bundle"
[[ -x "$BUNDLE/relic_app" ]] || { echo "flutter build did not produce $BUNDLE/relic_app" >&2; exit 1; }

STAGE="$ROOT/target/linux-pkg/relic-$VER-linux-x64"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$BUNDLE/." "$STAGE/"

if [[ "$SKIP_SIFT" == "0" ]]; then
  echo "==> cargo build sift + relic-cli (release)"
  (cd "$ROOT" && cargo build --release -p relic-sift --bin sift)
  (cd "$ROOT" && cargo build --release -p relic-cli --bin relic)
  # sift sits beside relic_app (SiftSidecar.locate checks
  # Platform.resolvedExecutable's dir first) and the runtime beside sift.
  cp "$ROOT/target/release/sift" "$STAGE/sift"
  cp "$ROOT/target/release/relic" "$STAGE/relic"
  [[ -f "$ORT_SO" ]] || { echo "onnxruntime not found: $ORT_SO" >&2; exit 1; }
  cp "$ORT_SO" "$STAGE/libonnxruntime.so"
  chmod +x "$STAGE/sift" "$STAGE/relic"
fi

# Relic writes its own launcher entry, icon and relic:// handler on first run
# (platform/src/linux/desktop_entry_linux.dart), so the tarball needs no install
# step — but ship the desktop file anyway for anyone doing a system-wide
# install by hand, and for appimagetool, which requires one in the AppDir.
cat > "$STAGE/space.relic.app.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=Relic
GenericName=Clipboard Vault
Comment=Everything you copy, kept and searchable
Exec=relic_app %u
Icon=space.relic.app
Terminal=false
Categories=Utility;
Keywords=clipboard;history;paste;vault;snippets;
MimeType=x-scheme-handler/relic;
StartupWMClass=space.relic.app
StartupNotify=false
EOF
cp "$APP_DIR/assets/app_icon.png" "$STAGE/space.relic.app.png"

cat > "$STAGE/README.txt" <<EOF
Relic $VER — Linux x86_64

Run ./relic_app. On first launch Relic registers itself with the desktop
(launcher entry, icon, and the relic:// link handler) under ~/.local/share;
nothing is installed system-wide and nothing needs root.

Relic targets X11. Under Wayland the window, capture and sync all work, but
global hotkeys, paste injection and knowing which app you copied from do not —
Wayland forbids them. Log in with "Ubuntu on Xorg" (or your desktop's X11
session) for the full experience.

Uninstall: delete this folder, then
  rm -f ~/.local/share/applications/space.relic.app.desktop \\
        ~/.config/autostart/space.relic.app.desktop \\
        ~/.local/share/icons/hicolor/256x256/apps/space.relic.app.png
Your vault lives in ~/.local/share/relic — delete that too if you mean it.
EOF

mkdir -p "$DIST"
TARBALL="$DIST/relic-$VER-linux-x64.tar.gz"
rm -f "$TARBALL"
echo "==> packing $(basename "$TARBALL")"
tar czf "$TARBALL" -C "$(dirname "$STAGE")" "$(basename "$STAGE")"

# --- AppImage: the Linux self-update story (one file to replace, then
#     relaunch — the sibling of the macOS ditto-swap). The runtime sets
#     $APPIMAGE to this file's real path, which is what the desktop entries
#     Relic writes must point at (see self_exec_linux.dart).
if [[ "$WANT_APPIMAGE" == "1" ]]; then
  APPDIR="$ROOT/target/linux-pkg/Relic.AppDir"
  rm -rf "$APPDIR"
  mkdir -p "$APPDIR/usr/bin"
  cp -a "$STAGE/." "$APPDIR/usr/bin/"
  cp "$STAGE/space.relic.app.desktop" "$APPDIR/space.relic.app.desktop"
  cp "$STAGE/space.relic.app.png" "$APPDIR/space.relic.app.png"
  cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
# The bundle's own libraries come first: relic_app is linked with an $ORIGIN
# rpath, but the plugins it dlopens are not, and a host library of the same
# name would win otherwise.
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/bin/lib:${LD_LIBRARY_PATH:-}"
exec "$HERE/usr/bin/relic_app" "$@"
EOF
  chmod +x "$APPDIR/AppRun"

  TOOL="$ROOT/target/appimagetool-x86_64.AppImage"
  if [[ ! -x "$TOOL" ]]; then
    echo "==> fetching appimagetool"
    curl -fsSL -o "$TOOL" \
      "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$TOOL"
  fi
  APPIMAGE="$DIST/relic-$VER-x86_64.AppImage"
  rm -f "$APPIMAGE"
  echo "==> packing $(basename "$APPIMAGE")"
  # --appimage-extract-and-run: appimagetool is itself an AppImage, and CI
  # runners have no FUSE.
  ARCH=x86_64 "$TOOL" --appimage-extract-and-run "$APPDIR" "$APPIMAGE"
fi

cat <<EOF

==> built: $TARBALL$([[ "$WANT_APPIMAGE" == "1" ]] && echo "
==> built: $DIST/relic-$VER-x86_64.AppImage")

Publish steps (mirrors build_release.ps1):
  1. wrangler r2 object put "relic-downloads/linux/relic-$VER-linux-x64.tar.gz" \\
       --file "$TARBALL"
     (and the .AppImage under relic-downloads/linux/ alongside it)
     NEVER overwrite a published versioned key — probe it first.
  2. website/public/latest.json — bump "version" to $VER and make sure the
     platforms block includes:
       "linux": { "url": "https://relic.space/download/linux" }
  3. deploy the website (push to main; .github/workflows/deploy-website.yml)

Run with --stage-ort for the one-time model-mirror upload.
EOF
