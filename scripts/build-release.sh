#!/bin/bash
# Builds VidFlow.app (universal), then the .dmg people install from, the .zip the in-app updater uses, and the
# update-macos.json manifest that points at it. Everything lands in dist/.
#
#   scripts/build-release.sh [version]
#
# Signing, all optional; without them the build is ad-hoc signed, for local use only:
#   DEVELOPER_ID   "Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE a profile saved with: xcrun notarytool store-credentials
#   RELEASE_URL    where the zip will live (default: this version's GitHub release)
#   ARCHS_OVERRIDE "arm64" for a quick single-architecture build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" # Other tools named codesign (Anaconda has one) mustn't win.

VERSION="${1:-$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' VidFlow.xcodeproj/project.pbxproj | head -1)}"
ARCHS_LIST="${ARCHS_OVERRIDE:-arm64 x86_64}"
IDENTITY="${DEVELOPER_ID:--}"
DIST="$ROOT/dist"
DERIVED="$ROOT/build/release"
APP="$DERIVED/Build/Products/Release/VidFlow.app"
BASE_URL="${RELEASE_URL:-https://github.com/Magicherry/VidFlow-for-Mac/releases/download/v$VERSION}"

rm -rf "$DIST"
mkdir -p "$DIST"

(cd Packages/VidFlowCore && swift test --parallel 2>&1 | tail -1)

xcodebuild -project VidFlow.xcodeproj -scheme VidFlow -configuration Release -derivedDataPath "$DERIVED" \
    -destination 'generic/platform=macOS' ARCHS="$ARCHS_LIST" ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" \
    CODE_SIGN_IDENTITY=- clean build | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'

# Inside out, as Gatekeeper checks it: helper first, then the app; Hardened Runtime on both.
TIMESTAMP=$([ "$IDENTITY" = "-" ] && echo "--timestamp=none" || echo "--timestamp")
codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$APP/Contents/Helpers/aria2c"
codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARIZE_ZIP="$DERIVED/notarize.zip"
    ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
fi

ZIP="$DIST/VidFlow-$VERSION-macos.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

# The disk image: the app beside a link to Applications.
STAGE="$DERIVED/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/VidFlow.app"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/VidFlow-$VERSION-macos.dmg"
hdiutil create -quiet -volname "VidFlow $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
if [ "$IDENTITY" != "-" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

NOTES=""
[ -f "docs/release-notes/$VERSION.md" ] && NOTES="$(cat "docs/release-notes/$VERSION.md")"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
SIZE="$(stat -f%z "$ZIP")"
NOTES="$NOTES" python3 -I - "$VERSION" "$BASE_URL/$(basename "$ZIP")" "$SHA" "$SIZE" > "$DIST/update-macos.json" <<'PY'
import datetime, json, os, sys
v, url, sha, size = sys.argv[1:5]
print(json.dumps({"version": v, "url": url, "sha256": sha, "size": int(size), "notes": os.environ["NOTES"],
                  "published": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
                 ensure_ascii=False, indent=2))
PY

spctl -a -t exec -vv "$APP" 2>&1 | head -2 || true
ls -la "$DIST"
