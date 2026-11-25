#!/bin/bash
# Extension E: issue a SEPARATE certificate for the standby edge (Mac 3, Himanshu),
# signed by the SAME Team1 Local Root CA. Run where rootCA.key lives (Phase 2: Mac 4, Kunal), in this folder,
# after make-certs.sh has already created rootCA.pem / rootCA.key.
#
# Why a new cert instead of copying team1.key to Mac 3:
#   - clients trust the CA, not one particular certificate, so no client changes are needed
#   - each edge keeps its own private key; losing one edge's key doesn't expose the other
#
# Output: team1-standby.crt + team1-standby.key -> AirDrop both to Himanshu, who installs them
#         as team1.crt / team1.key (see docs/PHASE2-SETUP.md, Extension E). Delete them from
#         Downloads afterwards. The CA key (rootCA.key) never leaves the Mac that made it.
# Phase 2: copied straight to mac3 with scp (chmod 600), local standby key deleted (evidence/phase2/E/01).
set -e
cd "$(dirname "$0")"
OPENSSL="$(brew --prefix openssl@3)/bin/openssl"
[ -f rootCA.pem ] && [ -f rootCA.key ] || { echo "rootCA.pem / rootCA.key not found: run in certs/ on the Mac that holds the CA key"; exit 1; }

# Same names (SANs) as the primary: the certificate proves the NAME, not the machine's IP
$OPENSSL req -new -nodes -newkey rsa:2048 \
  -keyout team1-standby.key -out team1-standby.csr -config leaf.cnf

$OPENSSL x509 -req -in team1-standby.csr -CA rootCA.pem -CAkey rootCA.key \
  -CAcreateserial -out team1-standby.crt -days 397 -sha256 \
  -extfile leaf.cnf -extensions v3_leaf

$OPENSSL verify -CAfile rootCA.pem team1-standby.crt
$OPENSSL x509 -in team1-standby.crt -noout -serial -ext subjectAltName
echo
echo "Primary cert serial (for comparison):"
$OPENSSL x509 -in team1.crt -noout -serial 2>/dev/null || true
echo "AirDrop team1-standby.crt and team1-standby.key to Mac 3 only."
