#!/bin/bash
# Extension A: backup DNS. Run on Mac 4. The PRIMARY dnsmasq (mac1, 10.7.17.233) is stopped; a client that lists both
# servers (mac3 here, resolver order 10.7.17.233 then 10.7.3.175) must still resolve the name via the BACKUP (mac3 itself)
# and still reach the app. Then the primary is started again.
#   bash scripts/phase2/A-backup-dns.sh
# dnsmasq is a launchd daemon with KeepAlive (sh.brew.dnsmasq), so it is stopped/started with
#   sudo -n /opt/homebrew/bin/brew services stop|start dnsmasq      (a plain pkill would be restarted by launchd)
# Capture on the client: pktap (en0 + lo0), because mac3 asks ITSELF (the backup) over loopback.
# Evidence: evidence/phase2/A/00-events.txt ... 06-summary.txt + 03 pcap
set -uo pipefail
source "$(dirname "$0")/lib.sh"
SCRIPT_ARGS="$*"
CLIENT=mac3
A="$EVID/A"; mkdir -p "$A"; EV="$A/00-events.txt"; PC="$A/03-mac3-client-dns-icmp.pcap"
ev() { printf '%s  %s\n' "$(now_ms)" "$*" | tee -a "$EV"; }
flush() { on "$1" 'sudo -n /usr/bin/dscacheutil -flushcache && sudo -n /usr/bin/killall -HUP mDNSResponder && echo "cache flushed on $(scutil --get LocalHostName)"'; }
DIGF="grep -E 'status:|^app\.team1\.test\.|SERVER:|Query time|communications error|connection refused|timed out|no servers'"

