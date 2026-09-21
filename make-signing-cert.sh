#!/bin/zsh
# One-time: creates a local self-signed code-signing certificate named "AirToggle Local Signing"
# and imports it into your login keychain. build.sh then signs with it automatically, so macOS
# keeps recognising AirToggle (and its Accessibility permission) across rebuilds.
set -euo pipefail
# Certificate common name. Pass a different one as the first argument if needed.
NAME="${1:-AirToggle Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Certificate '$NAME' already exists."; exit 0
fi
TMP=$(mktemp -d)
cat > "$TMP/cs.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/cs.key" -out "$TMP/cs.crt" -config "$TMP/cs.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/cs.key" -in "$TMP/cs.crt" -out "$TMP/cs.p12" -passout pass:airtoggle -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/cs.key" -in "$TMP/cs.crt" -out "$TMP/cs.p12" -passout pass:airtoggle
security import "$TMP/cs.p12" -k ~/Library/Keychains/login.keychain-db -P airtoggle -T /usr/bin/codesign -T /usr/bin/security
rm -rf "$TMP"
echo "Created '$NAME'. Now run ./build.sh --install and grant Accessibility one last time."
