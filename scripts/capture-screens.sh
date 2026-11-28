#!/bin/sh
# Captures the deeper windows as the shipped app draws them (WINDOW_NATIVE),
# with an isolated fixture watch. Never touches your real journey or Maps.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
[ "$(uname -s)" = Darwin ] || { echo 'Deeper-screen captures require macOS 26 / Xcode 26. NOT RUN.' >&2; exit 2; }
OUT=${1:-build/screens}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/window-screens.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library -swift-version 5 -D WINDOW_NATIVE -module-cache-path "$TMP/module-cache" \
  -target "$(uname -m)-apple-macosx26.0" \
  WatchCore.swift ScrubState.swift PanelMotion.swift PanelLifecycle.swift RulerModel.swift \
  PanelSnapshot.swift PanelFixtures.swift PlanSnapshot.swift PlanWidgetModel.swift PlanWidgetFixtures.swift \
  EveningCore.swift LiveWatch.swift LiveServices.swift LiveState.swift LiveController.swift \
  LiveWindowView.swift WindowPrototype.swift TimeInteractions.swift WindowPresentation.swift \
  LiveWatchTests.swift tests/CaptureScreens.swift \
  -framework Cocoa -framework SwiftUI -framework MapKit -framework UserNotifications \
  -o "$TMP/capture"
"$TMP/capture" "$OUT"
