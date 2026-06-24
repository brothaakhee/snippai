#!/usr/bin/env bash
# Build a DISTRIBUTABLE SnippAI: release binary → app bundle → Developer ID signing
# with the hardened runtime → DMG → notarization + stapling. The output DMG is
# Gatekeeper-clean and ready to attach to a GitHub Release.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in your keychain (you have one:
#      WP368XBRDU). Override auto-detection with SIGN_ID="Developer ID Application: ...".
#   2. A stored notarytool credential profile:
#        xcrun notarytool store-credentials snippai-notary \
#          --apple-id <you@apple-id> --team-id WP368XBRDU --password <app-specific-pw>
#      Override the profile name with NOTARY_PROFILE=...
#
# Usage:
#   scripts/release.sh                # full: sign + DMG + notarize + staple
#   scripts/release.sh --no-notarize  # sign + DMG only (local verification)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

NOTARY_PROFILE="${NOTARY_PROFILE:-snippai-notary}"
APP="${ROOT}/build/SnippAI.app"
ENTITLEMENTS="${ROOT}/Resources/SnippAI.entitlements"
DIST="${ROOT}/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${ROOT}/Resources/Info.plist")"
# Stable (unversioned) name so https://github.com/<repo>/releases/latest/download/SnippAI.dmg
# always resolves to the newest build — the site link and in-app feed both rely on this.
DMG="${DIST}/SnippAI.dmg"

# Resolve the Developer ID Application identity (override via SIGN_ID).
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [[ -z "${SIGN_ID}" ]]; then
    echo "error: no 'Developer ID Application' identity found. Set SIGN_ID=..." >&2
    exit 1
fi
echo "==> Release v${VERSION}  ·  signing as: ${SIGN_ID}"

# --- Build + assemble -------------------------------------------------------
echo "==> Building release binary..."
swift build -c release --product SnippAI
BIN_DIR="$(swift build -c release --product SnippAI --show-bin-path 2>/dev/null | tail -n 1)"
BIN_PATH="${BIN_DIR}/SnippAI"
[[ -f "${BIN_PATH}" ]] || { echo "error: binary not found at ${BIN_PATH}" >&2; exit 1; }

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_PATH}" "${APP}/Contents/MacOS/SnippAI"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"
if [[ -f "${ROOT}/Resources/SnippAI.icns" ]]; then
    cp "${ROOT}/Resources/SnippAI.icns" "${APP}/Contents/Resources/SnippAI.icns"
fi

# --- Sign (hardened runtime + secure timestamp) -----------------------------
echo "==> Codesigning (hardened runtime)..."
codesign --force --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${SIGN_ID}" "${APP}"
codesign --verify --strict --verbose=2 "${APP}"

# --- Build the DMG ----------------------------------------------------------
echo "==> Building DMG..."
mkdir -p "${DIST}"
rm -f "${DMG}"
STAGE="$(mktemp -d)"
cp -R "${APP}" "${STAGE}/SnippAI.app"
ln -s /Applications "${STAGE}/Applications"
hdiutil create -volname "SnippAI" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}" >/dev/null
rm -rf "${STAGE}"
codesign --force --timestamp --sign "${SIGN_ID}" "${DMG}"

# --- Notarize + staple ------------------------------------------------------
if [[ "${NOTARIZE}" == "1" ]]; then
    echo "==> Notarizing (this can take a few minutes)..."
    xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait
    echo "==> Stapling ticket..."
    xcrun stapler staple "${DMG}"
    xcrun stapler validate "${DMG}"
    spctl --assess --type open --context context:primary-signature -v "${DMG}" || true
else
    echo "==> Skipping notarization (--no-notarize). DMG is signed but NOT Gatekeeper-clean."
fi

# --- Update feed (for the in-app version check) -----------------------------
cat > "${DIST}/appcast.json" <<EOF
{
  "version": "${VERSION}",
  "url": "https://github.com/brothaakhee/snippai-releases/releases/latest/download/SnippAI.dmg",
  "notes": "See the release notes on GitHub."
}
EOF

echo ""
echo "==> Done."
echo "    DMG:     ${DMG}"
echo "    Feed:    ${DIST}/appcast.json"
echo "    Upload BOTH as assets on the GitHub Release tagged v${VERSION}, e.g.:"
echo "      gh release create v${VERSION} --repo brothaakhee/snippai-releases \"${DMG}\" \"${DIST}/appcast.json\" --title \"SnippAI v${VERSION}\" --generate-notes"
