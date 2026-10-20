#!/bin/bash
# Installs (or updates) Stray Cat from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/denniwang/stray-cat-widget/main/install.sh | bash
#
# Files fetched with curl are not quarantined, so macOS opens the app without the Gatekeeper warning.
# Optional environment variables:
#   STRAYCAT_DIR=<folder>   install here instead of /Applications (or ~/Applications if that isn't writable)
#   STRAYCAT_URL=<url>      download this zip instead of the latest release (a .sha256 file next to it is used if present)
#   STRAYCAT_NO_LAUNCH=1    don't open the app afterwards
set -euo pipefail

REPO="denniwang/stray-cat-widget"
URL="${STRAYCAT_URL:-https://github.com/$REPO/releases/latest/download/StrayCat.zip}"
APP="StrayCat.app"

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Stray Cat only runs on macOS."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 13 ] || die "Stray Cat needs macOS 13 or later (this is $(sw_vers -productVersion))."
for tool in curl ditto codesign shasum; do
    command -v "$tool" >/dev/null || die "Missing required tool: $tool"
done

# Choose where to install without needing sudo.
if [ -n "${STRAYCAT_DIR:-}" ]; then
    dest="$STRAYCAT_DIR"
elif [ -w /Applications ]; then
    dest="/Applications"
else
    dest="$HOME/Applications"
fi
mkdir -p "$dest" || die "Can't create $dest."
[ -w "$dest" ] || die "$dest isn't writable. Set STRAYCAT_DIR to a folder you own."

work="$(mktemp -d "${TMPDIR:-/tmp}/straycat.XXXXXX")"
trap 'rm -rf "$work"' EXIT

say "Downloading Stray Cat…"
curl -fL --retry 3 --connect-timeout 15 --progress-bar -o "$work/StrayCat.zip" "$URL" \
    || die "Download failed. Check your connection, or that a release exists at $URL"

# Verify against the published checksum when there is one.
if curl -fsSL --connect-timeout 15 -o "$work/StrayCat.zip.sha256" "$URL.sha256" 2>/dev/null; then
    expected="$(awk '{print $1}' "$work/StrayCat.zip.sha256")"
    actual="$(shasum -a 256 "$work/StrayCat.zip" | awk '{print $1}')"
    [ -n "$expected" ] && [ "$expected" = "$actual" ] || die "Checksum mismatch. The download is corrupt or was tampered with."
    say "Checksum OK."
fi

mkdir "$work/unpacked"
ditto -x -k "$work/StrayCat.zip" "$work/unpacked" || die "The download isn't a valid zip."
[ -d "$work/unpacked/$APP" ] || die "The download doesn't contain $APP."
[ -x "$work/unpacked/$APP/Contents/MacOS/StrayCat" ] || die "The app inside the download is incomplete."
codesign --verify "$work/unpacked/$APP" 2>/dev/null || die "The app's signature is invalid."
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$work/unpacked/$APP/Contents/Info.plist" 2>/dev/null || echo '?')"

# Quit a copy that is running from the install location so its files can be replaced.
# (Copies running from elsewhere, such as a build folder, are left alone.)
running="$(pgrep -f "$dest/$APP/Contents/MacOS/StrayCat" 2>/dev/null || true)"
if [ -n "$running" ]; then
    say "Quitting the running Stray Cat…"
    # shellcheck disable=SC2086
    kill $running 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$dest/$APP/Contents/MacOS/StrayCat" >/dev/null 2>&1 || break; sleep 0.3; done
fi

# Install next to the target first, then swap, so a failure never leaves a half-copied app behind.
ditto "$work/unpacked/$APP" "$dest/.$APP.new"
xattr -dr com.apple.quarantine "$dest/.$APP.new" 2>/dev/null || true
rm -rf "$dest/$APP"
mv "$dest/.$APP.new" "$dest/$APP"

say "Installed Stray Cat $version to $dest/$APP"
if [ "$dest" != "/Applications" ]; then
    say "Note: \"Start at login\" works most reliably from /Applications."
fi

if [ -z "${STRAYCAT_NO_LAUNCH:-}" ]; then
    open "$dest/$APP"
    say "Look for the 🐈, ⚙︎ and ⏱ icons in your menu bar."
fi
