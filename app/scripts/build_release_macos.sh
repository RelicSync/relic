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
#     App entitlements, real-identity path only. Runner/Release.entitlements is
#     an Xcode *template*: it carries $(AppIdentifierPrefix), which only the
#     build expands, and the build also adds application-identifier +
#     team-identifier — without which a keychain-access-group means nothing. So
#     re-sign from the expanded copy Xcode emitted (.xcent), minus
#     get-task-allow: a debuggable binary is an automatic notarization
#     rejection.
#     Ad-hoc gets NO entitlements: those keys are *restricted*, and AMFI
#     SIGKILLs a process that claims them under a signature it cannot validate
#     ("Code has restricted entitlements, but the validation of its code
#     signature failed"). Carrying them would cost nothing less than the app's
#     ability to launch, and buy nothing — the data-protection keychain already
#     fails -34018 without a real certificate.
APP_SIGN_ARGS=("${SIGN_ARGS[@]}")
if [[ -n "$IDENTITY" ]]; then
  XCENT="$(find "$APP_DIR/build/macos/Build/Intermediates.noindex" \
    -path "*/Release/*" -name "*.app.xcent" -print -quit 2>/dev/null || true)"
  if [[ -n "$XCENT" ]]; then
    SIGN_ENTITLEMENTS="$(mktemp -t relic-entitlements)"
    cp "$XCENT" "$SIGN_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" \
      "$SIGN_ENTITLEMENTS" >/dev/null 2>&1 || true
  else
    echo "warning: no expanded .xcent found; signing with the raw template" >&2
    SIGN_ENTITLEMENTS="$APP_DIR/macos/Runner/Release.entitlements"
  fi
  APP_SIGN_ARGS+=(--entitlements "$SIGN_ENTITLEMENTS")
fi
# The Xcode build embeds a *development* profile (registered Macs only — the
# restricted keychain entitlement gets the app SIGKILLed everywhere else), so
# the signed path swaps in the Developer ID profile (ProvisionsAllDevices).
# The profile was minted once via archive/export with automatic signing and
# checked in; it contains no secrets (every shipped app carries it).
DEVID_PROFILE="$APP_DIR/macos/Runner/DeveloperID.provisionprofile"
if [[ -n "$IDENTITY" ]]; then
  [[ -f "$DEVID_PROFILE" ]] || { echo "missing $DEVID_PROFILE (see docs/macos-port.md Phase 6)" >&2; exit 1; }
  cp "$DEVID_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
fi
# sift dlopens libonnxruntime — the bundled copy (ours, same signature) or, in
# preference, the one `sift models download` caches, which is Microsoft's
# ad-hoc-signed build. Under the hardened runtime, library validation would
# refuse that one, so the sidecar opts out. Nothing else here loads foreign code.
SIFT_ENTITLEMENTS="$APP_DIR/macos/Runner/Sift.entitlements"
echo "==> codesign (${IDENTITY:-ad-hoc})"
for fw in "$APP_BUNDLE/Contents/Frameworks"/*.framework; do
  [[ -d "$fw" ]] || continue
  target="$fw"
  [[ -d "$fw/Versions/A" ]] && target="$fw/Versions/A"
  codesign "${SIGN_ARGS[@]}" "$target"
done
codesign "${SIGN_ARGS[@]}" "$MACOS_DIR/libonnxruntime.dylib"
codesign "${SIGN_ARGS[@]}" --entitlements "$SIFT_ENTITLEMENTS" "$MACOS_DIR/sift"
codesign "${SIGN_ARGS[@]}" "$HELPERS_DIR/relic"
codesign "${APP_SIGN_ARGS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

# Belt-and-braces: the swap above must have left a ProvisionsAllDevices
# profile sealed into the bundle, or the app dies on every non-registered Mac.
if [[ -n "$IDENTITY" ]]; then
  security cms -D -i "$APP_BUNDLE/Contents/embedded.provisionprofile" 2>/dev/null \
    | grep -q "ProvisionsAllDevices" \
    || { echo "embedded.provisionprofile is not a Developer ID profile" >&2; exit 1; }
fi

[[ "$SKIP_DMG" == 1 ]] && { echo "==> done (skipped DMG): $APP_BUNDLE"; exit 0; }

# --- DMG
mkdir -p "$DIST"
DMG="$DIST/relic-$VER.dmg"
rm -f "$DMG"
echo "==> packaging $DMG"
# Stage first either way: create-dmg copies the *contents* of its source
# argument, so handing it the .app would scatter Contents/ over the volume
# root. The bundle is also renamed here — the target is relic_app.app, users
# get Relic.app.
STAGE="$(mktemp -d)"
chmod 755 "$STAGE"   # mktemp -d is 0700, and that mode becomes the volume root's
ditto "$APP_BUNDLE" "$STAGE/Relic.app"
PACKAGED=0
# The window background: two numbered steps, because step 2 (open it from
# Applications, not from this window) is the one people skip — and the ones who
# skip it end up running Relic off a volume that disappears. Checked in rather
# than drawn here: a build script cannot count on Python/PIL, and sips will not
# draw text. 1200x800 at 144dpi, so Finder lays it out at 600x400 points and it
# stays sharp on a retina display; keep those numbers in step with --window-size
# and the icon positions below if you ever redraw it.
DMG_BACKGROUND="$APP_DIR/macos/dmg-background.png"
BG_ARGS=()
[[ -f "$DMG_BACKGROUND" ]] && BG_ARGS=(--background "$DMG_BACKGROUND")
if command -v create-dmg >/dev/null 2>&1; then
  # create-dmg makes its own /Applications link, so the stage holds only the
  # app. It lays the window out by driving Finder, which needs an interactive
  # session that has granted automation rights — over ssh or from a build
  # agent that times out (-1712). Cosmetic, so failing over is fine.
  #
  # Icons at y=190 in a 600x400 window: Relic on the left, the Applications
  # drop link on the right, the background's arrow pointing from one to the
  # other. (The ${a[@]+…} guard is for bash 3.2, which is what /bin/bash still
  # is on macOS: an empty array under `set -u` is an unbound variable there.)
  # Up to three attempts: create-dmg's unmount step fails with "Resource busy"
  # for transient reasons (Spotlight indexing the fresh volume — or a Relic
  # someone launched off the staging volume while it was up; the guard in
  # AppDelegate.swift now exits such a copy, but the app it defers to can pin
  # the mount for a beat). The failure that matters is only cosmetic, but the
  # 1.0.36 build silently shipped the artless fallback, so: retry, and shout.
  for attempt in 1 2 3; do
    if create-dmg --volname "Relic $VER" \
        --window-pos 200 120 --window-size 600 400 \
        --icon-size 100 --text-size 13 \
        ${BG_ARGS[@]+"${BG_ARGS[@]}"} \
        --icon "Relic.app" 150 190 --app-drop-link 450 190 \
        --hide-extension "Relic.app" \
        "$DMG" "$STAGE"; then
      PACKAGED=1
      break
    fi
    echo "==> create-dmg attempt $attempt failed"
    rm -f "$DIST"/rw.*.dmg
    sleep 5
  done
  if [[ "$PACKAGED" == 0 ]]; then
    echo "==> WARNING: create-dmg failed 3 times; falling back to a PLAIN image"
    echo "==>          (no background artwork, no window layout)"
  fi
fi
if [[ "$PACKAGED" == 0 ]]; then
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Relic $VER" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi
rm -rf "$STAGE"

# --- notarize + staple (keychain profile locally, API key in CI; only
#     meaningful for a real-identity signature — Apple rejects ad-hoc)
if [[ -n "$IDENTITY" ]]; then
  # A signed DMG passes Gatekeeper on its own; the staple below then covers it
  # offline too.
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
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

# --- final layout check: mount what will actually ship and look inside. The
#     app and Applications link are hard requirements; the artwork is the
#     cosmetic one that quietly went missing once, so its state is printed
#     either way.
CHECK_MNT="$(mktemp -d)"
hdiutil attach -readonly -nobrowse "$DMG" -mountpoint "$CHECK_MNT" >/dev/null
[[ -d "$CHECK_MNT/Relic.app" ]] || { echo "==> FATAL: shipped DMG has no Relic.app"; exit 1; }
[[ -e "$CHECK_MNT/Applications" ]] || { echo "==> FATAL: shipped DMG has no Applications link"; exit 1; }
if [[ -f "$CHECK_MNT/.background/dmg-background.png" ]]; then
  echo "==> layout check: app + Applications + background artwork present"
else
  echo "==> layout check: WARNING — no background artwork in the shipped DMG"
fi
hdiutil detach "$CHECK_MNT" >/dev/null || hdiutil detach "$CHECK_MNT" -force >/dev/null
rmdir "$CHECK_MNT" 2>/dev/null || true

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
