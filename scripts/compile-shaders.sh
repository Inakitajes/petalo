#!/bin/sh
# Recompiles the SwiftUI layer-effect shaders into the prebuilt metallib the
# package ships as a resource. swift build cannot compile Metal sources, so
# run this after editing Sources/PetaloApp/Ripple.metal and commit the
# regenerated default.metallib alongside it.
#
# Requires the Metal toolchain: xcodebuild -downloadComponent MetalToolchain
set -eu

cd "$(dirname "$0")/.."
mkdir -p Sources/PetaloApp/Resources
xcrun -sdk macosx metal \
    Sources/PetaloApp/Ripple.metal \
    -o Sources/PetaloApp/Resources/default.metallib

# Fail loudly on an unloadable library. A corrupt metallib is invisible at
# build time and degrades at runtime into a blank layer effect: the notch
# scrim vanishes for the ripple's duration and the surface reads as the
# detached external-display bubble mid-transition.
xcrun metal-lipo -info Sources/PetaloApp/Resources/default.metallib >/dev/null

echo "Wrote Sources/PetaloApp/Resources/default.metallib"
