#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodegen generate
xcodebuild -scheme Window -configuration Debug -derivedDataPath "$HOME/Library/Caches/WindowTaras" build
print "$HOME/Library/Caches/WindowTaras/Build/Products/Debug/Window.app"
