#!/bin/bash
# Extension C: turn backend isolation OFF and restore the pre-demo state.
#   sudo bash fw-off.sh
set -uo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }
USER_HOME="$(eval echo "~${SUDO_USER:-root}")"
BK="$USER_HOME/team1-pf-backup"
ANCHOR="com.apple/team1"

# 1. Remove our rules (the rest of the ruleset is untouched)
pfctl -a "$ANCHOR" -F all 2>/dev/null

# 2. Release our enable token; pf goes back to disabled if nothing else holds a reference
if [ -s "$BK/pf-token" ]; then
  pfctl -X "$(cat "$BK/pf-token")" 2>/dev/null
  rm -f "$BK/pf-token"
fi
if [ "$(cat "$BK/was-enabled" 2>/dev/null)" = "no" ]; then
  pfctl -d 2>/dev/null   # it was off before the demo, so make sure it is off now
fi

# 3. /etc/pf.conf was never edited, but prove it matches the rollback copy
if [ -f "$BK/pf.conf.original" ]; then
  if cmp -s /etc/pf.conf "$BK/pf.conf.original"; then
    echo "/etc/pf.conf identical to backup"
  else
    cp "$BK/pf.conf.original" /etc/pf.conf && pfctl -f /etc/pf.conf
    echo "/etc/pf.conf restored from backup"
  fi
fi

echo "Rules left in $ANCHOR:"; pfctl -a "$ANCHOR" -sr 2>/dev/null | sed 's/^/  /'; echo "  (none expected)"
pfctl -s info | grep Status
