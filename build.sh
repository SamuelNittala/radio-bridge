#!/bin/sh
# Builds "build/Radio Bridge.app". Needs Xcode or its command line tools.
set -e
cd "$(dirname "$0")"
swift build -c release
app="build/Radio Bridge.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/RadioBridge "$app/Contents/MacOS/"
cp Bundle/Info.plist "$app/Contents/"
# Signed shortcut files: the setup screen opens them so Shortcuts offers "Add Shortcut".
mkdir -p "$app/Contents/Resources"
cp Bundle/Shortcuts/*.shortcut "$app/Contents/Resources/"
# Ad-hoc signature: enough to run locally; sharing needs a Developer ID and notarisation.
codesign --force --sign - "$app"
echo "Built $app"
