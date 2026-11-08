#!/bin/bash
# Compares Aegis with a Chromium browser (Microsoft Edge, throwaway profile)
# on the same five sites: time to first window, and total memory of every
# process the browser uses (app + renderers/WebContent + GPU + network).
# Usage: scripts/bench-compare.sh [settle_seconds=25]
set -uo pipefail
cd "$(dirname "$0")/.."
SETTLE=${1:-25}
URLS=("https://www.theverge.com" "https://en.wikipedia.org/wiki/Web_browser" "https://github.com/trending" "https://www.youtube.com" "https://news.ycombinator.com")
SCRATCH=$(mktemp -d)
WINID="$SCRATCH/winid"
cat > "$SCRATCH/winid.swift" <<'EOF'
import CoreGraphics
let owner = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
print(list.contains { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 } ? "yes" : "no")
EOF
swiftc -O "$SCRATCH/winid.swift" -o "$WINID" 2>/dev/null

mb() { footprint -p "$1" 2>/dev/null | awk '/phys_footprint:/{v=$2;u=$3;if(u~/G/)v*=1024;if(u~/K/)v/=1024;print int(v);exit}'; }
sum_pids() { local t=0; for p in "$@"; do m=$(mb "$p"); t=$((t + ${m:-0})); done; echo $t; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
wait_window() { local owner=$1 start=$2; for _ in $(seq 1 200); do [ "$("$WINID" "$owner")" = yes ] && { echo $(( $(now_ms) - start )); return; }; sleep 0.05; done; echo "timeout"; }

run_edge() {
  local profile="$SCRATCH/edge-profile"
  local start=$(now_ms)
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" --user-data-dir="$profile" --no-first-run --no-default-browser-check \
     --disable-features=msEdgeSidebarV2 "${URLS[@]}" >/dev/null 2>&1 &
  local launch=$(wait_window "Microsoft Edge" "$start")
  sleep "$SETTLE"
  local pids=$(pgrep -f -- "--user-data-dir=$profile"; pgrep -f "Microsoft Edge.app/Contents/MacOS/Microsoft Edge --user-data-dir=$profile")
  pids=$(echo "$pids" | sort -u)
  local total=$(sum_pids $pids)
  echo "edge launch_ms=$launch total_mb=$total procs=$(echo $pids | wc -w | tr -d ' ')"
  kill $pids 2>/dev/null; sleep 3; kill -9 $pids 2>/dev/null; rm -rf "$profile"
}

run_aegis() {
  pkill -x Aegis 2>/dev/null; sleep 1
  local before=$(pgrep -f "com.apple.WebKit" | sort)
  local start=$(now_ms)
  ./build/Aegis.app/Contents/MacOS/Aegis --snapshot "$SCRATCH/a.png" --open "${URLS[@]}" --delay $((SETTLE + 5)) >/dev/null 2>&1 &
  local launch=$(wait_window "Aegis" "$start")
  sleep "$SETTLE"
  local app=$(pgrep -x Aegis | head -1)
  local kids=$(comm -13 <(echo "$before") <(pgrep -f "com.apple.WebKit" | sort))
  local total=$(sum_pids $app $kids)
  echo "aegis launch_ms=$launch total_mb=$total app_mb=$(mb $app) procs=$(( $(echo $kids | wc -w) + 1 ))"
  pkill -x Aegis; sleep 2
}

echo "Settle: ${SETTLE}s, sites: ${#URLS[@]}"
for round in 1 2; do
  echo "--- round $round"
  run_aegis
  run_edge
done
rm -rf "$SCRATCH"
