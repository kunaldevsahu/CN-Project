#!/bin/bash
# Extension C: turn backend isolation OFF and prove pf is back to its BEFORE state. Run on Mac 4.
#   bash scripts/phase2/C-rollback.sh
# Per Mac (mac3 and this Mac), only `sudo -n /sbin/pfctl` is used:
#   flush anchor com.apple/team1 -> release our reference token (pfctl -X) -> pfctl -d ONLY if pf was disabled before
#   -> save the AFTER state and diff it against BEFORE (empty diff = restored) -> archive the state dir.
# Evidence: evidence/phase2/C/07-rollback.txt, 08-before-after-diff.txt
set -uo pipefail
source "$(dirname "$0")/lib.sh"
SCRIPT_ARGS="$*"
TS=$(date +%Y%m%d-%H%M%S)

rollback_snippet="BK=~/team1-pf-backup; PF='sudo -n /sbin/pfctl'; TS=$TS"'
quiet() { grep -vE "Use of -f option|present in the main ruleset|See /etc/pf.conf|^$" || true; }
echo "== $(scutil --get LocalHostName) $(ipconfig getifaddr en0)"
[ -f "$BK/was-enabled" ] || echo "WARNING: no saved before-state in $BK (was C-apply.sh run?). Flushing the anchor anyway."
echo "\$ sudo -n /sbin/pfctl -a com.apple/team1 -F all"; $PF -a com.apple/team1 -F all 2>&1 | quiet | sed "s/^/   /"
if [ -s "$BK/pf-token" ]; then echo "\$ sudo -n /sbin/pfctl -X $(cat "$BK/pf-token")      # release our reference"
  $PF -X "$(cat "$BK/pf-token")" 2>&1 | quiet | sed "s/^/   /"; rm -f "$BK/pf-token"; fi
if [ "$(cat "$BK/was-enabled" 2>/dev/null)" = no ] && $PF -si 2>/dev/null | grep -q "Status: Enabled"; then
  echo "\$ sudo -n /sbin/pfctl -d      # pf was DISABLED before isolation"; $PF -d 2>&1 | quiet | sed "s/^/   /"
elif [ "$(cat "$BK/was-enabled" 2>/dev/null)" = yes ]; then echo "(pf was ENABLED before isolation: leaving it enabled, no pfctl -d)"; fi
$PF -sr > "$BK/pf-rules-after.txt" 2>/dev/null; $PF -si > "$BK/pf-info-after.txt" 2>/dev/null; $PF -a com.apple/team1 -sr > "$BK/pf-anchor-after.txt" 2>/dev/null
echo "--- restored?"
echo "   main rules (pfctl -sr) diff before/after: $(diff -q "$BK/pf-rules-before.txt" "$BK/pf-rules-after.txt" >/dev/null && echo "EMPTY (identical)" || echo "DIFFERENT")"
echo "   anchor com.apple/team1 rules: before $(wc -l < "$BK/pf-anchor-before.txt" | tr -d " ")  after $(wc -l < "$BK/pf-anchor-after.txt" | tr -d " ")"
echo "   status: before $(awk "/Status/{print \$2}" "$BK/pf-info-before.txt")  after $(awk "/Status/{print \$2}" "$BK/pf-info-after.txt")"
echo "   /etc/pf.conf: $(cmp -s /etc/pf.conf "$BK/pf.conf.original" && echo "unchanged" || echo "CHANGED")"
mkdir -p "$BK/done-$TS"; mv "$BK"/pf-*.txt "$BK"/was-enabled "$BK"/saved-at "$BK"/loaded-rules.pf "$BK"/pf.conf.original "$BK/done-$TS/" 2>/dev/null
echo "   state archived in ~/team1-pf-backup/done-$TS/ (next C-apply.sh saves a fresh before-state)"'

diff_snippet='D=~/team1-pf-backup/done-'"$TS"'; echo "\$ diff pf-rules-before.txt pf-rules-after.txt   (sudo -n /sbin/pfctl -sr)"
diff "$D/pf-rules-before.txt" "$D/pf-rules-after.txt" && echo "   (empty diff: main ruleset identical)"
echo "\$ diff pf-anchor-before.txt pf-anchor-after.txt  (sudo -n /sbin/pfctl -a com.apple/team1 -sr)"
diff "$D/pf-anchor-before.txt" "$D/pf-anchor-after.txt" && echo "   (empty diff: anchor empty again)"
echo "\$ diff <(grep -oE \"Status: (Enabled|Disabled)\" pf-info-before.txt) <(grep -oE ... pf-info-after.txt)   (state only, not the uptime)"
SB=$(grep -oE "Status: (Enabled|Disabled)" "$D/pf-info-before.txt"); SA=$(grep -oE "Status: (Enabled|Disabled)" "$D/pf-info-after.txt")
echo "   before: ${SB:-MISSING}   after: ${SA:-MISSING}"
[ -n "$SB" ] && [ "$SB" = "$SA" ] && echo "   (empty diff: same state as before)" || echo "   DIFFERENT (or missing)"
echo "\$ cmp /etc/pf.conf pf.conf.original"; cmp /etc/pf.conf "$D/pf.conf.original" && echo "   (identical)"'

diff_report() {
  OUT2="$(evidence_path C 08-before-after-diff.txt)"
  { header "Ext C · 08 pf state BEFORE vs AFTER rollback (an empty diff = restored)" "Archived state: ~/team1-pf-backup/done-$TS/ on each Mac"
    echo "## mac3"; on mac3 "$diff_snippet"; echo; echo "## Mac 4 (this Mac)"; on local "$diff_snippet"; } 2>&1 | tee "$OUT2"
}
# Rebuild 08 from an earlier rollback's archive without touching pf:  C-rollback.sh --diff-only 20261125-152110
if [ "${1:-}" = "--diff-only" ]; then
  TS="${2:?usage: C-rollback.sh --diff-only <TS of done-<TS> dir>}"
  diff_snippet="D=~/team1-pf-backup/done-$TS;${diff_snippet#*;}"   # swap the leading "D=...;" for the given archive
  diff_report; exit 0
fi

OUT="$(evidence_path C 07-rollback.txt)"
{ header "Ext C · 07 isolation OFF (rollback) on mac3 and Mac 4"
  echo "## mac3"; on mac3 "$rollback_snippet"; echo
  echo "## Mac 4 (this Mac)"; on local "$rollback_snippet"; echo
  echo "## Direct access works again (from $CLIENT, the client)"
  crun "for hp in 10.7.3.175:3001 10.7.30.71:3002; do echo \"\$(tsm)  nc -vz -G 3 \${hp%:*} \${hp#*:}: \$(nc -vz -G 3 \${hp%:*} \${hp#*:} 2>&1 | tail -1)\"; done"
} 2>&1 | tee "$OUT"
diff_report
echo "(saved in $EVID/C/: 07-rollback.txt 08-before-after-diff.txt)"