# timed plain dig + OS resolver + 4 HTTPS requests, as the client sees it
client_view() {  # client_view <ssh alias>
  (CLIENT="$1"; crun 'a=$(perl -MTime::HiRes=time -e "printf q(%.3f), time"); out=$(dig '"$NAME"' 2>&1); b=$(perl -MTime::HiRes=time -e "printf q(%.3f), time")
echo "$out" | '"$DIGF"'; echo "(dig took $(perl -e "printf q(%.2f), $b - $a") s)"')
  (CLIENT="$1"; crun "dscacheutil -q host -a name $NAME | grep ip_address")
  (CLIENT="$1"; crun 'for i in 1 2 3 4; do h=$(curl -s -D - -o /dev/null -w "DNS=%{time_namelookup} TOTAL=%{time_total} IP=%{remote_ip}" https://$NAME/api/status); printf "%s  #%s http=%s ip=%s x-edge=%s x-backend=%s %s\n" "$(tsm)" $i "$(echo "$h" | awk "NR==1{print \$2}")" "$(echo "$h" | sed -n "s/.*IP=//p")" "$(echo "$h" | hv x-edge)" "$(echo "$h" | hv x-backend)" "$(echo "$h" | grep -o "DNS=[0-9.]* TOTAL=[0-9.]*")"; sleep 0.3; done')
}

: > "$EV"
{ header "Ext A · 00 events (this Mac's clock, ms)" "Primary DNS = mac1 10.7.17.233, backup = mac3 10.7.3.175; client = mac3 (+ mac1)"; } | tee -a "$EV"

# ------------------------------------------------------------------ 1. baseline
{ header "Ext A · 01 baseline: both DNS servers up, the client uses the primary"
  echo "## Which DNS servers mac3 asks, in order"; crun "scutil --dns | awk '/^resolver #1/{f=1} f&&/nameserver\\[/{print} f&&/^\$/{exit}'"
  crun "sudo -n /opt/homebrew/bin/brew services list | grep dnsmasq"
  echo "## Both servers answer the same record"
  for s in "$DNS1" "$DNS2"; do crun "dig +nocmd @$s $NAME +noall +answer +stats | grep -E 'IN[[:space:]]+A|SERVER'"; done
  echo "## The client (OS cache flushed first)"; flush mac3; client_view mac3
} 2>&1 | tee "$A/01-baseline.txt"

# ------------------------------------------------------------------ 2. capture on the client
on mac3 "mkdir -p ~/team1-logs; rm -f ~/team1-logs/A-mac3.pcap; nohup sudo -n /usr/sbin/tcpdump -i pktap,en0,lo0 -U -Z \$(whoami) -w ~/team1-logs/A-mac3.pcap 'port 53 or icmp' >/dev/null 2>~/team1-logs/tcpdump-A.err </dev/null &"
sleep 1.5; ev "tcpdump on mac3: \$ sudo -n /usr/sbin/tcpdump -i pktap,en0,lo0 -U -Z <user> -w ~/team1-logs/A-mac3.pcap 'port 53 or icmp'"

# ------------------------------------------------------------------ 3. stop the primary
ev "STOP primary DNS on mac1: \$ sudo -n /opt/homebrew/bin/brew services stop dnsmasq"
on mac1 'sudo -n /opt/homebrew/bin/brew services stop dnsmasq 2>&1 | tail -1; sleep 1; pgrep -lx dnsmasq || echo "no dnsmasq process on mac1"' | sed 's/^/                ↳ /' | tee -a "$EV"
ev "primary from this Mac: $(dig +nocmd @$DNS1 $NAME +time=2 +tries=1 2>&1 | grep -E 'refused|timed out|no servers|IN[[:space:]]+A' | head -1)"

# ------------------------------------------------------------------ 4. the client with the primary down
{ header "Ext A · 02 primary DNS DOWN (dnsmasq stopped on mac1): the client still resolves via the backup" \
    "Stopped at $(awk '/STOP primary/{print $1}' "$EV") (see 00-events.txt)"
  crun "dig +nocmd @$DNS1 $NAME +time=2 +tries=1 2>&1 | grep -vE '^\$|^;; global|^; <<>>'"
  echo "## mac3 (cache flushed): plain dig tries 10.7.17.233 first, gets refused, uses 10.7.3.175"; flush mac3; client_view mac3
  echo "## mac1, the main client, is affected too (it lists itself first): also falls back to the backup"; flush mac1; client_view mac1
} 2>&1 | tee "$A/02-primary-down-client.txt"

# ------------------------------------------------------------------ 5. restore
ev "START primary DNS on mac1: \$ sudo -n /opt/homebrew/bin/brew services start dnsmasq"
on mac1 'sudo -n /opt/homebrew/bin/brew services start dnsmasq 2>&1 | tail -1; for i in $(seq 1 20); do dig +nocmd @127.0.0.1 '"$NAME"' +short +time=1 +tries=1 2>/dev/null | grep -q . && break; sleep 0.3; done; pgrep -lx dnsmasq; sudo -n /opt/homebrew/bin/brew services list | grep dnsmasq' | sed 's/^/                ↳ /' | tee -a "$EV"
{ header "Ext A · 05 primary DNS back: the client uses it again"
  crun "dig +nocmd @$DNS1 $NAME +noall +answer +stats | grep -E 'IN[[:space:]]+A|SERVER'"
  flush mac3; client_view mac3; flush mac1 >/dev/null
} 2>&1 | tee "$A/05-restore.txt"

# ------------------------------------------------------------------ 6. capture
sleep 1
on mac3 "sudo -n /usr/bin/pkill -INT -f '^/usr/sbin/tcpdump -i pktap,en0,lo0 -U -Z [a-z]+ -w /Users/[a-z]+/team1-logs/A-mac3.pcap'; sleep 0.7; grep 'packets captured' ~/team1-logs/tcpdump-A.err" > /dev/null
scp -q -o BatchMode=yes mac3:team1-logs/A-mac3.pcap "$PC" && on mac3 'rm -f ~/team1-logs/A-mac3.pcap'
ev "tcpdump stopped, pcap -> ${PC#"$REPO"/}"
pcap_summary() {  # only packets about OUR name: queries for app.team1.test, the answers to them (same DNS id),
                  # and the ICMP errors caused by them (the ICMP carries the query's UDP source port: tcpdump -v)
  local T; T=$(mktemp -d)
  tcpdump -nn -r "$PC" 'udp port 53' 2>/dev/null | awk -v pf="$T/ports" '
    function ip(x) { sub(/\.[0-9]+:?$/, "", x); return x }
    / (A|AAAA)\? app\.team1\.test\./ { id = $6; sub(/[^0-9].*/, "", id); k = id $3 $5; if (seen[k]++) next
        for (i = 6; i <= NF; i++) if ($i ~ /\?$/) ty = $i; dst = ip($5); p = $3; sub(/.*\./, "", p); print p > pf; q[id] = 1
        up = (dst !~ /^10\.7\./) ? "   <- forwarded UPSTREAM: mac3 has no local=/team1.test/" : ""
        printf "%s  query   %-6s %-11s -> %-11s id %s%s\n", substr($1,1,12), ty, ip($3), dst, id, up; next }
    $3 ~ /\.53$/ { id = $6; sub(/[^0-9].*/, "", id); if (!(id in q)) next; k = id $3 $5; if (seen[k]++) next
        a = ""; for (i = 7; i <= NF && $i !~ /^\(/; i++) a = a " " $i
        printf "%s  answer  from %-11s to %-11s id %s:%s\n", substr($1,1,12), ip($3), ip($5), id, a }' > "$T/dns"
  tcpdump -nn -v -r "$PC" 'icmp' 2>/dev/null | awk -v pf="$T/ports" '
    BEGIN { while ((getline p < pf) > 0) ours[p] = 1 }
    /^[0-9][0-9]:/ { t = substr($1,1,12); next }
    /udp port 53 unreachable/ { from = $1; icmp = 1; next }
    icmp && / > [0-9.]+\.53:/ { p = $1; sub(/.*\./, "", p); if ((p in ours) && !seen[t p]++) printf "%s  ICMP    %-11s says udp port 53 unreachable (query from port %s: nothing listening)\n", t, from, p; icmp = 0 }' > "$T/icmp"
  sort "$T/dns" "$T/icmp" | sed 's/^/  /'
  rm -rf "$T"
}
{ header "Ext A · 04 what mac3's capture shows, ONLY for $NAME: queries, ICMP errors caused by them, answers" \
    "pktap (en0 + lo0); loopback packets appear twice and are deduplicated. Includes mac1's queries to the backup while its own dnsmasq was down."
  pcap_summary
} > "$A/04-pcap-summary.txt" 2>&1

# ------------------------------------------------------------------ 7. summary
{ header "Ext A · 06 summary"
  grep -E 'STOP primary|START primary' "$EV" | sed 's/^/  /'
  echo "## Primary DOWN (02-primary-down-client.txt)"
  grep -E '^;; SERVER:|^;; connection|^\(dig took|^[0-9:.]+  #[0-9] http=|^cache flushed|^## ' "$A/02-primary-down-client.txt" | sed 's/^/  /'
  echo "## Primary back (05-restore.txt)"
  grep -E '^;; SERVER:|^\(dig took' "$A/05-restore.txt" | sed 's/^/  /'
  echo "## On the wire (04-pcap-summary.txt), only packets about $NAME:"
  echo "  $(grep -c ' ICMP ' "$A/04-pcap-summary.txt") ICMP port-unreachable from mac1 for our queries, $(grep -c 'answer  from 10.7.3.175' "$A/04-pcap-summary.txt") answers from the backup," \
       "$(grep -c 'forwarded UPSTREAM' "$A/04-pcap-summary.txt") of our queries forwarded to the internet by mac3"
  echo "## Plain dig: from asking the primary to asking the backup (same DNS id)"
  awk '$2 == "query" && $3 == "A?" && $4 == "10.7.3.175" && $6 == "10.7.17.233" { first[$8] = $1 } $2 == "query" && $4 == "10.7.3.175" && $6 == "10.7.3.175" && ($8 in first) && !done[$8]++ {
         split(first[$8], a, ":"); split($1, b, ":"); printf "  id %s: primary at %s, backup at %s = %.2f s later\n", $8, first[$8], $1, (b[1]*3600+b[2]*60+b[3]) - (a[1]*3600+a[2]*60+a[3]) }' \
      <(sed 's/^  //' "$A/04-pcap-summary.txt")
} 2>&1 | tee "$A/06-summary.txt"
echo "(evidence in $A/)"
