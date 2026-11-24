#!/bin/bash
# Extension C: turn backend isolation ON.
#   Mac 3 (Himanshu):  sudo bash fw-on.sh A
#   Mac 4 (Kunal):     sudo bash fw-on.sh B
#
# Rollback copy: before changing anything this saves /etc/pf.conf and the current pf state
# to ~/team1-pf-backup/. Undo with: sudo bash fw-off.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }
case "${1:-}" in
  A) RULES="team1-backendA.pf" ;;
  B) RULES="team1-backendB.pf" ;;
  *) echo "usage: sudo bash fw-on.sh A|B"; exit 1 ;;
esac

DIR="$(cd "$(dirname "$0")" && pwd)"
USER_HOME="$(eval echo "~${SUDO_USER:-root}")"
BK="$USER_HOME/team1-pf-backup"
ANCHOR="com.apple/team1"

# 1. Rollback copy (only the first time, so a second run doesn't overwrite the original)
if [ ! -f "$BK/pf.conf.original" ]; then
  mkdir -p "$BK"
  cp /etc/pf.conf "$BK/pf.conf.original"
  pfctl -s info  > "$BK/pf-info-before.txt"  2>&1 || true
  pfctl -sr      > "$BK/pf-rules-before.txt" 2>&1 || true
  pfctl -s info 2>/dev/null | grep -q "Status: Enabled" && echo yes > "$BK/was-enabled" || echo no > "$BK/was-enabled"
  chown -R "${SUDO_USER:-root}" "$BK"
  echo "Backup saved in $BK"
fi

# 2. Syntax check our rules without loading them
pfctl -n -a "$ANCHOR" -f "$DIR/$RULES"

# 3. Make sure the stock macOS ruleset (which hooks in anchor "com.apple/*") is loaded.
#    This loads the UNMODIFIED /etc/pf.conf; we never edit that file.
if ! pfctl -sr 2>/dev/null | grep -q 'anchor "com.apple/\*"'; then
  pfctl -f /etc/pf.conf 2>/dev/null
fi

# 4. Enable pf with a reference token (fw-off.sh releases it), then load our anchor
TOKEN=$(pfctl -E 2>&1 | awk '/Token/ {print $3}')
echo "$TOKEN" > "$BK/pf-token"
pfctl -a "$ANCHOR" -f "$DIR/$RULES"

# 5. pflog0 for dropped-packet evidence (harmless if it already exists)
ifconfig pflog0 create 2>/dev/null || true

echo
echo "Backend $1 isolation ON. Rules in anchor $ANCHOR:"
pfctl -a "$ANCHOR" -sr
pfctl -s info | grep Status
