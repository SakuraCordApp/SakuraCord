#!/usr/bin/env bash
set -euo pipefail

IDENTITY_NAME="SakuraCord Local Development"
LOGIN_KEYCHAIN="$(security default-keychain -d user | tr -d '[:space:]\"')"
if [[ -z "$LOGIN_KEYCHAIN" || ! -f "$LOGIN_KEYCHAIN" ]]; then
  echo "Could not locate the login keychain." >&2
  exit 1
fi

existing_identity="$(
  security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null \
    | awk -v name="\"$IDENTITY_NAME\"" 'index($0, name) { print $2; exit }'
)"

if [[ -n "$existing_identity" ]]; then
  echo "SakuraCord local signing identity is already installed: $existing_identity"
  exit 0
fi

if security find-certificate -c "$IDENTITY_NAME" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
  echo "A certificate named '$IDENTITY_NAME' exists without a usable private key." >&2
  echo "Remove or repair it in Keychain Access before trying again." >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-signing.XXXXXX")"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

PRIVATE_KEY="$STAGING_DIR/private-key.pem"
CERTIFICATE="$STAGING_DIR/certificate.pem"
IDENTITY_ARCHIVE="$STAGING_DIR/identity.p12"
ARCHIVE_PASSWORD="$(openssl rand -hex 24)"

openssl req \
  -x509 \
  -newkey rsa:3072 \
  -sha256 \
  -days 3650 \
  -nodes \
  -keyout "$PRIVATE_KEY" \
  -out "$CERTIFICATE" \
  -subj "/CN=$IDENTITY_NAME/O=SakuraCord Development" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  >/dev/null 2>&1

openssl pkcs12 \
  -export \
  -inkey "$PRIVATE_KEY" \
  -in "$CERTIFICATE" \
  -name "$IDENTITY_NAME" \
  -out "$IDENTITY_ARCHIVE" \
  -passout "pass:$ARCHIVE_PASSWORD"

security import "$IDENTITY_ARCHIVE" \
  -k "$LOGIN_KEYCHAIN" \
  -f pkcs12 \
  -P "$ARCHIVE_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  >/dev/null
security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$LOGIN_KEYCHAIN" \
  "$CERTIFICATE"

identity_hash="$(
  security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null \
    | awk -v name="\"$IDENTITY_NAME\"" 'index($0, name) { print $2; exit }'
)"
if [[ -z "$identity_hash" ]]; then
  echo "The certificate was imported but is not a valid code-signing identity." >&2
  exit 1
fi

echo "Installed SakuraCord local signing identity: $identity_hash"
