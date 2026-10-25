#!/bin/zsh
# One-time: creates a self-signed "VOIX Local Signing" certificate in your login keychain.
# build.sh signs with it, so macOS permissions survive rebuilds.
set -e
NAME="VOIX Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "\"$NAME\" already exists."; exit 0
fi
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cat > "$D/cfg" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/key.pem" -out "$D/cert.pem" -days 3650 -config "$D/cfg" 2>/dev/null
openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -out "$D/voix.p12" -passout pass:voix \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import "$D/voix.p12" -k ~/Library/Keychains/login.keychain-db -P voix -T /usr/bin/codesign
echo "Created \"$NAME\". Now run ./build.sh"
