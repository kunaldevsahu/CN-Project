#!/bin/bash
# Stage 2 baseline: the healthy Phase 2 system, seen from the client (mac1). Read-only, re-run any time.
#   bash scripts/phase2/baseline.sh            # all four sections
#   bash scripts/phase2/baseline.sh lb         # one section: dns | https | lb | cache
# Evidence: evidence/phase2/baseline/01-dns.txt 02-https.txt 03-lb-loop.txt 04-cache-304.txt
set -uo pipefail
source "$(dirname "$0")/lib.sh"
SCRIPT_ARGS="$*"

dns() {
  crun "networksetup -getdnsservers Wi-Fi"
  crun "dig $NAME"                                   # plain dig: SERVER, status, TTL 30
  crun "dig +nocmd api.team1.test +noall +answer"
  crun "dscacheutil -q host -a name $NAME"           # what curl/browsers get (mDNSResponder)
}

https() {
  crun "curl -sI http://$NAME/api/status | grep -iE '^HTTP|^location'"   # port 80 -> 301 to https
  echo "Reading the verbose output: '(304) (OUT), TLS handshake' = TLS record version 0x0304 = TLS 1.3 (not HTTP 304)."
  echo "'CAfile: /etc/ssl/cert.pem' is LibreSSL's default bundle; our CA is not in it. Apple's /usr/bin/curl also uses the"
  echo "macOS keychain trust settings: before the CA was trusted the same request failed with curl (60), see edge-move/02."
  echo
  crun "curl -sv https://$NAME/api/status 2>&1 | grep -vE '^\\* +(Trying|Closing|Connection #)|^> (User-Agent|Accept)|^\\{ |^\\} |^ *$'"
  crun "curl -sS -o /dev/null -w 'ssl_verify_result=%{ssl_verify_result} (0 = trusted)  http_version=%{http_version}  code=%{http_code}  remote=%{remote_ip}:%{remote_port}\n' https://$NAME/api/status"
}

lb() {
  crun 'a=0; b=0; for i in $(seq 1 10); do
  h=$(curl -s -D - -o /dev/null https://$NAME/api/status)
  be=$(echo "$h" | hv x-backend); [ "$be" = A ] && a=$((a+1)); [ "$be" = B ] && b=$((b+1))
  printf "%s  #%-2s http=%s  x-edge=%s  x-backend=%s  x-upstream=%s\n" "$(date +%T)" $i "$(echo "$h" | awk "NR==1{print \$2}")" "$(echo "$h" | hv x-edge)" "$be" "$(echo "$h" | hv x-upstream)"
  sleep 0.5
done; echo "totals: A=$a  B=$b  (round robin -> 5/5)"'
}

cache() {
  crun "curl -sI https://$NAME/api/status | grep -iE '^HTTP|^cache-control|^etag|^x-backend'"
  crun "curl -sI https://$NAME/api/cached | grep -iE '^HTTP|^cache-control|^etag|^x-backend|^content-length'"
  echo "## Same ETag from both backends (same body), so a 304 works whichever backend answers"
  crun 'for i in 1 2 3 4; do h=$(curl -sI https://$NAME/api/cached); printf "%s  x-backend=%s  etag=%s\n" "$(date +%T)" "$(echo "$h" | hv x-backend)" "$(echo "$h" | hv etag)"; done'
  echo "## Conditional request: send the ETag back -> 304 Not Modified, no body"
  crun 'e=$(curl -sI https://$NAME/api/cached | hv etag); echo "ETag from first response: $e"
for i in 1 2; do echo "$(date +%T)  curl -sI -H \"If-None-Match: $e\" https://$NAME/api/cached"; curl -sI -H "If-None-Match: $e" https://$NAME/api/cached | grep -iE "^HTTP|^etag|^x-backend|^content-length"; done
echo "$(date +%T)  same request with a wrong ETag -> full 200"; curl -sI -H "If-None-Match: \"nope\"" https://$NAME/api/cached | grep -iE "^HTTP"'
}

section() {  # section <file> <title> <function>
  local OUT; OUT="$(evidence_path baseline "$1")"
  { header "Baseline · $2"; "$3"; } 2>&1 | tee "$OUT"
  echo "(saved: ${OUT#"$REPO"/})"; echo
}

want="${1:-all}"
[[ $want == all || $want == dns   ]] && section 01-dns.txt       "DNS: plain dig from the client (TTL 30, which server answered)" dns
[[ $want == all || $want == https ]] && section 02-https.txt     "HTTPS by name without -k (system trust), HTTP -> HTTPS redirect"  https
[[ $want == all || $want == lb    ]] && section 03-lb-loop.txt   "Load balancing: 10 requests, X-Backend alternates A/B"            lb
[[ $want == all || $want == cache ]] && section 04-cache-304.txt "Caching headers (Cache-Control, ETag) and a 304 with If-None-Match" cache
exit 0
