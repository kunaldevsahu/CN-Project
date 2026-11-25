#!/bin/bash
# Extension A side check: do the primary (mac1) and the backup (mac3) treat the zone team1.test the same way?
# Both serve the same team1.hosts, but only mac1's dnsmasq.conf has `local=/team1.test/` (+ no-hosts). Without it,
# a team1.test name that is NOT in team1.hosts (or a record type it doesn't have) is forwarded to the internet.
# Run on Mac 4. Read-only except a short capture on mac3.
#   bash scripts/phase2/A-zone-check.sh
# Evidence: evidence/phase2/A/07-zone-config-check.txt, 08-mac3-upstream.pcap
set -uo pipefail
source "$(dirname "$0")/lib.sh"
SCRIPT_ARGS="$*"
A="$EVID/A"; mkdir -p "$A"; PC="$A/08-mac3-upstream.pcap"
PROBE="probe-$(date +%s).team1.test"     # a new name every run, so no cache can answer it

{ header "Ext A · 07 do both DNS servers own the zone team1.test? (primary mac1 vs backup mac3)" \
    "Probe name (not in team1.hosts): $PROBE · capture on mac3 en0: DNS to the upstream servers only"
  echo "## Config lines that decide it"
  for h in mac1 mac3; do echo "[$h]\$ grep -nE '^(local|no-hosts|addn-hosts|server|local-ttl|log-)' /opt/homebrew/etc/dnsmasq.conf"
    on $h "grep -nE '^(local|no-hosts|addn-hosts|server|local-ttl|log-)' /opt/homebrew/etc/dnsmasq.conf"; echo; done

  on mac3 "rm -f ~/team1-logs/A-zone.pcap; nohup sudo -n /usr/sbin/tcpdump -i en0 -U -Z \$(whoami) -w ~/team1-logs/A-zone.pcap 'udp port 53 and (host 8.8.8.8 or host 10.5.7.1)' >/dev/null 2>~/team1-logs/tcpdump-Az.err </dev/null &"
  sleep 1.5
  echo "## The same questions to both servers (asked from this Mac)"
  for s in "$DNS1" "$DNS2"; do
    for q in "$PROBE A" "$NAME AAAA"; do
      echo "\$ dig @$s $q"
      dig +nocmd @"$s" $q +time=3 +tries=1 2>&1 | grep -E 'status:|flags:|^;; (AUTHORITY|ANSWER) SECTION|IN[[:space:]]+SOA|Query time' | sed 's/^/   /'
    done
  done
  sleep 1
  on mac3 "sudo -n /usr/bin/pkill -INT -f '^/usr/sbin/tcpdump -i en0 -U -Z [a-z]+ -w /Users/[a-z]+/team1-logs/A-zone.pcap'; sleep 0.7"
  scp -q -o BatchMode=yes mac3:team1-logs/A-zone.pcap "$PC" && on mac3 'rm -f ~/team1-logs/A-zone.pcap'
  echo
  echo "## What mac3 sent to the INTERNET meanwhile (only team1.test names shown; capture ${PC#"$REPO"/})"
  tcpdump -nn -r "$PC" 2>/dev/null | grep -i 'team1\.test' | sed 's/^/   /'
  [ "$(tcpdump -nn -r "$PC" 2>/dev/null | grep -ci 'team1\.test')" = 0 ] && echo "   (none)"
  echo
  echo "Reading: NXDOMAIN / empty answer with NO authority section = dnsmasq answered from its own zone (local=/team1.test/), nothing left the LAN (mac1)."
  echo "Authority = the ROOT zone's SOA (a.root-servers.net) = the question was forwarded to the internet (8.8.8.8, in the capture): internal names leak and the answer is slower (mac3)."
  echo "Fix: add local=/team1.test/ (and no-hosts) to mac3's dnsmasq.conf, as in dns/phase2/dnsmasq.conf."
} 2>&1 | tee "$A/07-zone-config-check.txt"
