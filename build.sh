#!/bin/sh
# Builds "build/Radio Bridge.app". Needs Xcode or its command line tools.
# UNIVERSAL=1 builds for Apple silicon and Intel (needs Xcode); VERSION=1.2.3 sets the app's version.
set -e
cd "$(dirname "$0")"
if [ -n "$UNIVERSAL" ]; then
    arch="--arch arm64 --arch x86_64"
fi
swift build -c release $arch
bin="$(swift build -c release $arch --show-bin-path)"
app="build/Radio Bridge.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/RadioBridge" "$app/Contents/MacOS/"
cp Bundle/Info.plist "$app/Contents/"
if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$app/Contents/Info.plist"
fi
# Signed shortcut files: the setup screen opens them so Shortcuts offers "Add Shortcut".
mkdir -p "$app/Contents/Resources"
cp Bundle/Shortcuts/*.shortcut "$app/Contents/Resources/"
# Ad-hoc signature: enough to run locally; sharing needs a Developer ID and notarisation.
codesign --force --sign - "$app"
echo "Built $app"
