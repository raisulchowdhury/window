#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
MODE=${1:---core}
case "$MODE" in
  --core|--native) ;;
  *) echo "Usage: sh scripts/test-craft.sh [--core|--native]" >&2; exit 2 ;;
esac
TMP=$(mktemp -d "${TMPDIR:-/tmp}/window-craft.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
if [ "$MODE" = --core ]; then
  command -v swiftc >/dev/null 2>&1 || { echo "Swift compiler required." >&2; exit 2; }
  swiftc -parse-as-library -swift-version 5 WatchCore.swift EveningCore.swift WatchCoreTests.swift tests/CraftCoreTests.swift -o "$TMP/core"
  "$TMP/core"
else
  [ "$(uname -s)" = Darwin ] || { echo "Native controller tests require macOS 26 and Xcode 26; not run." >&2; exit 2; }
  command -v xcrun >/dev/null 2>&1 || { echo "Xcode command-line tools required." >&2; exit 2; }
  xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx26.0" \
    WatchCore.swift EveningCore.swift LiveServices.swift LiveWatch.swift tests/CraftLiveTests.swift \
    -framework AppKit -framework MapKit -framework UserNotifications -framework Combine -framework Network \
    -o "$TMP/native"
  "$TMP/native"
fi
