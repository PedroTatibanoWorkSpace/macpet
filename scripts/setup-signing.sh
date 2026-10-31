#!/usr/bin/env bash
# Cria um certificado de assinatura local ("MacPet Local Signing") no seu Keychain de login.
#
# Por quê: sem conta paga da Apple o app é assinado ad-hoc e cada build vira um "app novo"
# para o macOS, que esquece a permissão de Acessibilidade (usada pelo modo limpeza).
# Com uma identidade fixa, a permissão sobrevive a rebuilds.
#
# Rode uma vez:  ./scripts/setup-signing.sh
set -euo pipefail

NAME="MacPet Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
    echo "Identidade \"$NAME\" já existe."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg.cnf" <<EOF
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

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes -config "$TMP/cfg.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/macpet.p12" -passout pass:macpet 2>/dev/null \
    || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/macpet.p12" -passout pass:macpet
security import "$TMP/macpet.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P macpet -T /usr/bin/codesign

echo "Pronto. Agora rode: make install"
