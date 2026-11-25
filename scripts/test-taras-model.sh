#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/window-taras-model.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
command -v swiftc >/dev/null 2>&1 || { echo "Swift compiler required." >&2; exit 2; }
swiftc -parse-as-library -swift-version 6 -module-cache-path "$TMP/module-cache" \
  WatchCore.swift EveningCore.swift TarasRulerModel.swift TarasScrubState.swift TarasMotion.swift TarasPanelLifecycle.swift TarasPanelSnapshot.swift TarasPanelFixtures.swift App/TarasPanelPlacement.swift tests/TarasPanelFadeTests.swift tests/TarasMotionTests.swift tests/TarasRulerModelTests.swift -o "$TMP/model"
"$TMP/model"
