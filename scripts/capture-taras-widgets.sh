#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
[ "$(uname -s)" = Darwin ] || { echo 'Widget captures require macOS / Xcode.' >&2; exit 2; }
OUT=${1:-docs/taras-look/captures}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/window-taras-widget-captures.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "$TMP/module-cache" \
  -target "$(uname -m)-apple-macosx26.0" \
  -emit-library -emit-module -static -module-name WindowCore \
  -emit-module-path "$TMP/WindowCore.swiftmodule" \
  WatchCore.swift EveningCore.swift TarasRulerModel.swift TarasPanelSnapshot.swift PlanSnapshot.swift PlanWidgetModel.swift PlanWidgetFixtures.swift \
  -o "$TMP/libWindowCore.a"
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "$TMP/module-cache" \
  -target "$(uname -m)-apple-macosx26.0" -I "$TMP" -L "$TMP" -lWindowCore \
  Widget/TarasWidgetView.swift tests/CaptureTarasWidgets.swift -o "$TMP/capture"
"$TMP/capture" "$OUT"
printf 'Long route and 147-minute countdown: %s/widget-{small,medium}-long-route-countdown.png\n' "$OUT"
