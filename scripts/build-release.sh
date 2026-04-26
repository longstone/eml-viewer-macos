#!/usr/bin/env bash
# Build a release .app and package it as a .zip that is ready for distribution
# via a Homebrew cask.
#
# Usage:
#   scripts/build-release.sh [version]
#
# Outputs:
#   dist/eml-viewer.app
#   dist/eml-viewer-<version>.zip
#   dist/eml-viewer-<version>.zip.sha256

set -euo pipefail

VERSION="${1:-$(date +%Y.%m.%d)}"
SCHEME="eml-viewer"
PROJECT="eml-viewer.xcodeproj"
CONFIG="Release"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
BUILD="$ROOT/.build-release"
rm -rf "$DIST" "$BUILD"
mkdir -p "$DIST" "$BUILD"

echo "==> Building $SCHEME $VERSION ($CONFIG)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="$BUILD/Build/Products/$CONFIG/$SCHEME.app"
if [ ! -d "$APP" ]; then
  echo "error: built app not found at $APP" >&2
  exit 1
fi

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"

cp -R "$APP" "$DIST/"

ZIP="$DIST/eml-viewer-$VERSION.zip"
echo "==> Zipping -> $ZIP"
/usr/bin/ditto -c -k --keepParent "$DIST/$SCHEME.app" "$ZIP"

SHASUM="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "$SHASUM  $(basename "$ZIP")" > "$ZIP.sha256"

echo
echo "Built: $ZIP"
echo "SHA-256: $SHASUM"
echo
echo "Paste into the Homebrew cask:"
echo "  version \"$VERSION\""
echo "  sha256  \"$SHASUM\""
