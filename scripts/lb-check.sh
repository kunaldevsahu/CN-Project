#!/bin/bash
# Extension D: send N requests and show who served each one, whether nginx had to retry, and how long it took.
#   bash lb-check.sh            # 8 requests, 0.5 s apart
#   bash lb-check.sh 20 1       # 20 requests, 1 s apart (leave running while you stop/start Backend A)
N="${1:-8}"; GAP="${2:-0.5}"; URL="https://${HOST:-app.team1.test}/api/status"
printf "%-3s %-8s %-5s %-8s %-36s %-12s %s\n" "#" time code backend x-upstream x-up-status total
for i in $(seq 1 "$N"); do
  out=$(curl -s -D - -o /dev/null --max-time 10 -w 'TOTAL=%{time_total}' "$URL")
  g() { echo "$out" | awk -F': ' -v k="$1" 'tolower($1)==k{gsub("\r","",$2);print $2}'; }
  code=$(echo "$out" | awk 'NR==1{print $2}')
  t=$(echo "$out" | sed -n 's/.*TOTAL=//p')
  printf "%-3s %-8s %-5s %-8s %-36s %-12s %ss\n" "$i" "$(date +%H:%M:%S)" "${code:--}" "$(g x-backend)" "$(g x-upstream)" "$(g x-upstream-status)" "$t"
  sleep "$GAP"
done
