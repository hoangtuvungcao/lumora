#!/usr/bin/env bash
# CI helper: import a base64-encoded .p12 signing identity into a temporary keychain
# and print the identity name matching $2 (e.g. "Developer ID Application").
#
#   app/tool/apple/import_cert.sh <p12-base64-env-var-name> <identity-prefix>
#
# The certificate password comes from $CERT_PASSWORD. The keychain lives in
# $RUNNER_TEMP and disappears with the runner. Nothing secret is echoed.
set -euo pipefail

VAR="$1"
PREFIX="$2"
P12_B64="${!VAR:-}"
[ -n "$P12_B64" ] || { echo "error: \$$VAR is empty" >&2; exit 1; }

TMP="${RUNNER_TEMP:-$(mktemp -d)}"
KEYCHAIN="$TMP/lumora-signing.keychain-db"
KC_PASS="$(openssl rand -hex 24)"
P12="$TMP/lumora-signing.p12"

printf '%s' "$P12_B64" | base64 --decode >"$P12"
if [ ! -f "$KEYCHAIN" ]; then
  security create-keychain -p "$KC_PASS" "$KEYCHAIN" >&2
  security set-keychain-settings -lut 21600 "$KEYCHAIN" >&2
  echo "$KC_PASS" >"$TMP/lumora-signing.pass"
else
  KC_PASS="$(cat "$TMP/lumora-signing.pass")"
fi
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN" >&2
security import "$P12" -k "$KEYCHAIN" -P "${CERT_PASSWORD:-}" -f pkcs12 \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild >&2
rm -f "$P12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null
# Put the keychain first in the search list (keep the existing ones).
# shellcheck disable=SC2046
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" |
  sed -nE "s/^ *[0-9]+\) [0-9A-F]{40} \"(${PREFIX}[^\"]*)\"\$/\1/p" | head -1)"
[ -n "$IDENTITY" ] || { echo "error: no \"$PREFIX\" identity in \$$VAR" >&2; security find-identity -v -p codesigning "$KEYCHAIN" >&2; exit 1; }
echo "$IDENTITY"
