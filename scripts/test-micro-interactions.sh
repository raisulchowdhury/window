#!/bin/sh
# Actual controller/policy tests with fake services; no UI or real notifications.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
MODE=${1:---portable}
case "$MODE" in --portable|--native) ;; *) echo 'Usage: sh scripts/test-micro-interactions.sh [--portable|--native]' >&2; exit 2 ;; esac
TMP=$(mktemp -d "${TMPDIR:-/tmp}/window-micro.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
if [ "$MODE" = --native ]; then
  [ "$(uname -s)" = Darwin ] || { echo 'Native interaction tests require macOS 26 / Xcode 26. NOT RUN.' >&2; exit 2; }
  xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx26.0" \
    WatchCore.swift EveningCore.swift LiveWatch.swift LiveServices.swift tests/MicroInteractionTests.swift \
    -framework AppKit -framework Combine -framework Network -framework MapKit -framework UserNotifications -o "$TMP/checks"
else
  swiftc -D WINDOW_PORTABLE_TESTS -parse-as-library -swift-version 5 \
    WatchCore.swift EveningCore.swift tests/PortableRuntime.swift LiveWatch.swift tests/MicroInteractionTests.swift -o "$TMP/checks"
fi
"$TMP/checks"
python3 scripts/check-interactions.py
