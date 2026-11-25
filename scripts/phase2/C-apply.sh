#!/bin/bash
# Extension C: turn backend isolation ON (pf), run on Mac 4. Acts on mac3 (Backend A, :3001) and this Mac (Backend B, :3002).
#   bash scripts/phase2/C-apply.sh            # then: bash scripts/phase2/C-test.sh ; undo: bash scripts/phase2/C-rollback.sh
#
# Per Mac, only `sudo -n /sbin/pfctl` is used:
#   1. save the pf state BEFORE (pfctl -sr, -si, the anchor, /etc/pf.conf, enabled yes/no) in ~/team1-pf-backup/
#      (only once: running apply twice keeps the original before-state) + copies in ~/backups/
#   2. syntax check (pfctl -n), enable pf with a reference token (pfctl -E), load the rules into anchor com.apple/team1
# /etc/pf.conf and the main ruleset are never changed: macOS's stock ruleset already evaluates "anchor com.apple/*".
# Evidence: evidence/phase2/C/00-before-<mac>.txt, 01-apply.txt
set -uo pipefail
source "$(dirname "$0")/lib.sh"
SCRIPT_ARGS="$*"

apply_snippet() {  # apply_snippet <rules file> -> bash snippet for the target Mac
  cat <<EOF
BK=~/team1-pf-backup; mkdir -p "\$BK" ~/backups; TS=\$(date +%Y%m%d-%H%M%S)
PF="sudo -n /sbin/pfctl"; quiet() { grep -vE 'Use of -f option|present in the main ruleset|See /etc/pf.conf|^\$' || true; }
echo "== \$(scutil --get LocalHostName) \$(ipconfig getifaddr en0)   rules: ${1#"$REPO"/}"
if [ -f "\$BK/was-enabled" ]; then
  echo "before-state already saved at \$(cat "\$BK/saved-at") (isolation still on from an earlier run): keeping that original"
else
  \$PF -sr > "\$BK/pf-rules-before.txt" 2>/dev/null; \$PF -si > "\$BK/pf-info-before.txt" 2>/dev/null
  \$PF -a com.apple/team1 -sr > "\$BK/pf-anchor-before.txt" 2>/dev/null; cp /etc/pf.conf "\$BK/pf.conf.original"
  grep -q "Status: Enabled" "\$BK/pf-info-before.txt" && echo yes > "\$BK/was-enabled" || echo no > "\$BK/was-enabled"
  date '+%F %T' > "\$BK/saved-at"
  cp "\$BK/pf-rules-before.txt" ~/backups/pf-rules-before.\$TS.txt; cp "\$BK/pf-info-before.txt" ~/backups/pf-info-before.\$TS.txt
  echo "before-state saved: ~/team1-pf-backup/ + ~/backups/pf-{rules,info}-before.\$TS.txt"
fi
echo "pf enabled BEFORE: \$(cat "\$BK/was-enabled")   (\$(grep Status "\$BK/pf-info-before.txt" | awk '{print \$1, \$2}'))"
cat > "\$BK/loaded-rules.pf" <<'PFEOF'
$(cat "$1")
PFEOF
echo "\\\$ sudo -n /sbin/pfctl -n -a com.apple/team1 -f ~/team1-pf-backup/loaded-rules.pf     # syntax check only"
\$PF -n -a com.apple/team1 -f "\$BK/loaded-rules.pf" 2>&1 | quiet
if [ -s "\$BK/pf-token" ]; then echo "pf reference token already held: \$(cat "\$BK/pf-token")"
else echo "\\\$ sudo -n /sbin/pfctl -E                                                     # enable pf, take a reference token"
     out=\$(\$PF -E 2>&1); echo "\$out" | quiet | sed 's/^/   /'; echo "\$out" | awk '/Token/{print \$3}' > "\$BK/pf-token"; fi
echo "\\\$ sudo -n /sbin/pfctl -a com.apple/team1 -f ~/team1-pf-backup/loaded-rules.pf"
\$PF -a com.apple/team1 -f "\$BK/loaded-rules.pf" 2>&1 | quiet
echo "\\\$ sudo -n /sbin/pfctl -a com.apple/team1 -sr"; \$PF -a com.apple/team1 -sr 2>/dev/null | sed 's/^/   /'
echo "\\\$ sudo -n /sbin/pfctl -si | grep Status"; \$PF -si 2>/dev/null | grep Status | sed 's/^/   /'
EOF
}

before_snippet='BK=~/team1-pf-backup; echo "# saved $(cat $BK/saved-at), pf enabled before: $(cat $BK/was-enabled)"; echo "## sudo -n /sbin/pfctl -si"; cat $BK/pf-info-before.txt; echo; echo "## sudo -n /sbin/pfctl -sr"; cat $BK/pf-rules-before.txt; echo; echo "## sudo -n /sbin/pfctl -a com.apple/team1 -sr  (lines: $(wc -l < $BK/pf-anchor-before.txt | tr -d " "))"; cat $BK/pf-anchor-before.txt'

OUT="$(evidence_path C 01-apply.txt)"
{ header "Ext C · 01 isolation ON: pf anchor com.apple/team1 on mac3 (:3001) and Mac 4 (:3002)" \
    "Allowed: mac3 :3001 <- 10.7.30.71 (edge) + lo0 ;  Mac 4 :3002 <- 10.7.3.175 (standby edge) + lo0 (edge uses 127.0.0.1)"
  echo "## mac3 (Backend A)"; on mac3 "$(apply_snippet "$REPO/firewall/team1-backendA.pf")"; echo
  echo "## Mac 4 (Backend B, this Mac)"; on local "$(apply_snippet "$REPO/firewall/team1-backendB.pf")"
} 2>&1 | tee "$OUT"
for m in mac3 local; do
  n=$([ $m = local ] && echo mac4 || echo $m)
  { header "Ext C · 00 pf state BEFORE isolation on $n (saved by C-apply.sh)"; on $m "$before_snippet"; } > "$(evidence_path C "00-before-$n.txt")" 2>&1
done
echo "(saved in $EVID/C/: 00-before-mac3.txt 00-before-mac4.txt 01-apply.txt)"
