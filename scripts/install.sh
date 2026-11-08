#!/bin/zsh
# Rebuilds Aegis and installs it to /Applications (quits a running copy first).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh release
pkill -x Aegis 2>/dev/null || true
ditto build/Aegis.app /Applications/Aegis.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Aegis.app
echo "Installed /Applications/Aegis.app"
