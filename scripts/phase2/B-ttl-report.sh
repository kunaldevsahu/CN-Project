#!/bin/bash
# Extension B (TTL + controlled record change): builds evidence/phase2/B/01-ttl-from-E.txt from the Ext E run.
# Ext E already IS a controlled record change with TTL 30 on both DNS servers, so B reuses its logs instead of a
# separate test (cached vs flushed: mac1 waits for its cache, mac3 flushes and switches at once). Re-run after E-cutover.sh.
#   bash scripts/phase2/B-ttl-report.sh
set -uo pipefail
source "$(dirname "$0")/lib.sh"
SCRIPT_ARGS="$*"
E="$EVID/E"; OUT="$(evidence_path B 01-ttl-from-E.txt)"
[ -f "$E/04-client-loop-cutover.txt" ] || { echo "run scripts/phase2/E-cutover.sh first"; exit 1; }
{ header "Ext B · 01 TTL and a controlled record change (lines copied from the Ext E evidence, see the file names)"
  echo "## 1. The TTL every client gets: 30 s (baseline/01-dns.txt)"
  grep -E '^app\.team1\.test\..*IN[[:space:]]+A|^;; SERVER:' "$EVID/baseline/01-dns.txt" | head -2 | sed 's/^/   /'
  echo; echo "## 2. The change, on BOTH servers in the same second (E/05-set-record-to-standby.txt)"
  grep -E '^[0-9:]+  (app\.team1\.test ->|@)' "$E/05-set-record-to-standby.txt" | sed 's/^/   /'
  echo; echo "## 3. mac1 WITHOUT flushing: the server answers the new IP at once, curl keeps the cached old IP (E/04-client-loop-cutover.txt)"
  awk '/^[0-9:.]+  t\+/ { line[++n] = $0; if (!f && $3 == "server=10.7.3.175") f = n; if (!g && $4 == "curl->10.7.3.175") g = n }
       END { for (i = f - 2; i <= g + 1; i++) if (i >= 1 && (i < f + 2 || i > g - 3)) print "   " line[i]; else if (i == f + 2) print "   ... (" g - f - 4 " more lines: server new, curl old)" }' "$E/04-client-loop-cutover.txt"
  echo; echo "## 4. Why: mac1's own DNS lookups in the capture (E/08-pcap-summary.txt)"
  grep -E '^  [0-9:.]+  asked' "$E/08-pcap-summary.txt" | sed 's/^/ /'
  echo; echo "## 5. mac3 as a client: cached vs FLUSHED (E/06-mac3-as-client.txt)"
  grep -E '^## |^[0-9:.]+  OS resolver' "$E/06-mac3-as-client.txt" | sed 's/^/   /'
  echo; echo "## 6. Numbers (E/10-summary.txt)"
  grep -E 'after the change|later|time between' "$E/10-summary.txt" | sed 's/^/ /'
  echo
  echo "Reading: TTL is set by the server but enforced by every cache. dig asks the server, so it shows the new IP at once;"
  echo "curl/browsers use the OS cache (mDNSResponder) and keep the old answer until it expires. A manual flush forces a new"
  echo "lookup. On these Macs the cached answer lived ~37.7 s with TTL 30, so lower the TTL well before a planned change."
} 2>&1 | tee "$OUT"
echo "(saved: ${OUT#"$REPO"/})"
