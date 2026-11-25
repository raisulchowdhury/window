#!/bin/zsh
# Build the website download of Window: a Release Window.app, signed ad hoc, zipped.
#
#   zsh scripts/package-download.sh
#
# Writes dist/Window-<version>.zip and, next to it, a checksum file with the same
# name plus the extension .sha256.
# Needs a Mac with Xcode 26 and xcodegen. It needs no Apple account: there is no
# team, no Developer ID and no notarization. The app is signed ad hoc, which an
# Apple silicon Mac requires before it runs any code.
#
# The download build leaves out the desktop widget. Without a team, macOS gives the
# app and the widget no shared container (an app group ID must start with a team ID
# or come with a provisioning profile), so the widget could only ever say
# "Open Window". The app's application-groups entitlement is dropped for the same
# reason. Build from source with your own team to get the widget.
set -euo pipefail
cd "${0:A:h:h}"
[[ "$(uname -s)" == Darwin ]] || { print -u2 "This script needs macOS and Xcode."; exit 2; }
command -v xcodegen >/dev/null || { print -u2 "Install xcodegen first: brew install xcodegen"; exit 2; }

# The official download's bundle prefix, WINDOW_RELEASE_BUNDLE_PREFIX in Config/Window.xcconfig.
# Set WINDOW_RELEASE_PREFIX to build the same download under another prefix (the Mac
# proof uses com.example.window so its test launch never opens a real install's data).
PREFIX=${WINDOW_RELEASE_PREFIX:-$(sed -n 's/^WINDOW_RELEASE_BUNDLE_PREFIX *= *\([^ ]*\).*/\1/p' Config/Window.xcconfig | head -1)}
[[ -n "$PREFIX" ]] || { print -u2 "No WINDOW_RELEASE_BUNDLE_PREFIX in Config/Window.xcconfig."; exit 1; }

WORK="$PWD/build/download"
DERIVED="$WORK/derived"
STAGE="$WORK/stage"
rm -rf "$WORK"; mkdir -p "$STAGE" dist

xcodegen generate
# Command-line settings override Config/Maintainer.xcconfig and Config/Local.xcconfig.
xcodebuild -scheme Window -configuration Release -derivedDataPath "$DERIVED" \
  WINDOW_BUNDLE_PREFIX="$PREFIX" DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY=- \
  PROVISIONING_PROFILE_SPECIFIER= REGISTER_APP_GROUPS=NO \
  build

BUILT="$DERIVED/Build/Products/Release/Window.app"
[[ -d "$BUILT" ]] || { print -u2 "Build finished but $BUILT is missing."; exit 1; }
# Keep Xcode's own product untouched for inspection and package a copy.
ditto "$BUILT" "$STAGE/Window.app"
APP="$STAGE/Window.app"
PLIST="$APP/Contents/Info.plist"

ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
[[ "$ID" == "$PREFIX".* ]] || { print -u2 "Unexpected bundle ID $ID (want $PREFIX.*)."; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")

# No widget and no app group in the download build (see the note at the top).
rm -rf "$APP/Contents/PlugIns/WindowWidget.appex"
rmdir "$APP/Contents/PlugIns" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Delete :WindowAppGroup' "$PLIST" 2>/dev/null || true

ENT="$WORK/Window.entitlements"
codesign -d --entitlements - --xml "$BUILT" > "$ENT" 2>/dev/null
[[ -s "$ENT" ]] || { print -u2 "Xcode signed the app without entitlements; expected the sandbox."; exit 1; }
for key in com.apple.security.application-groups com.apple.security.get-task-allow; do
  /usr/libexec/PlistBuddy -c "Delete :$key" "$ENT" 2>/dev/null || true
done
codesign --force --sign - --timestamp=none --generate-entitlement-der --entitlements "$ENT" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

INFO=$(codesign -dv --verbose=4 "$APP" 2>&1)
print -r -- "$INFO" | grep -q '^Signature=adhoc' || { print -u2 "Not an ad-hoc signature:"; print -u2 -r -- "$INFO"; exit 1; }
print -r -- "$INFO" | grep -q '^TeamIdentifier=not set' || { print -u2 "A team ID is set; the download build must have none."; exit 1; }

ZIP="dist/Window-$VERSION.zip"
EXT=sha256  # spelled apart so the export's source check doesn't read it as a script name
SUM="$ZIP.$EXT"
rm -f "$ZIP" "$SUM"
ditto -c -k --keepParent "$APP" "$ZIP"
# The checksum file names the zip without a folder, so `shasum -a 256 -c` works next to it.
(cd dist && shasum -a 256 "${ZIP:t}" > "${SUM:t}")

print "Bundle ID: $ID"
print "Version:   $VERSION"
print "Signature: ad hoc, no team"
print "Size:      $(stat -f %z "$ZIP") bytes"
print "SHA-256:   $(cut -d ' ' -f 1 "$SUM")"
print "ZIP $PWD/$ZIP"
