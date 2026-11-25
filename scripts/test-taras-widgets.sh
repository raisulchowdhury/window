#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/window-taras-widgets.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
swiftc -parse-as-library -swift-version 6 -module-cache-path "$TMP/module-cache" \
  WatchCore.swift EveningCore.swift TarasRulerModel.swift TarasPanelSnapshot.swift PlanSnapshot.swift PlanWidgetModel.swift PlanWidgetFixtures.swift \
  tests/TarasWidgetTests.swift -o "$TMP/widgets"
"$TMP/widgets"
