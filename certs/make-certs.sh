#!/bin/bash
# Recreates the Team 1 root CA and the server certificate (run on Mac 2, Kevish).
# These are the exact commands used on 2026-10-02.
# Output: rootCA.pem (share with clients), rootCA.key + team1.key (NEVER share), team1.crt
set -e
cd "$(dirname "$0")"
OPENSSL="$(brew --prefix openssl@3)/bin/openssl"   # macOS's own openssl is LibreSSL
$OPENSSL version

# 1. Root CA
$OPENSSL req -x509 -new -nodes -newkey rsa:2048 \
  -keyout rootCA.key -out rootCA.pem -days 825 \
  -config ca.cnf -extensions v3_ca

# 2. Server key + CSR, signed by the CA
$OPENSSL req -new -nodes -newkey rsa:2048 \
  -keyout team1.key -out team1.csr -config leaf.cnf

$OPENSSL x509 -req -in team1.csr -CA rootCA.pem -CAkey rootCA.key \
  -CAcreateserial -out team1.crt -days 397 -sha256 \
  -extfile leaf.cnf -extensions v3_leaf

# 3. Verify
$OPENSSL verify -CAfile rootCA.pem team1.crt
$OPENSSL x509 -in team1.crt -noout -ext subjectAltName

# 4. Install into nginx
mkdir -p "$(brew --prefix)/etc/nginx/certs"
cp team1.crt team1.key "$(brew --prefix)/etc/nginx/certs/"
chmod 600 "$(brew --prefix)/etc/nginx/certs/team1.key"
echo "Done. AirDrop ONLY rootCA.pem to the client Macs."
