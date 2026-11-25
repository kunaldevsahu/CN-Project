#!/bin/bash
# Change one record on BOTH DNS servers at the same moment (Mac 1 primary + Mac 3 backup, in parallel),
# then ask both servers directly. Run on Mac 4. Both Macs run THIS repo's dns/phase2/set-record.sh (sent over ssh).
#   bash scripts/phase2/set-record-both.sh app.team1.test 10.7.30.71                          # just do it
#   bash scripts/phase2/set-record-both.sh app.team1.test 10.7.30.71 edge-move/03-set-record.txt   # + evidence file
# team1.hosts keeps app and api on one line, so changing app.team1.test also changes api.team1.test.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
N="${1:?usage: set-record-both.sh <name> <ip> [<EXT>/<file>.txt]}"; IP="${2:?usage}"; EV="${3:-}"; SCRIPT_ARGS="$*"

main() {
  header "Record change on BOTH DNS servers: $N -> $IP" \
         "Tool: dns/phase2/set-record.sh run on mac1 ($DNS1) and mac3 ($DNS2) in parallel via ssh"
  T=$(mktemp -d)
  echo "$(date +%T)  sending to mac1 + mac3"
  for h in mac1 mac3; do
    { echo "[$h]\$ bash dns/phase2/set-record.sh $N $IP"; "${SSH[@]}" "$h" bash -s -- "$N" "$IP" < "$REPO/dns/phase2/set-record.sh" 2>&1; } > "$T/$h" &
  done
  wait
  cat "$T/mac1"; echo; cat "$T/mac3"; echo; rm -rf "$T"
  echo "## Both servers asked directly from $(hostname -s) (dig @server, no client cache involved)"
  for s in "$DNS1" "$DNS2"; do for n in app.team1.test api.team1.test; do
    printf '%s  @%-12s %s\n' "$(date +%T)" "$s" "$(dig +nocmd @"$s" "$n" +noall +answer +time=2 +tries=1 | tr -s ' \t' ' ')"
  done; done
}

if [ -n "$EV" ]; then
  OUT="$(evidence_path "$(dirname "$EV")" "$(basename "$EV")")"
  main 2>&1 | tee "$OUT"; echo "(saved: ${OUT#"$REPO"/})"
else
  main
fi
