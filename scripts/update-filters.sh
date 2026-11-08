#!/usr/bin/env bash
# Refreshes the filter lists bundled with Aegis (Sources/ContentBlocking/Resources/lists).
# These are data files shipped inside the app so blocking works before the first
# in-app update. EasyList / EasyPrivacy are dual-licensed GPLv3 / CC BY-SA 3.0
# (see LICENSE-filter-lists.txt in the same folder).
#
# Usage: scripts/update-filters.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/ContentBlocking/Resources/lists"
mkdir -p "$DEST"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() {
  local name="$1" url="$2"
  echo "Fetching $url"
  # --proto =https: never follow a redirect to plain HTTP. No cookies, no extra headers.
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
       --max-time 120 -o "$TMP/$name" "$url"
  # Sanity check: must look like an Adblock Plus list and be reasonably large.
  if ! head -n 1 "$TMP/$name" | grep -q '^\[Adblock Plus'; then
    echo "error: $url does not look like an Adblock Plus filter list" >&2
    exit 1
  fi
  local size
  size=$(wc -c < "$TMP/$name" | tr -d ' ')
  if [ "$size" -lt 100000 ]; then
    echo "error: $url is suspiciously small ($size bytes)" >&2
    exit 1
  fi
  mv "$TMP/$name" "$DEST/$name"
  echo "  -> $DEST/$name ($size bytes, $(wc -l < "$DEST/$name" | tr -d ' ') lines)"
}

fetch easylist.txt    https://easylist.to/easylist/easylist.txt
fetch easyprivacy.txt https://easylist.to/easylist/easyprivacy.txt
echo "Done. Rebuild the app to pick up the new lists."
