#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/window-model.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
command -v swiftc >/dev/null 2>&1 || { echo "Swift compiler required." >&2; exit 2; }
swiftc -parse-as-library -swift-version 6 -module-cache-path "$TMP/module-cache" \
  WatchCore.swift EveningCore.swift RulerModel.swift ScrubState.swift PanelMotion.swift PanelLifecycle.swift PanelSnapshot.swift PanelFixtures.swift App/PanelPlacement.swift tests/PanelFadeTests.swift tests/PanelMotionTests.swift tests/RulerModelTests.swift -o "$TMP/model"
"$TMP/model"
