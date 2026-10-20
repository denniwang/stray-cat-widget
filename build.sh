#!/bin/sh
# Builds build/StrayCat.app (universal: Apple Silicon + Intel, macOS 13+) and build/StrayCat.zip.
set -e
cd "$(dirname "$0")"
APP=build/StrayCat.app
rm -rf "$APP" build/StrayCat.zip build/StrayCat.zip.sha256 build/.arm64 build/.x86_64
mkdir -p "$APP/Contents/MacOS"

DEMO_SWIFT_FLAGS=
if [ "${DEMO_CAPTURE:-0}" = "1" ]; then
    DEMO_SWIFT_FLAGS="-D DEMO_CAPTURE"
fi

for arch in arm64 x86_64; do
    # DEMO_SWIFT_FLAGS is an optional pair of fixed compiler arguments.
    swiftc $DEMO_SWIFT_FLAGS -O -swift-version 5 -target "$arch-apple-macos13.0" \
        -framework AppKit -framework ServiceManagement -framework CoreAudio \
        -o "build/.$arch" Sources/main.swift
done
lipo -create build/.arm64 build/.x86_64 -output "$APP/Contents/MacOS/StrayCat"
rm -f build/.arm64 build/.x86_64

cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ "${DEMO_CAPTURE:-0}" = "1" ]; then
    cp Resources/demo-cat.gif "$APP/Contents/Resources/demo-cat.gif"
fi
# CI passes VERSION (for example 1.2.0, from the v1.2.0 tag) so the app reports the release it came from.
if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" build/StrayCat.zip
(cd build && shasum -a 256 StrayCat.zip > StrayCat.zip.sha256)
echo "Built $APP, build/StrayCat.zip and build/StrayCat.zip.sha256"
