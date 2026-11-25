#!/bin/bash
# Shared helpers for scripts/phase2/*.sh. Source it, don't run it.
# All scripts run on Mac 4 (the edge, 10.7.30.71); client-side commands run on $CLIENT (default mac1) over ssh,
# and the output (with a header and timestamps) is tee'd into evidence/phase2/<EXT>/.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVID="$REPO/evidence/phase2"

NAME="${NAME:-app.team1.test}"
EDGE_IP="10.7.30.71"        # Mac 4, Kunal: primary edge + Backend B :3002
STANDBY_IP="10.7.3.175"     # Mac 3, Himanshu: backup DNS + Backend A :3001 + standby edge
DNS1="10.7.17.233"          # Mac 1, Vaibhav: primary DNS + main test client
DNS2="10.7.3.175"           # Mac 3: backup DNS
A_HP="10.7.3.175:3001"
B_HP="10.7.30.71:3002"
CLIENT="${CLIENT:-mac1}"    # ssh alias of the test client
CA="$REPO/certs/rootCA.pem" # public CA cert ("Team1 Local Root CA 2026-11")

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=6)

# Evidence header: title, date/time, which Mac ran it, the exact invocation.
header() {  # header "<title>" "<extra line>"...
  echo "# $1"
  echo "# Date:      $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "# Run on:    $(hostname -s) $(ipconfig getifaddr en0)  (script: ${0#"$REPO"/} ${SCRIPT_ARGS:-})"
  echo "# Client:    $CLIENT = $("${SSH[@]}" "$CLIENT" 'echo "$(hostname -s) $(ipconfig getifaddr en0)"' 2>/dev/null)"
  shift; for l in "$@"; do echo "# $l"; done
  echo "# Every command is printed before its output: '\$ ' = this Mac, '[$CLIENT]\$ ' = the client."
  echo
}

# Prefix every line with the time (date +%T)
ts() { while IFS= read -r l; do printf '%s  %s\n' "$(date +%T)" "$l"; done; }

# Run a command on this Mac, printing it first
run() { echo "\$ $*"; bash -c "$*" 2>&1; echo; }

# Prelude sent ahead of every client command (client runs it with bash, whatever its login shell is).
#   tcurl = curl WITHOUT -k. Only while the client does not trust our CA yet (curl exit 60) it adds
#           --cacert <our rootCA.pem> (full chain + name verification still happens). Nothing is written on the client.
#   hv    = value of one response header from a `curl -D -` dump
client_prelude() {
  cat <<EOF
NAME='$NAME'; EDGE_IP='$EDGE_IP'; STANDBY_IP='$STANDBY_IP'
CA_PEM='$(cat "$CA")'
curl -s -o /dev/null --max-time 4 --resolve "\$NAME:443:\$EDGE_IP" "https://\$NAME/" ; [ \$? -eq 60 ] && NEED_CA=1
[ "\${NEED_CA:-}" = 1 ] && echo "  (note: CA not yet trusted in this client's keychain -> curl gets --cacert rootCA.pem; still verified, NOT -k)"
tcurl() { if [ "\${NEED_CA:-}" = 1 ]; then curl --cacert <(printf '%s\n' "\$CA_PEM") "\$@"; else curl "\$@"; fi; }
hv() { awk -F': ' -v k="\$1" 'tolower(\$1)==k{gsub("\r","",\$2);print \$2}'; }
EOF
}

# Run a command (or a multi-line bash snippet) on the client, printing it first ("tcurl" shown as "curl")
crun() {
  echo "[$CLIENT]\$ ${*//tcurl/curl}"
  { client_prelude; printf '%s\n' "$*"; } | "${SSH[@]}" "$CLIENT" bash -s 2>&1
  echo
}

evidence_path() { mkdir -p "$EVID/$1"; echo "$EVID/$1/$2"; }

# Header value from a curl -D - dump (this Mac)
hval() { awk -F': ' -v k="$(echo "$1" | tr 'A-Z' 'a-z')" 'tolower($1)==k{gsub("\r","",$2);print $2}'; }
