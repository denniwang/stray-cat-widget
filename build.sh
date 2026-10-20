#!/bin/sh
# Builds build/StrayCat.app (universal: Apple Silicon + Intel, macOS 13+) and build/StrayCat.zip.
set -e
cd "$(dirname "$0")"
APP=build/StrayCat.app
rm -rf "$APP" build/StrayCat.zip build/StrayCat.zip.sha256 build/.arm64 build/.x86_64
mkdir -p "$APP/Contents/MacOS"

for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
        -framework AppKit -framework ServiceManagement -framework CoreAudio \
        -o "build/.$arch" Sources/main.swift
done
lipo -create build/.arm64 build/.x86_64 -output "$APP/Contents/MacOS/StrayCat"
rm -f build/.arm64 build/.x86_64

cp Info.plist "$APP/Contents/Info.plist"
# CI passes VERSION (for example 1.2.0, from the v1.2.0 tag) so the app reports the release it came from.
if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" build/StrayCat.zip
(cd build && shasum -a 256 StrayCat.zip > StrayCat.zip.sha256)
echo "Built $APP, build/StrayCat.zip and build/StrayCat.zip.sha256"
