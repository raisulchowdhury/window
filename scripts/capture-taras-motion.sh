#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
[ "$(uname -s)" = Darwin ] || { echo 'Taras motion captures require macOS / Xcode.' >&2; exit 2; }
OUT=${1:-docs/taras-look/captures/motion}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/window-taras-motion.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
# The capture executable renders fixtures only; WindowApp and live services are not linked.
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "$TMP/module-cache" \
  -target "$(uname -m)-apple-macosx26.0" \
  -emit-library -emit-module -static -module-name WindowCore \
  -emit-module-path "$TMP/WindowCore.swiftmodule" \
  WatchCore.swift EveningCore.swift TarasRulerModel.swift TarasScrubState.swift TarasMotion.swift \
  TarasPanelSnapshot.swift TarasPanelFixtures.swift PlanSnapshot.swift PlanWidgetModel.swift PlanWidgetFixtures.swift \
  -o "$TMP/libWindowCore.a"
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "$TMP/module-cache" \
  -target "$(uname -m)-apple-macosx26.0" -I "$TMP" -L "$TMP" -lWindowCore \
  App/TarasMotion+SwiftUI.swift App/TarasPanelView.swift App/TarasRulerInput.swift \
  Widget/TarasWidgetView.swift tests/TarasAnimatedTextTests.swift tests/CaptureTarasMotion.swift -o "$TMP/capture"
"$TMP/capture" "$OUT"
