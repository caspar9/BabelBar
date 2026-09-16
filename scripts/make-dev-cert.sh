#!/bin/bash
# Creates a self-signed code-signing identity in the login keychain so local
# builds get a *stable* designated requirement (identifier + certificate)
# instead of the per-build cdhash that ad-hoc signing produces.
#
# Why: macOS TCC (Screen Recording, Microphone) and the Keychain remember the
# app by its designated requirement. With ad-hoc signing that requirement is
# the binary's hash, so every rebuild invalidates all granted permissions and
# the user is prompted again. With this identity, grants survive rebuilds.
#
# Usage: scripts/make-dev-cert.sh [identity-name]   (default: "BabelBar Dev")
# Then:  make build   (the Makefile picks the identity up automatically)
set -euo pipefail

NAME="${1:-BabelBar Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "Code-signing identity \"$NAME\" already exists — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[dn]
CN = $NAME
[ext]
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
basicConstraints     = critical, CA:false
subjectKeyIdentifier = hash
CNF

# Use the system LibreSSL: its PKCS#12 output is what `security import` expects.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass:babelbar

# -T lets codesign use the private key without a per-signing prompt.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P babelbar \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Trust the self-signed cert for code signing (user trust domain; macOS may
# ask for your login password once).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Created identity \"$NAME\". Next: make build && make install"
else
  echo "Identity not visible yet — open Keychain Access, find \"$NAME\", and set Code Signing trust to Always Trust."
  exit 1
fi
