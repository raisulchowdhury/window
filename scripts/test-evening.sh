#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
MODE=${1:---portable}
case "$MODE" in --core|--portable|--native) ;; *) echo 'Usage: sh scripts/test-evening.sh [--core|--portable|--native]' >&2; exit 2 ;; esac
TMP=$(mktemp -d "${TMPDIR:-/tmp}/window-evening.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
command -v swiftc >/dev/null 2>&1 || { echo 'Swift compiler required.' >&2; exit 2; }
swiftc -parse-as-library -swift-version 5 WatchCore.swift EveningCore.swift tests/EveningCoreTests.swift -o "$TMP/core"
"$TMP/core"
[ "$MODE" != --core ] || exit 0
if [ "$MODE" = --native ]; then
  [ "$(uname -s)" = Darwin ] || { echo 'Native controller checks require macOS 26 / Xcode 26. NOT RUN.' >&2; exit 2; }
  xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx26.0" \
    WatchCore.swift EveningCore.swift LiveWatch.swift LiveServices.swift tests/EveningLiveTests.swift \
    -framework AppKit -framework Combine -framework Network -framework MapKit -framework UserNotifications -o "$TMP/live"
  "$TMP/live"
else
  swiftc -D WINDOW_PORTABLE_TESTS -parse-as-library -swift-version 5 \
    WatchCore.swift EveningCore.swift tests/PortableRuntime.swift LiveWatch.swift tests/EveningLiveTests.swift -o "$TMP/live"
  "$TMP/live"
  cat > "$TMP/main.swift" <<'SWIFT'
@main struct LegacyLiveRunner { @MainActor static func main() async { await runLiveWatchTests() } }
SWIFT
  swiftc -D WINDOW_PORTABLE_TESTS -parse-as-library -swift-version 5 \
    WatchCore.swift EveningCore.swift tests/PortableRuntime.swift LiveWatch.swift LiveWatchTests.swift "$TMP/main.swift" -o "$TMP/legacy"
  "$TMP/legacy"
  swiftc -D WINDOW_PORTABLE_TESTS -parse-as-library -swift-version 5 \
    WatchCore.swift EveningCore.swift tests/PortableRuntime.swift LiveWatch.swift tests/CraftLiveTests.swift -o "$TMP/craft"
  "$TMP/craft"
  echo 'Portable checks use observation/protocol shims. No AppKit, SwiftUI, Maps, OS notifications, or physical lifecycle tested.'
fi
sh scripts/test-monitoring-copy.sh "$MODE"
sh scripts/test-micro-interactions.sh "$MODE"
