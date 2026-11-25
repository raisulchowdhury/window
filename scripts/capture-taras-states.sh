#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
[ "$(uname -s)" = Darwin ] || { echo 'Taras captures require macOS / Xcode.' >&2; exit 2; }
OUT=${1:-docs/taras-look/captures}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/window-taras-captures.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
# Compile the same core and view without the app entry point or any Maps requests.
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "$TMP/module-cache" \
  -target "$(uname -m)-apple-macosx26.0" \
  -emit-library -emit-module -static -module-name WindowCore \
  -emit-module-path "$TMP/WindowCore.swiftmodule" \
  WatchCore.swift EveningCore.swift TarasRulerModel.swift TarasScrubState.swift TarasMotion.swift TarasPanelSnapshot.swift TarasPanelFixtures.swift \
  -o "$TMP/libWindowCore.a"
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "$TMP/module-cache" \
  -target "$(uname -m)-apple-macosx26.0" -I "$TMP" -L "$TMP" -lWindowCore \
  App/TarasMotion+SwiftUI.swift App/TarasPanelView.swift App/TarasRulerInput.swift tests/CaptureTarasStates.swift -o "$TMP/capture"
"$TMP/capture" "$OUT"
