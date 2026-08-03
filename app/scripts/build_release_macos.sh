#!/usr/bin/env bash
# Relic — macOS release build (docs/macos-port.md Phase 6).
# The mac twin of build_release.ps1: version from pubspec → flutter build →
# cargo sift/cli → bundle → codesign → notarize → DMG in dist/.
#
# Usage (run on a Mac, from anywhere):
#   app/scripts/build_release_macos.sh                       # unsigned dev DMG
#   app/scripts/build_release_macos.sh \
#     --identity "Developer ID Application: Jordan … (TEAMID)" \
#     --notary-profile relic-notary                           # signed + notarized
#
# Options:
#   --identity <name>        codesign identity (skip → ad-hoc signed, no notarize)
#   --notary-profile <name>  notarytool keychain profile (xcrun notarytool store-credentials)
#   --notary-key <p8> --notary-key-id <id> --notary-issuer <uuid>
#                            notarize with an App Store Connect API key instead
#                            of a keychain profile (what CI has — codemagic.yaml)
#   --ort <path>             libonnxruntime .dylib to bundle beside sift
#                            (default: fetched from the official onnxruntime release)
#   --skip-dmg               stop after the signed .app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
ROOT="$(dirname "$APP_DIR")"
DIST="$ROOT/dist"

IDENTITY=""
NOTARY_PROFILE=""
NOTARY_KEY=""
NOTARY_KEY_ID=""
NOTARY_ISSUER=""
ORT_DYLIB=""
SKIP_DMG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
    --notary-key) NOTARY_KEY="$2"; shift 2 ;;
    --notary-key-id) NOTARY_KEY_ID="$2"; shift 2 ;;
    --notary-issuer) NOTARY_ISSUER="$2"; shift 2 ;;
    --ort) ORT_DYLIB="$2"; shift 2 ;;
    --skip-dmg) SKIP_DMG=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# --- version: single-sourced from pubspec.yaml (same regex as build_release.ps1)
VER="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$APP_DIR/pubspec.yaml" | head -n1)"
[[ -n "$VER" ]] || { echo "could not read version from pubspec.yaml" >&2; exit 1; }
echo "==> Relic $VER (macOS $(uname -m))"

# --- ONNX Runtime dylib for the sift sidecar (ort api-24 ⇒ 1.24.x)
ORT_VERSION="1.24.2"
if [[ -z "$ORT_DYLIB" ]]; then
  ORT_CACHE="$ROOT/target/ort-osx-arm64-$ORT_VERSION"
  ORT_DYLIB="$ORT_CACHE/onnxruntime-osx-arm64-$ORT_VERSION/lib/libonnxruntime.$ORT_VERSION.dylib"
  if [[ ! -f "$ORT_DYLIB" ]]; then
    echo "==> fetching onnxruntime $ORT_VERSION (osx-arm64)"
    mkdir -p "$ORT_CACHE"
    curl -fsSL -o "$ORT_CACHE/ort.tgz" \
      "https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VERSION/onnxruntime-osx-arm64-$ORT_VERSION.tgz"
    tar -xzf "$ORT_CACHE/ort.tgz" -C "$ORT_CACHE"
  fi
fi
[[ -f "$ORT_DYLIB" ]] || { echo "onnxruntime dylib not found: $ORT_DYLIB" >&2; exit 1; }

# --- builds
echo "==> flutter build macos --release"
(cd "$APP_DIR" && flutter build macos --release)
APP_BUNDLE="$APP_DIR/build/macos/Build/Products/Release/relic_app.app"
[[ -d "$APP_BUNDLE" ]] || { echo "flutter build did not produce $APP_BUNDLE" >&2; exit 1; }

echo "==> cargo build sift + relic-cli (release)"
(cd "$ROOT" && cargo build --release -p relic-sift --bin sift)
(cd "$ROOT" && cargo build --release -p relic-cli --bin relic)

# --- bundle the sidecar + CLI + runtime inside the .app
#   sift sits beside the runner executable (SiftSidecar.locate checks
#   Platform.resolvedExecutable's dir first); the ort dylib beside sift is the
#   packaged fallback pipeline::init_ort probes before the model cache.
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
HELPERS_DIR="$APP_BUNDLE/Contents/Helpers"
mkdir -p "$HELPERS_DIR"
cp "$ROOT/target/release/sift" "$MACOS_DIR/sift"
cp "$ORT_DYLIB" "$MACOS_DIR/libonnxruntime.dylib"
cp "$ROOT/target/release/relic" "$HELPERS_DIR/relic"

# --- codesign, inside-out (Developer ID + hardened runtime; ad-hoc for dev —
#     no timestamp/hardening there, both need a real certificate)
if [[ -n "$IDENTITY" ]]; then
  SIGN_ARGS=(--force --timestamp --options runtime --sign "$IDENTITY")
else
  SIGN_ARGS=(--force --sign -)
fi
ENTITLEMENTS="$APP_DIR/macos/Runner/Release.entitlements"
echo "==> codesign (${IDENTITY:-ad-hoc})"
codesign "${SIGN_ARGS[@]}" "$MACOS_DIR/libonnxruntime.dylib"
codesign "${SIGN_ARGS[@]}" "$MACOS_DIR/sift"
codesign "${SIGN_ARGS[@]}" "$HELPERS_DIR/relic"
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

[[ "$SKIP_DMG" == 1 ]] && { echo "==> done (skipped DMG): $APP_BUNDLE"; exit 0; }

# --- DMG
mkdir -p "$DIST"
DMG="$DIST/relic-$VER.dmg"
rm -f "$DMG"
echo "==> packaging $DMG"
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg --volname "Relic $VER" --app-drop-link 450 150 "$DMG" "$APP_BUNDLE"
else
  STAGE="$(mktemp -d)"
  cp -R "$APP_BUNDLE" "$STAGE/Relic.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Relic $VER" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
fi

# --- notarize + staple (keychain profile locally, API key in CI; only
#     meaningful for a real-identity signature — Apple rejects ad-hoc)
if [[ -n "$IDENTITY" ]]; then
  if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "==> notarizing (keychain profile)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  elif [[ -n "$NOTARY_KEY" && -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER" ]]; then
    echo "==> notarizing (App Store Connect API key)"
    xcrun notarytool submit "$DMG" \
      --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
    xcrun stapler staple "$DMG"
  fi
fi

cat <<EOF

==> built: $DMG

Publish steps (mirrors build_release.ps1):
  1. wrangler r2 object put "relic-downloads/macos/relic-$VER.dmg" --file "$DMG"
  2. website/public/latest.json — bump "version" to $VER and make sure the
     platforms block includes:
       "macos": { "url": "https://relic.space/download/macos" }
  3. deploy the website (push to main; .github/workflows/deploy-website.yml)

One-time (first mac release only) — stage the sift runtime on the model mirror
so 'sift models download' works for mac users:
  wrangler r2 object put "<model-mirror-bucket>/relic-sift/v1/macos-arm64/libonnxruntime.dylib" \\
    --file "$ORT_DYLIB"
EOF
