#!/bin/sh
# Run Window's portable (Foundation-only) suites on Linux or any machine with Docker.
# These cover the departure policy, ruler, widget model and live controller logic.
# They do not compile AppKit/SwiftUI or test rendering, notifications or the widget on a desktop.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IMAGE=${SWIFT_IMAGE:-mirror.gcr.io/library/swift:6.1}
docker run --rm -v "$ROOT":/src -w /src "$IMAGE" sh -c '
set -e
sh scripts/test-taras-model.sh
sh scripts/test-taras-widgets.sh
sh scripts/test-taras-live.sh
sh scripts/test-evening.sh --core
sh scripts/test-craft.sh --core
'
