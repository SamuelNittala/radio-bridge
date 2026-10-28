#!/bin/sh
# Builds the universal app and zips it for a GitHub release: build/RadioBridge-<version>.zip
# Usage: ./release.sh 0.1.0
set -e
cd "$(dirname "$0")"
version="${1:?usage: ./release.sh <version>}"
UNIVERSAL=1 VERSION="$version" ./build.sh
zip="build/RadioBridge-$version.zip"
rm -f "$zip"
# ditto keeps the bundle's signature and attributes intact; plain zip can break them.
ditto -c -k --keepParent "build/Radio Bridge.app" "$zip"
echo "Zipped $zip"
