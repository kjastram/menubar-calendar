#!/bin/sh
# Creates a self-signed code-signing certificate "Almanac Local Signing" in the login keychain.
# build-app.sh signs with it, so the app keeps the same identity across rebuilds and the
# Keychain doesn't ask for permission again after every build. Safe to run more than once.
set -eu

NAME="Almanac Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# An identity is the certificate plus its private key. find-identity lists it even before it is trusted.
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
    echo "\"$NAME\" is already in the login keychain with its private key. Nothing to do."
    exit 0
fi
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    cat >&2 <<MSG
"$NAME" is in the login keychain, but its private key is missing, so codesign can't use it.
Delete the certificate, then run this script again:
  security delete-certificate -c "$NAME" "$KEYCHAIN"
(or in Keychain Access: login → Certificates, select "$NAME", Delete).
MSG
    exit 1
fi

# LibreSSL in /usr/bin writes a PKCS#12 file that `security import` can read.
# (OpenSSL 3's default AES-based PKCS#12 fails with "MAC verification failed".)
OPENSSL=/usr/bin/openssl
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# Random password for the temporary .p12 file (deleted on exit). openssl reads it from the
# environment so it doesn't show up in `ps`.
P12_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
export P12_PASS

cat >"$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

echo "Creating the certificate (valid for 10 years)…"
"$OPENSSL" req -new -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
    -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -passout env:P12_PASS -out "$WORK/cert.p12"

echo "Importing into the login keychain (codesign may use the key)…"
# `security import` takes the password only as -P (on the command line) or from a GUI prompt;
# it has no environment or file option. The password only protects the short-lived file above.
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -f pkcs12 -T /usr/bin/codesign

echo "Trusting it for code signing. macOS will ask for your login password in a dialog."
if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"; then
    cat <<MSG

Couldn't set trust automatically. Do it by hand (signing still works without it,
but \`security find-identity -v\` won't list it as valid):
  1. Open Keychain Access, find "$NAME" under login → My Certificates.
  2. Double-click it, open Trust, set "Code Signing" to "Always Trust", close and enter your password.
MSG
fi

cat <<MSG

Done. Run scripts/build-app.sh to build and sign Almanac.app with "$NAME".
The first build may show "codesign wants to sign using key …": enter your login
password and click "Always Allow" so later builds don't ask.
MSG
