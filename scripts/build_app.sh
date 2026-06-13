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

echo "==> Codesigning (ad-hoc)..."
# Plain ad-hoc signature (no hardened runtime) is the most reliable for local
# TCC: it gives the bundle a stable identity so macOS remembers the Screen
# Recording / Automation grants, without notarization friction.
codesign --force --deep --sign - "${APP}"

echo "==> Done: ${APP}"
echo "    Launch with:  open \"${APP}\""
