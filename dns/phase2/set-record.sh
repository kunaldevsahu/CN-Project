#!/bin/bash
# Change one record in team1.hosts and make dnsmasq reload it (no restart).
# Run on EACH DNS server (Mac 1 primary and Mac 3 backup), within a few seconds of each other,
# otherwise clients that ask the backup get a different answer from clients that ask the primary.
#
#   bash set-record.sh app.team1.test 10.7.3.175    # cut over to the standby edge (Mac 3)
#   bash set-record.sh app.team1.test 10.7.30.71    # back to the primary edge (Mac 4, since Phase 2)
#   bash set-record.sh --show                        # print the current records
# From Mac 4 for both DNS Macs at once: bash scripts/phase2/set-record-both.sh <name> <ip>
# (team1.hosts keeps app and api on ONE line, so changing app also changes api.)
set -euo pipefail

# Over ssh (non-interactive shell) brew is not on PATH, so fall back to the Apple-silicon prefix
HOSTS="$(brew --prefix 2>/dev/null || echo /opt/homebrew)/etc/team1.hosts"

if [[ "${1:-}" == "--show" ]]; then
  grep -v '^#' "$HOSTS" | sed '/^$/d'
  exit 0
fi

NAME="${1:?usage: set-record.sh <name> <ip> | --show}"
IP="${2:?usage: set-record.sh <name> <ip> | --show}"

if ! [[ "$IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo "Not an IPv4 address: $IP" >&2; exit 1
fi
if ! grep -qE "[[:space:]]${NAME//./\\.}([[:space:]]|$)" "$HOSTS"; then
  echo "No record for $NAME in $HOSTS" >&2; exit 1
fi

cp "$HOSTS" "$HOSTS.bak"
# Replace the IP on the line for NAME, keep every other line as it is
awk -v n="$NAME" -v ip="$IP" '
  /^[[:space:]]*#/ || NF < 2 { print; next }
  { for (i = 2; i <= NF; i++) if ($i == n) { $1 = ip; break } print }
' "$HOSTS.bak" > "$HOSTS"

# SIGHUP: dnsmasq re-reads addn-hosts and clears its own cache
sudo -n /usr/bin/pkill -HUP -x dnsmasq   # passwordless rule from scripts/phase2/bootstrap-mac.sh

echo "$(date +%H:%M:%S)  $NAME -> $IP  (dnsmasq reloaded on $(scutil --get LocalHostName))"
sleep 1
dig +nocmd @127.0.0.1 "$NAME" +noall +answer
