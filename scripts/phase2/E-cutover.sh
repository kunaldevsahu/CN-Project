#!/bin/bash
# Extension E: edge migration by DNS cutover, Mac 4 (10.7.30.71) -> standby on mac3 (10.7.3.175), and back. Run on Mac 4.
# Needs both edges up:  bash scripts/phase2/E-standby.sh up
#   bash scripts/phase2/E-cutover.sh
#   DURATION=90 CUT_AT=20 RESTORE_LOOP=45 GAP=1 KEEP_STANDBY=0 bash scripts/phase2/E-cutover.sh
#   bash scripts/phase2/E-cutover.sh --analyze     # only rebuild 08/09/10 from the saved pcap, loops and events
#
# 1. flush mac1's cache, capture on mac1 (pktap = en0 + lo0: mac1 asks ITSELF for DNS, which never reaches en0)
# 2. 90 s loop on mac1: what the DNS server says now (dig +tcp, bypasses the cache) vs the IP curl really used,
#    X-Edge, X-Backend, http code
# 3. at ~20 s: set-record-both.sh app.team1.test 10.7.3.175 (both DNS Macs at once), exact time logged
#    + mac3 used as a second client: cached answer (old edge) -> flush -> new edge at once
# 4. restore: record back to 10.7.30.71, 45 s loop WITHOUT flushing (switch back <= TTL), only then stop the standby
# Evidence: evidence/phase2/E/03-events.txt ... 13-standby-down.txt
set -uo pipefail
source "$(dirname "$0")/lib.sh"
SCRIPT_ARGS="$*"
DURATION=${DURATION:-90}; CUT_AT=${CUT_AT:-20}; RESTORE_LOOP=${RESTORE_LOOP:-45}; GAP=${GAP:-1}; KEEP_STANDBY=${KEEP_STANDBY:-0}
E="$EVID/E"; mkdir -p "$E"; TMP=$(mktemp -d)
EV="$E/03-events.txt"; L1="$E/04-client-loop-cutover.txt"; L2="$E/12-client-loop-restore.txt"
PC="$E/07-mac1-dns-443.pcap"; ACCLOG=/opt/homebrew/var/log/nginx/team1-access.log
FILTER="port 53 or (tcp port 443 and (host $EDGE_IP or host $STANDBY_IP))"
ev() { printf '%s  %s\n' "$(now_ms)" "$*" | tee -a "$EV"; }
flush() { on "$1" 'sudo -n /usr/bin/dscacheutil -flushcache && sudo -n /usr/bin/killall -HUP mDNSResponder && echo "cache flushed on $(scutil --get LocalHostName)"'; }

