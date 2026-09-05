#!/bin/sh
set -eu

swift build -c release
bundle=".build/Petalo.app"
/bin/rm -rf "$bundle"
/bin/mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
/bin/cp config/Info.plist "$bundle/Contents/Info.plist"
/bin/cp config/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
/bin/cp .build/release/Petalo "$bundle/Contents/MacOS/Petalo"
# Keep the shader inside the signed bundle resources; the app resolves this
# main-bundle copy first and SwiftPM's module bundle during `swift run`.
/bin/cp .build/release/Petalo_PetaloApp.bundle/default.metallib "$bundle/Contents/Resources/default.metallib"
/bin/chmod 755 "$bundle/Contents/MacOS/Petalo"

# Use a stable signing identity when available so macOS Privacy & Security
# (TCC) recognises the rebuilt app as the same one instead of creating a new
# orphaned entry each time. Falls back to ad-hoc signing if no certificate is
# found.
sign_identity=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/grep "Developer ID Application" \
    | /usr/bin/awk -F'"' '{print $2}' \
    | /usr/bin/head -1)
if [ -n "$sign_identity" ]; then
    /usr/bin/codesign --force --deep --sign "$sign_identity" "$bundle"
    /usr/bin/printf 'Signed with: %s\n' "$sign_identity"
else
    /usr/bin/codesign --force --deep --sign - "$bundle"
    /usr/bin/printf 'Signed ad-hoc (no Developer ID found; TCC entries may duplicate on rebuild)\n'
fi

/usr/bin/printf 'Built %s\n' "$bundle"
