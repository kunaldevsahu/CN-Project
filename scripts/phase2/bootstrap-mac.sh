#!/bin/bash
# One-time setup per Mac for Phase 2 (run it AT the Mac, in its own Terminal, not over ssh:
# trusting a CA may pop up a macOS password dialog).
#
#   Mac 4 (Kunal):           sudo bash ~/CN-Project/scripts/phase2/bootstrap-mac.sh
#   Mac 1 (Vaibhav), Mac 3:  sudo bash ~/Downloads/team1-bootstrap-mac.sh
#
# What it does, and nothing else:
#   1. /etc/sudoers.d/team1-demo: passwordless sudo for exactly these 10 programs (old file shown + backed up,
#      new file checked with visudo -cf before it is installed)
#   2. trusts the Phase 2 CA "Team1 Local Root CA 2026-11" in the System keychain, only if its SHA-256
#      fingerprint matches (old Team1 CAs are left alone)
#   3. DNS Macs only: makes /opt/homebrew/etc/team1.hosts owned by you, so set-record.sh can rewrite it
set -euo pipefail

[ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] || { echo "Run it as: sudo bash $0"; exit 1; }
U="$SUDO_USER"; UHOME="$(eval echo "~$U")"; TS="$(date +%Y%m%d-%H%M%S)"
BK="$UHOME/backups"; mkdir -p "$BK"; chown "$U" "$BK"
FP_EXPECTED="89:CC:62:AE:C2:F2:03:F2:22:E0:4A:15:87:9B:73:AF:BC:4F:5D:37:71:E7:84:DE:A6:F9:F9:30:F8:03:3B:6A"
SUDOERS=/etc/sudoers.d/team1-demo
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "== $(hostname -s) $(ipconfig getifaddr en0)  user=$U  $(date '+%F %T')"

# ---------------------------------------------------------------- 1. sudoers
echo; echo "== 1. Passwordless sudo ($SUDOERS)"
grep -nE '^[#@]includedir' /etc/sudoers | sed 's/^/   \/etc\/sudoers: /' || echo "   WARNING: /etc/sudoers has no includedir line, files in /etc/sudoers.d are ignored"
if [ -f "$SUDOERS" ]; then
  echo "   current file (this is what did not work):"; sed 's/^/     | /' "$SUDOERS"
  cp -p "$SUDOERS" "$BK/team1-demo.sudoers.$TS"; chown "$U" "$BK/team1-demo.sudoers.$TS"
  echo "   backup: $BK/team1-demo.sudoers.$TS"
fi
TMP="$(mktemp /tmp/team1-sudoers.XXXXXX)"
cat > "$TMP" <<EOF
# Team 1 CN project, Phase 2 (scripts/phase2/bootstrap-mac.sh, $TS). Remove after the course: sudo rm $SUDOERS
$U ALL=(root) NOPASSWD: /opt/homebrew/sbin/dnsmasq, /usr/bin/pkill, /usr/bin/killall, /opt/homebrew/bin/brew, /sbin/pfctl, /usr/sbin/networksetup, /usr/bin/dscacheutil, /opt/homebrew/bin/nginx, /usr/sbin/tcpdump, /usr/sbin/lsof
EOF
if visudo -cf "$TMP" >/dev/null; then
  install -m 0440 -o root -g wheel "$TMP" "$SUDOERS"; rm -f "$TMP"
  echo "   installed + syntax OK:"; sed 's/^/     | /' "$SUDOERS"
else
  visudo -cf "$TMP"; rm -f "$TMP"; echo "   NOT installed: syntax check failed"; exit 1
fi
visudo -c >/dev/null && echo "   visudo -c: whole sudoers config OK"
if sudo -n -l -U "$U" 2>/dev/null | grep -q 'NOPASSWD: /opt/homebrew/sbin/dnsmasq'; then echo "   OK: $U now has the NOPASSWD rule"
else echo "   WARNING: sudo -l -U $U does not show the rule"; sudo -l -U "$U" | sed 's/^/     /'; fi

# ---------------------------------------------------------------- 2. CA trust
echo; echo "== 2. Trust the Phase 2 CA"
CA=""
for c in "${1:-}" "$HERE/../../certs/rootCA.pem" "$HERE/team1-rootCA-2026-11.pem" "$UHOME/Downloads/team1-rootCA-2026-11.pem"; do
  [ -n "$c" ] && [ -f "$c" ] && { CA="$c"; break; }
done
[ -n "$CA" ] || { echo "   rootCA file not found (give its path as the first argument)"; exit 1; }
FP="$(openssl x509 -in "$CA" -noout -fingerprint -sha256 | sed 's/.*=//')"
echo "   file: $CA"; echo "   subject: $(openssl x509 -in "$CA" -noout -subject)"; echo "   sha256:  $FP"
[ "$FP" = "$FP_EXPECTED" ] || { echo "   FINGERPRINT MISMATCH, not trusting this file"; exit 1; }
FPH="$(echo "$FP" | tr -d ':')"
if security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null | grep -q "$FPH" \
   && security dump-trust-settings -d 2>/dev/null | grep -q "Team1 Local Root CA 2026-11"; then
  echo "   already in the System keychain and trusted"
else
  if security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CA"; then
    echo "   added + trusted (System keychain)"
  else
    echo "   FAILED to trust the CA (were you at the Mac to approve the dialog?). Re-run the script."
  fi
fi
security find-certificate -a -c "Team1 Local Root CA" -Z /Library/Keychains/System.keychain 2>/dev/null \
  | awk '/SHA-256/{h=$3} /"labl"/{sub(/.*="/,""); sub(/"$/,""); print "   in System keychain: " $0 "  " substr(h,1,16) "..."}'

# ---------------------------------------------------------------- 3. DNS Macs: team1.hosts owner
echo; echo "== 3. team1.hosts (DNS Macs only)"
H=/opt/homebrew/etc/team1.hosts
if [ -f "$H" ]; then
  ls -l "$H" | sed 's/^/   before: /'
  cp -p "$H" "$BK/team1.hosts.$TS"; chown "$U" "$BK/team1.hosts.$TS"
  chown "$U:admin" "$H"; [ -f "$H.bak" ] && chown "$U:admin" "$H.bak"
  ls -l "$H" | sed 's/^/   after:  /'
else
  echo "   not a DNS Mac (no $H), nothing to do"
fi

echo; echo "== Done. This Mac is ready."
