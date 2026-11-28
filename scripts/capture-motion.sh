#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
[ "$(uname -s)" = Darwin ] || { echo 'Motion captures require macOS / Xcode.' >&2; exit 2; }
OUT=${1:-docs/panel-look/captures/motion}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/window-motion.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
# The capture executable renders fixtures only; WindowApp and live services are not linked.
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "$TMP/module-cache" \
  -target "$(uname -m)-apple-macosx26.0" \
  -emit-library -emit-module -static -module-name WindowCore \
  -emit-module-path "$TMP/WindowCore.swiftmodule" \
  WatchCore.swift EveningCore.swift RulerModel.swift ScrubState.swift PanelMotion.swift \
  PanelSnapshot.swift PanelFixtures.swift PlanSnapshot.swift PlanWidgetModel.swift PlanWidgetFixtures.swift \
  -o "$TMP/libWindowCore.a"
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "$TMP/module-cache" \
  -target "$(uname -m)-apple-macosx26.0" -I "$TMP" -L "$TMP" -lWindowCore \
  App/PanelMotion+SwiftUI.swift App/PanelView.swift App/RulerInput.swift \
  Widget/WidgetView.swift tests/AnimatedTextTests.swift tests/CapturePanelMotion.swift -o "$TMP/capture"
"$TMP/capture" "$OUT"
