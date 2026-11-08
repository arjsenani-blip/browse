#!/bin/zsh
# Launches build/Aegis.app, waits for it to settle, and reports the physical
# footprint of the app process and of its WebKit child processes.
# Usage: scripts/bench-memory.sh [seconds=10]
set -euo pipefail
cd "$(dirname "$0")/.."
WAIT=${1:-10}
BUDGET_MB=150

pkill -x Aegis 2>/dev/null || true
open -n build/Aegis.app
sleep "$WAIT"
PID=$(pgrep -x Aegis | head -1)
[ -z "$PID" ] && { echo "Aegis is not running"; exit 1; }

mb() { footprint -p "$1" 2>/dev/null | awk '/phys_footprint:/ {v=$2; u=$3; if (u ~ /G/) v*=1024; if (u ~ /K/) v/=1024; printf "%.1f", v; exit}'; }
APP_MB=$(mb "$PID")
echo "Aegis app process (pid $PID): ${APP_MB} MB"

TOTAL=0
for child in $(pgrep -f "com.apple.WebKit" || true); do
  # Only WebKit processes serving Aegis (their responsible pid is Aegis).
  if [ "$(launchctl procinfo "$child" 2>/dev/null | awk '/responsible pid/ {print $NF; exit}')" = "$PID" ]; then
    C=$(mb "$child"); NAME=$(ps -o comm= -p "$child" | xargs basename)
    echo "  $NAME (pid $child): ${C} MB"
    TOTAL=$(echo "$TOTAL + ${C:-0}" | bc)
  fi
done
echo "WebKit children total: ${TOTAL} MB"

if (( $(echo "$APP_MB > $BUDGET_MB" | bc) )); then
  echo "FAIL: app process over ${BUDGET_MB} MB budget"; exit 2
fi
echo "PASS: app process under ${BUDGET_MB} MB"
