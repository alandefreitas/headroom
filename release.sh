#!/bin/sh
# Builds a universal Headroom.app and packages it for a GitHub release.
#
#   ./release.sh 0.1.0
#
# Writes dist/Headroom-0.1.0.dmg (drag to Applications) and
# dist/Headroom-0.1.0.zip, plus SHA-256 checksums.
set -e
cd "$(dirname "$0")"

VERSION=${1:?usage: ./release.sh <version>, e.g. ./release.sh 0.1.0}
UNIVERSAL=1 VERSION="$VERSION" ./build.sh

rm -rf dist
mkdir -p dist

# ditto keeps the bundle's symlinks and extended attributes intact.
ditto -c -k --keepParent Headroom.app "dist/Headroom-$VERSION.zip"

STAGE=$(mktemp -d)
cp -R Headroom.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Headroom" -srcfolder "$STAGE" -format UDZO \
  "dist/Headroom-$VERSION.dmg"
rm -rf "$STAGE"

cd dist
shasum -a 256 "Headroom-$VERSION.dmg" "Headroom-$VERSION.zip" > SHA256SUMS.txt
cat SHA256SUMS.txt
