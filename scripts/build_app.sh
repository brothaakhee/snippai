#!/usr/bin/env bash
# Assemble SnippAI.app from the SwiftPM build product and ad-hoc codesign it.
# Ad-hoc signing is sufficient for local TCC (Screen Recording / Automation),
# and a stable bundle identity lets macOS remember granted permissions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="${ROOT}/build/SnippAI.app"

echo "==> Building SnippAI (${CONFIG})..."
swift build -c "${CONFIG}" --product SnippAI

BIN_DIR="$(swift build -c "${CONFIG}" --product SnippAI --show-bin-path 2>/dev/null | tail -n 1)"
BIN_PATH="${BIN_DIR}/SnippAI"
if [[ ! -f "${BIN_PATH}" ]]; then
    echo "error: built binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> Assembling app bundle at ${APP} ..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_PATH}" "${APP}/Contents/MacOS/SnippAI"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

echo "==> Codesigning..."
# Prefer a STABLE self-signed identity ("SnippAI Dev") so TCC grants (Screen
# Recording / Automation) survive rebuilds — ad-hoc changes the code hash every
# build and silently invalidates them. Falls back to ad-hoc if the cert is absent.
# Create the cert once with: scripts/make_signing_cert.sh
if codesign --force --deep --sign "SnippAI Dev" "${APP}" 2>/dev/null; then
    echo "    signed with stable identity 'SnippAI Dev' (grants persist across rebuilds)"
else
    echo "    'SnippAI Dev' identity not found — ad-hoc signing (grants reset each rebuild)"
    codesign --force --deep --sign - "${APP}"
fi

echo "==> Done: ${APP}"
echo "    Launch with:  open \"${APP}\""