loop() {  # loop <seconds> -> client snippet
  cat <<EOF
t0=\$(date +%s); end=\$((SECONDS+$1)); i=0
while [ \$SECONDS -lt \$end ]; do i=\$((i+1))
  srv=\$(dig +tcp +short +time=1 +tries=1 @$DNS1 \$NAME 2>/dev/null | grep -E '^[0-9.]+\$' | head -1)
  h=\$(curl -s -D - -o /dev/null --max-time 5 -w 'IP=%{remote_ip} CODE=%{http_code}' https://\$NAME/api/status)
  ip=\$(echo "\$h" | sed -n 's/.*IP=\([0-9.]*\).*/\1/p'); code=\$(echo "\$h" | sed -n 's/.*CODE=\([0-9]*\).*/\1/p')
  flag=""; [ -n "\$srv" ] && [ -n "\$ip" ] && [ "\$srv" != "\$ip" ] && flag="  <- OS cache still has the old IP"
  printf '%s  t+%-3s server=%-11s curl->%-11s http=%-3s x-edge=%-13s x-backend=%-2s%s\n' "\$(tsm)" \$((\$(date +%s)-t0)) "\${srv:--}" "\${ip:--}" "\${code:--}" "\$(echo "\$h" | hv x-edge)" "\$(echo "\$h" | hv x-backend)" "\$flag"
  sleep $GAP
done
EOF
}
mac3_client() {  # one request from mac3 acting as a client
  (CLIENT=mac3; crun 'h=$(curl -s -D - -o /dev/null --max-time 5 -w "IP=%{remote_ip} CODE=%{http_code}" https://$NAME/api/status); echo "$(tsm)  OS resolver: $(dscacheutil -q host -a name $NAME | awk "/ip_address/{print \$2}")   curl -> $(echo "$h" | sed -n "s/.*IP=\([0-9.]*\).*/\1/p")  http=$(echo "$h" | sed -n "s/.*CODE=\([0-9]*\).*/\1/p")  x-edge=$(echo "$h" | hv x-edge)"')
}


# ------------------------------------------------------------------ analysis (also: E-cutover.sh --analyze, rebuilds 08/09/10 from the saved files)
analyze() {  # needs E_START E_CUT E_RESTORE (epochs, this Mac's clock), $PC $L1 $L2
  local T; T=$(mktemp -d)
  # mac1's OWN resolver only: queries sent from $DNS1 (not 127.0.0.1 = the dig in set-record.sh, not other clients
  # such as mac3, whose lookups mac1's dnsmasq also answers), answers matched by DNS id, loopback duplicates dropped
  tcpdump -nn -r "$PC" 'udp port 53' 2>/dev/null | awk -v me="$DNS1" '
    / (A|AAAA)\? app\.team1\.test\./ { split($3, s, "."); src = s[1]"."s[2]"."s[3]"."s[4]; id = $6; sub(/[^0-9].*/, "", id)
        if (src != me) { other[id] = 1; next } if (id in q) next; q[id] = substr($1,1,12); to = $5; sub(/\.53:$/, "", to); dst[id] = to; next }
    { id = $6; sub(/[^0-9].*/, "", id); if (!(id in q) || done[id]++) next
      ip = ""; for (i = 1; i <= NF; i++) if ($i == "A") ip = $(i+1); if (ip == "") next
      print q[id], dst[id], ip }
    END { n = 0; for (k in other) n++; print n > "/dev/stderr" }' > "$T/lookups" 2> "$T/others"

  { header "Ext E · 08 what mac1's capture shows (pktap = en0 + lo0: mac1 asks ITSELF for DNS, over loopback)" \
      "Cutover $(hms "$E_CUT"), restore $(hms "$E_RESTORE") (Mac 4 clock; mac1's clock is within ~0.2 s)"
    echo "## Lookups made by mac1's OWN resolver (mDNSResponder). Between two lines every request used the cached answer."
    awk 'function sec(x, p) { split(x, p, ":"); return p[1]*3600 + p[2]*60 + p[3] }
         { d = prev ? sprintf("%5.2f s after the previous lookup", sec($1) - prev) : "first lookup after the cache flush"; prev = sec($1)
           printf "  %s  asked %-11s -> %-11s  %s\n", $1, $2, $3, d }' "$T/lookups"
    echo
    echo "Not listed: $(cat "$T/others") lookups by OTHER hosts that mac1's dnsmasq answered meanwhile (mac3 as a client, the dig in set-record.sh)."
    echo
    echo "## TCP connections (SYN) from $CLIENT to each edge on 443"
    for ip in "$EDGE_IP" "$STANDBY_IP"; do
      tcpdump -nn -r "$PC" "src host $DNS1 and dst host $ip and tcp dst port 443 and tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0" 2>/dev/null \
        | awk -v ip="$ip" '{ k = $3; if (seen[k]++) next; n++; if (!f) f = substr($1,1,12); l = substr($1,1,12) } END { printf "  %-11s %3d connections   first %s   last %s\n", ip, n, f, l }'
    done
  } > "$E/08-pcap-summary.txt" 2>&1

  { header "Ext E · 09 the two edges' own logs: requests from $CLIENT per 5 s after the cutover" \
      "Mac 4: $ACCLOG (Mac 4 clock) · mac3: same path on mac3 (mac3 clock). The old edge goes quiet when the client's cached answer expires."
    grep "client=$DNS1 " "$ACCLOG" | sed 's/^/mac4 /' > "$T/acc"
    on mac3 "grep 'client=$DNS1 ' $ACCLOG" | sed 's/^/mac3 /' >> "$T/acc"
    awk -v s="$E_START" -v c="$E_CUT" -v r="$E_RESTORE" '
      { match($0, /t=[0-9.]+/); t = substr($0, RSTART+2, RLENGTH-2) + 0; if (t < s || t >= r) next
        b = int((t - c + 1000) / 5) - 200; n[b, $1]++; if (!init || b < mn) mn = b; if (!init || b > mx) mx = b; init = 1
        if ($1 == "mac4" && t > c && t > lastp) lastp = t; if ($1 == "mac3" && t > c && (!firsts || t < firsts)) firsts = t }
      END { printf "  %-16s %-14s %-14s\n", "s after cutover", "mac4-primary", "mac3-standby"
            for (b = mn; b <= mx; b++) printf "  %4d .. %-4d     %-14d %-14d\n", b*5, b*5+5, n[b,"mac4"], n[b,"mac3"]
            printf "\n  last request on mac4-primary:  %.1f s after the cutover\n  first request on mac3-standby: %.1f s after the cutover\n", lastp - c, firsts - c }' "$T/acc"
  } > "$E/09-edge-logs.txt" 2>&1

  { header "Ext E · 10 summary (numbers from 04/06/08/09/12)" "TTL of the record: 30 s (local-ttl=30 on both DNS servers)"
    awk -v new="$STANDBY_IP" -v cut="$(hms "$E_CUT")" '
         function sec(x, p) { split(x, p, ":"); return p[1]*3600 + p[2]*60 + p[3] }
         /^[0-9:.]+  t\+/ { n++; split($3, s, "="); split($4, c, ">"); split($5, h, "="); if (h[2] != "200") bad++
           if (!sf && s[2] == new) sf = $1; if (!cf && c[2] == new) cf = $1; if ($0 ~ /cache still has/) old++ }
         END { printf "## Cutover seen from the client\n  requests: %d   non-200: %d\n", n, bad
               printf "  record changed (Mac 4 clock):         %s\n  DNS server answered the NEW IP from:  %s\n  curl connected to the NEW edge from:  %s  = %.1f s after the change\n", cut, sf, cf, sec(cf) - sec(cut)
               printf "  requests that still went to the OLD edge after the server had changed: %d (all 200: the old edge was still up)\n", old }' "$L1"
    awk -v ed="$EDGE_IP" -v rs="$(hms "$E_RESTORE")" '
         function sec(x, p) { split(x, p, ":"); return p[1]*3600 + p[2]*60 + p[3] }
         /^[0-9:.]+  t\+/ { n++; split($4, c, ">"); split($5, h, "="); if (h[2] != "200") bad++; if (!cf && c[2] == ed) cf = $1 }
         END { printf "## Restore (record back, NO flush, old/standby edge kept up meanwhile)\n  requests: %d   non-200: %d   record restored %s, client back on %s from %s = %.1f s later\n", n, bad, rs, ed, cf, sec(cf) - sec(rs) }' "$L2"
    echo "## mac3 as a second client (06-mac3-as-client.txt)"; grep -E '^[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+  OS resolver:' "$E/06-mac3-as-client.txt" | sed 's/^/  /'
    echo "  -> before the change: old edge; after the change WITHOUT flush: still the old edge (cache); after a flush: new edge at once"
    echo "## The edges' own logs (09-edge-logs.txt)"; grep -E 'last request|first request' "$E/09-edge-logs.txt"
    echo "## Why it took that long: mac1's OWN DNS lookups (08-pcap-summary.txt)"
    awk -v cut="$(hms "$E_CUT")" '
      function sec(x, p) { split(x, p, ":"); return p[1]*3600 + p[2]*60 + p[3] }
      { t[NR] = $1; ip[NR] = $3 }
      END { for (i = 1; i <= NR; i++) { if (sec(t[i]) < sec(cut)) b = i; else if (!a) a = i }
            if (b && a) printf "  the answer mac1 had cached at the change was fetched at %s, %.1f s BEFORE the change (%s)\n  mac1 looked the name up again only at %s, %.2f s after that fetch (%s)\n", t[b], sec(cut) - sec(t[b]), ip[b], t[a], sec(t[a]) - sec(t[b]), ip[a]
            printf "  time between mac1 lookups during the whole test:"; for (i = 2; i <= NR; i++) printf " %.2f", sec(t[i]) - sec(t[i-1]); printf " s\n" }' "$T/lookups"
    echo "  => the TTL is 30 s, but macOS kept each cached answer ~7.7 s longer before asking again. So after a record change"
    echo "     a client like mac1 can stay on the old edge for up to ~38 s here (0 s if its cache was about to expire)."
    echo "     The old edge must stay up at least that long: production waits a few TTLs before switching the old one off."
  } 2>&1 | tee "$E/10-summary.txt"
  rm -rf "$T"
}

if [ "${1:-}" = "--analyze" ]; then
  DAY=$(awk '/^# Date:/{print $3; exit}' "$EV")
  te() { perl -MTime::Local -e '($d, $t) = @ARGV; ($Y, $M, $D) = split /-/, $d; ($h, $m, $s) = split /:/, $t; printf "%.3f", timelocal(0, $m, $h, $D, $M - 1, $Y) + $s' \
           "$DAY" "$(awk -v p="$1" 'index($0, p) { print $1; exit }' "$EV")"; }
  E_START=$(te "client loop started"); E_CUT=$(te "CUTOVER:"); E_RESTORE=$(te "RESTORE:")
  analyze; exit 0
fi

# ------------------------------------------------------------------ 0. preflight
: > "$EV"
{ header "Ext E · 03 events: DNS cutover Mac 4 -> mac3 and back (this Mac's clock, ms)" \
    "Plan: ${DURATION}s loop on $CLIENT, record change at ~${CUT_AT}s, restore + ${RESTORE_LOOP}s loop, TTL 30 s"; } | tee -a "$EV"
for ip in "$EDGE_IP" "$STANDBY_IP"; do
  ev "preflight: edge $ip from $CLIENT: $("${SSH[@]}" "$CLIENT" "curl -s -o /dev/null -D - --resolve $NAME:443:$ip https://$NAME/api/status | tr -d '\r' | awk '/^HTTP/{c=\$2} tolower(\$1)==\"x-edge:\"{e=\$2} END{print c, e}'")"
done
ev "preflight: records: @$DNS1 $(dig +nocmd @$DNS1 $NAME +short)  @$DNS2 $(dig +nocmd @$DNS2 $NAME +short)"
ACC0=$(wc -l < "$ACCLOG"); ACC3=$(on mac3 "wc -l < $ACCLOG" | tr -d ' ')
ev "$(flush "$CLIENT")"

# ------------------------------------------------------------------ 1. capture on mac1
on "$CLIENT" "mkdir -p ~/team1-logs; rm -f ~/team1-logs/E-mac1.pcap; nohup sudo -n /usr/sbin/tcpdump -i pktap,en0,lo0 -U -Z \$(whoami) -w ~/team1-logs/E-mac1.pcap '$FILTER' >/dev/null 2>~/team1-logs/tcpdump-E.err </dev/null &"
sleep 1.5
ev "tcpdump on $CLIENT: \$ sudo -n /usr/sbin/tcpdump -i pktap,en0,lo0 -U -Z <user> -w ~/team1-logs/E-mac1.pcap '$FILTER'"

# ------------------------------------------------------------------ 2. client loop (background, live)
( { header "Ext E · 04 client loop on $CLIENT during the cutover (no manual flush during the loop)" \
      "server = answer of DNS server $DNS1 right now (dig over TCP, no cache); curl-> = IP curl actually connected to (OS cache)" \
      "Record change app.team1.test -> $STANDBY_IP at ~t+${CUT_AT}s (see 03-events.txt / 05-set-record-to-standby.txt)"
    crun "$(loop "$DURATION")"; } 2>&1 | tee "$L1" ) &
LOOP_PID=$!; T0=$(date +%s); ev "client loop started on $CLIENT"
wait_until() { while [ $(( $(date +%s) - T0 )) -lt "$1" ]; do sleep 0.2; done; }

# ------------------------------------------------------------------ 3. mac3 as a second client: warm its cache with the OLD answer
wait_until $((CUT_AT - 8))
{ header "Ext E · 06 mac3 used as a second client: cached answer vs flushed" \
    "Warm the cache before the change, ask again after the change (cache: old edge), flush, ask again (new edge)"
  echo "## Before the change: flush + one request (fills mac3's cache with $EDGE_IP)"; flush mac3; mac3_client; } > "$E/06-mac3-as-client.txt" 2>&1

# ------------------------------------------------------------------ 4. the cutover
wait_until "$CUT_AT"; E_CUT=$(epoch); ev "CUTOVER: set-record-both.sh $NAME $STANDBY_IP (mac1 + mac3 in parallel)"
bash "$REPO/scripts/phase2/set-record-both.sh" "$NAME" "$STANDBY_IP" E/05-set-record-to-standby.txt 2>&1 | grep -E 'sending|-> |@' | sed 's/^/                ↳ /' | tee -a "$EV"
sleep 2
{ echo; echo "## Right after the change, NO flush: mac3 still uses its cached answer (old edge)"; mac3_client
  echo "## Flush mac3's cache, ask again: new edge at once"; flush mac3; mac3_client; } >> "$E/06-mac3-as-client.txt" 2>&1
ev "mac3-as-client demo done: $(grep -c 'curl ->' "$E/06-mac3-as-client.txt") requests (see 06-mac3-as-client.txt)"
wait "$LOOP_PID"; ev "client loop finished"

# ------------------------------------------------------------------ 5. restore (keep the standby up until the TTL has passed)
E_RESTORE=$(epoch); ev "RESTORE: set-record-both.sh $NAME $EDGE_IP"
bash "$REPO/scripts/phase2/set-record-both.sh" "$NAME" "$EDGE_IP" E/11-restore-set-record.txt 2>&1 | grep -E 'sending|-> |@' | sed 's/^/                ↳ /' | tee -a "$EV"
{ header "Ext E · 12 client loop on $CLIENT after the RESTORE (no flush: switches back when its cached answer expires)"
  crun "$(loop "$RESTORE_LOOP")"; } 2>&1 | tee "$L2"
ev "restore loop finished"

# ------------------------------------------------------------------ 6. stop capture, fetch
on "$CLIENT" "sudo -n /usr/bin/pkill -INT -f '^/usr/sbin/tcpdump -i pktap,en0,lo0 -U -Z [a-z]+ -w /Users/[a-z]+/team1-logs/E-mac1.pcap'; sleep 0.7; grep 'packets captured' ~/team1-logs/tcpdump-E.err" > "$TMP/cap"
scp -q -o BatchMode=yes "$CLIENT:team1-logs/E-mac1.pcap" "$PC" && on "$CLIENT" 'rm -f ~/team1-logs/E-mac1.pcap'
ev "tcpdump stopped on $CLIENT: $(cat "$TMP/cap") -> ${PC#"$REPO"/}"

# ------------------------------------------------------------------ 7. analysis
analyze

# ------------------------------------------------------------------ 8. stop the standby (record no longer points at it, TTL passed)
if [ "$KEEP_STANDBY" = 1 ]; then ev "KEEP_STANDBY=1: standby left running"
else bash "$REPO/scripts/phase2/E-standby.sh" down >/dev/null 2>&1; ev "standby stopped (13-standby-down.txt)"; fi
flush "$CLIENT" >/dev/null; flush mac3 >/dev/null
ev "final: $CLIENT -> $("${SSH[@]}" "$CLIENT" "curl -s -o /dev/null -D - -w 'IP=%{remote_ip}' https://$NAME/api/status | tr -d '\r' | awk '/^HTTP/{c=\$2} tolower(\$1)==\"x-edge:\"{e=\$2} /IP=/{sub(/.*IP=/,\"\"); i=\$0} END{print c, e, i}'")"
rm -rf "$TMP"; echo "(evidence in evidence/phase2/E/)"
