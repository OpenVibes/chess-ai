#!/bin/sh
# Copies the current DMG from dist/ into the site and deploys it to Vercel (production).
# Run ./build.sh first. If the version changes, also update the version, size and SHA-256 in index.html.
set -e
cd "$(dirname "$0")"
VERSION=$(sed -n 's/^VERSION=//p' ../build.sh)
DMG="../dist/Chess-$VERSION.dmg"
[ -f "$DMG" ] || { echo "missing $DMG: run ../build.sh first"; exit 1; }
mkdir -p download
cp "$DMG" download/
echo "SHA-256: $(shasum -a 256 "download/Chess-$VERSION.dmg" | cut -d' ' -f1)"
npx --yes vercel@65.16.0 deploy --prod --yes
