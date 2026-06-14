#!/usr/bin/env bash
# Create a stable, self-signed code-signing certificate ("SnippAI Dev") in the
# login keychain. Signing the app with a stable identity (instead of ad-hoc) means
# macOS TCC grants — Screen Recording, Automation — SURVIVE rebuilds, because the
# code's designated requirement stays constant. Run once.
set -euo pipefail

NAME="SnippAI Dev"
if codesign --sign "${NAME}" --dryrun /usr/bin/true 2>/dev/null || \
   security find-identity -v 2>/dev/null | grep -q "${NAME}"; then
    echo "Identity '${NAME}' already present."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "${TMP}/k.key" -out "${TMP}/k.crt" -days 3650 -nodes \
    -subj "/CN=${NAME}" \
    -addext "extendedKeyUsage=codeSigning" -addext "keyUsage=critical,digitalSignature" >/dev/null 2>&1

# -legacy: emit a PKCS12 the macOS `security` tool can verify (OpenSSL 3 default isn't).
openssl pkcs12 -export -legacy -inkey "${TMP}/k.key" -in "${TMP}/k.crt" \
    -out "${TMP}/k.p12" -passout pass:snippai -name "${NAME}" >/dev/null 2>&1

# -T /usr/bin/codesign authorizes codesign to use the key without a prompt.
security import "${TMP}/k.p12" -k "${HOME}/Library/Keychains/login.keychain-db" -P snippai -T /usr/bin/codesign

echo "Created code-signing identity '${NAME}'. Rebuild with scripts/build_app.sh."
