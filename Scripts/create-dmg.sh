#!/bin/bash
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────
APP_NAME="Prism"
BUNDLE_ID="com.subversivesoftware.prism"
VERSION="1.0.0"
IDENTITY="Developer ID Application: Matt Konda (84CC987JU3)"
TEAM_ID="${TEAM_ID:-84CC987JU3}"
APPLE_ID="${APPLE_ID:-}"
APP_PASSWORD="${APP_PASSWORD:-}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_PATH="$BUILD_DIR/Release/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-${VERSION}"
WWW_UPDATES="$PROJECT_DIR/../www/static/updates/prism"

SKIP_NOTARIZE=false
if [[ "${1:-}" == "--skip-notarize" ]]; then
    SKIP_NOTARIZE=true
fi

# ── 1. Clean check ────────────────────────────────────────────────
if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]]; then
    echo "ERROR: Uncommitted changes. Commit or stash before building."
    exit 1
fi

# ── 2. Version bump ───────────────────────────────────────────────
PLIST="$PROJECT_DIR/Info.plist"
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
NEW_BUILD=$((CURRENT_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
echo "Build: $CURRENT_BUILD → $NEW_BUILD"

# ── 3. Build ──────────────────────────────────────────────────────
echo "Building ${APP_NAME}..."
DERIVED_DATA="$BUILD_DIR/DerivedData"

xcodebuild -project "$PROJECT_DIR/${APP_NAME}.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -arch arm64 -arch x86_64 \
    ONLY_ACTIVE_ARCH=NO \
    clean build 2>&1 | tail -5

# ── 4. Deep sign ──────────────────────────────────────────────────
echo "Signing..."

SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
    for xpc in "$SPARKLE_FW"/Versions/B/XPCServices/*.xpc; do
        [[ -e "$xpc" ]] && codesign --force --options runtime --sign "$IDENTITY" --timestamp "$xpc"
    done
    for app in "$SPARKLE_FW"/Versions/B/*.app; do
        [[ -e "$app" ]] && codesign --force --options runtime --sign "$IDENTITY" --timestamp "$app"
    done
    [[ -f "$SPARKLE_FW/Versions/B/Autoupdate" ]] && \
        codesign --force --options runtime --sign "$IDENTITY" --timestamp "$SPARKLE_FW/Versions/B/Autoupdate"
    codesign --force --options runtime --sign "$IDENTITY" --timestamp "$SPARKLE_FW"
fi

codesign --force --options runtime --sign "$IDENTITY" --timestamp \
    --entitlements "$PROJECT_DIR/${APP_NAME}.entitlements" "$APP_PATH"

codesign --verify --verbose=2 --deep "$APP_PATH"
echo "Signing verified."

# ── 5. Create DMG ─────────────────────────────────────────────────
echo "Creating DMG..."
DMG_PATH="$BUILD_DIR/${DMG_NAME}.dmg"
rm -f "$DMG_PATH"

if command -v create-dmg &>/dev/null; then
    create-dmg \
        --volname "$APP_NAME" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 150 190 \
        --app-drop-link 450 190 \
        "$DMG_PATH" "$APP_PATH"
else
    hdiutil create -volname "$APP_NAME" -srcfolder "$APP_PATH" \
        -ov -format UDZO "$DMG_PATH"
fi

# ── 6. Notarize ───────────────────────────────────────────────────
if [[ "$SKIP_NOTARIZE" == false ]]; then
    echo "Notarizing..."
    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait

    xcrun stapler staple "$DMG_PATH"
    echo "Notarization complete."
fi

# ── 7. Sparkle zip ────────────────────────────────────────────────
SPARKLE_DIR="$BUILD_DIR/sparkle"
rm -rf "$SPARKLE_DIR"
mkdir -p "$SPARKLE_DIR"
ZIP_NAME="${APP_NAME}-${VERSION}-b${NEW_BUILD}.zip"
ditto -c -k --keepParent "$APP_PATH" "$SPARKLE_DIR/$ZIP_NAME"

# ── 8. Generate appcast ──────────────────────────────────────────
GENERATE_APPCAST=$(find "$DERIVED_DATA/SourcePackages/artifacts" \
    "$PROJECT_DIR/.build/artifacts" \
    "$HOME/Library/Developer/Xcode/DerivedData"/${APP_NAME}-*/SourcePackages/artifacts \
    -name "generate_appcast" -type f 2>/dev/null | head -1)

if [[ -n "$GENERATE_APPCAST" ]]; then
    "$GENERATE_APPCAST" "$SPARKLE_DIR"
    echo "Appcast generated."
else
    echo "WARNING: generate_appcast not found. Skipping appcast generation."
fi

# ── 9. Git tag + push ─────────────────────────────────────────────
TAG="v${VERSION}-b${NEW_BUILD}"
git -C "$PROJECT_DIR" add Info.plist
git -C "$PROJECT_DIR" commit -m "Build ${NEW_BUILD}"
git -C "$PROJECT_DIR" tag -a "$TAG" -m "${APP_NAME} ${VERSION} build ${NEW_BUILD}"
git -C "$PROJECT_DIR" push && git -C "$PROJECT_DIR" push --tags

# ── 10. GitHub release ────────────────────────────────────────────
PREV_TAG=$(git -C "$PROJECT_DIR" tag --sort=-v:refname | grep -v "^$TAG$" | head -1)
RELEASE_NOTES=""
if [[ -n "$PREV_TAG" ]]; then
    RELEASE_NOTES=$(git -C "$PROJECT_DIR" log --pretty=format:"- %s" "$PREV_TAG".."$TAG" -- . ':!Info.plist' \
        | grep -v "^- Build [0-9]" || true)
fi

gh release create "$TAG" \
    "$DMG_PATH" "$SPARKLE_DIR/$ZIP_NAME" \
    --repo "subversivesoftwareorg/prism" \
    --title "${APP_NAME} ${VERSION} (Build ${NEW_BUILD})" \
    --notes "${RELEASE_NOTES:-Initial release}"

# ── 11. Rewrite + stage ──────────────────────────────────────────
APPCAST_FILE="$SPARKLE_DIR/appcast.xml"
if [[ -f "$APPCAST_FILE" ]]; then
    GITHUB_URL="https://github.com/subversivesoftwareorg/prism/releases/download/${TAG}/${ZIP_NAME}"
    sed -i '' "s|url=\"[^\"]*${ZIP_NAME}\"|url=\"${GITHUB_URL}\"|" "$APPCAST_FILE"
    mkdir -p "$WWW_UPDATES"
    cp "$APPCAST_FILE" "$WWW_UPDATES/appcast.xml"
    echo "Appcast staged to website."
fi

echo ""
echo "Done! Deploy the website:"
echo "  cd ../www && git add -A && git commit -m 'Prism ${VERSION} build ${NEW_BUILD}' && git push"
