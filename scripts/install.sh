#!/bin/zsh
# Rebuilds Vane (real identity) and installs it to /Applications.
# Never quits a running copy: the new version takes effect on next launch.
set -euo pipefail
cd "$(dirname "$0")/.."
AEGIS_RELEASE=1 scripts/bundle.sh release
ditto build/Vane.app /Applications/Vane.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Vane.app
if pgrep -f "/Applications/Vane.app/Contents/MacOS/Aegis" >/dev/null; then
  echo "Installed /Applications/Vane.app — quit and reopen Vane to use the new version"
else
  echo "Installed /Applications/Vane.app"
fi
# Leave a dev build in build/ for test runs (its own bundle ID and data folder).
scripts/bundle.sh release >/dev/null
