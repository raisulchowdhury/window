#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/window-live.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
swiftc -D WINDOW_PORTABLE_TESTS -parse-as-library -swift-version 5 -module-cache-path "$TMP/module-cache" \
  WatchCore.swift EveningCore.swift tests/PortableRuntime.swift LiveWatch.swift LiveWatchTests.swift \
  PanelMotion.swift RulerModel.swift PanelSnapshot.swift PlanSnapshot.swift PlanWidgetModel.swift LiveState.swift tests/LiveTests.swift -o "$TMP/live"
"$TMP/live"
