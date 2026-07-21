#!/bin/sh
# Builds a universal (arm64 + x86_64) Prism.app, signs it with Developer ID,
# notarizes it, packages a DMG, generates the Sparkle appcast, tags the
# release, and publishes it to GitHub Releases.
#
# Requirements:
#   brew install create-dmg
#   A "Developer ID Application" certificate in your keychain
#   The shared Sparkle EdDSA private key in your keychain (generate_keys)
#   gh CLI authenticated (for the GitHub release step)
#
# Environment variables (optional — prompted if missing):
#   APPLE_ID        — Apple ID email for notarization
#   TEAM_ID         — Apple Developer team ID (default: 84CC987JU3)
#   APP_PASSWORD    — app-specific password for notarytool
#                     (appleid.apple.com > Sign-In and Security > App-Specific Passwords)
#
# Usage:
#   ./Scripts/create-dmg.sh                   # full build + sign + notarize + release
#   ./Scripts/create-dmg.sh --skip-notarize   # build + sign only (for testing)

set -e

APP_NAME="Prism"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
STAGING_DIR="$BUILD_DIR/dmg-staging"
DERIVED_DATA="$BUILD_DIR/DerivedData"
PLIST="$PROJECT_DIR/Info.plist"
NOTARIZE_TIMEOUT="15m"

SKIP_NOTARIZE=false
if [ "$1" = "--skip-notarize" ]; then
    SKIP_NOTARIZE=true
fi

# ── Prerequisites ─────────────────────────────────────────────────
if ! command -v create-dmg >/dev/null 2>&1; then
    echo "Error: create-dmg is not installed."
    echo "Install it with: brew install create-dmg"
    exit 1
fi

# ── Find Developer ID certificate ────────────────────────────────
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [ -z "$IDENTITY" ]; then
    echo "Error: No 'Developer ID Application' certificate found in keychain."
    if [ "$SKIP_NOTARIZE" = true ]; then
        echo "Continuing without signing..."
    else
        echo "For unsigned test builds, use: ./Scripts/create-dmg.sh --skip-notarize"
        exit 1
    fi
fi

# ── Sparkle EdDSA key check ──────────────────────────────────────
# generate_appcast signs update entries with the shared private key.
# Fail before doing any work rather than after a full notarization.
if [ "$SKIP_NOTARIZE" = false ]; then
    if ! security find-generic-password -s "https://sparkle-project.org" >/dev/null 2>&1 && \
       ! security find-generic-password -l "Private key for signing Sparkle updates" >/dev/null 2>&1; then
        echo "Error: Sparkle EdDSA private key not found in keychain."
        echo "Import the shared Subversive Software key, or run Sparkle's generate_keys."
        echo "For test builds without appcast signing: ./Scripts/create-dmg.sh --skip-notarize"
        exit 1
    fi
fi

# ── Notarization credentials ─────────────────────────────────────
if [ "$SKIP_NOTARIZE" = false ] && [ -n "$IDENTITY" ]; then
    TEAM_ID="${TEAM_ID:-84CC987JU3}"

    if [ -z "$APPLE_ID" ]; then
        printf "Apple ID (email) for notarization: "
        read -r APPLE_ID
    fi
    if [ -z "$APP_PASSWORD" ]; then
        echo "App-specific password required for notarization."
        echo "Create one at: https://appleid.apple.com > Sign-In and Security > App-Specific Passwords"
        printf "App-specific password: "
        stty -echo
        read -r APP_PASSWORD
        stty echo
        echo ""
    fi
fi

# ── Verify clean working directory ───────────────────────────────
if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]; then
        echo "Error: Working directory has uncommitted changes."
        echo "Commit or stash them before building a release."
        echo ""
        git -C "$PROJECT_DIR" status --short
        exit 1
    fi
fi

# ── Auto-increment build number (with rollback on failure) ───────
# The bump happens before the build so the app embeds the new number.
# If anything fails before the release commit, the bump is undone so
# the tree stays clean and the number isn't burned.
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
NEW_BUILD=$((CURRENT_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
echo "==> Incrementing build number: $CURRENT_BUILD → $NEW_BUILD"

ROLLBACK=1
cleanup() {
    if [ "$ROLLBACK" = "1" ]; then
        git -C "$PROJECT_DIR" checkout -- Info.plist 2>/dev/null || true
        echo "NOTE: Rolled back Info.plist build-number bump."
    fi
}
trap cleanup EXIT

# ── Clean & Build (Universal Binary) ─────────────────────────────
echo "==> Building ${APP_NAME} (Release, Universal: arm64 + x86_64)..."
xcodebuild -project "$PROJECT_DIR/${APP_NAME}.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    clean build \
    | tail -5

APP_PATH="$DERIVED_DATA/Build/Products/Release/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Error: Build failed — ${APP_NAME}.app not found at $APP_PATH"
    exit 1
fi

if [ ! -f "$APP_PATH/Contents/MacOS/${APP_NAME}" ]; then
    echo "Error: Build produced an app bundle but the binary is missing!"
    echo "Check the full build log for compiler errors."
    exit 1
fi

echo "==> Verifying universal binary..."
ARCHS=$(lipo -archs "$APP_PATH/Contents/MacOS/${APP_NAME}" 2>/dev/null || echo "unknown")
echo "    Architectures: $ARCHS"
if echo "$ARCHS" | grep -q "arm64" && echo "$ARCHS" | grep -q "x86_64"; then
    echo "    Universal binary OK"
else
    echo "    Warning: Expected universal binary (arm64 x86_64), got: $ARCHS"
fi

# ── Code signing ──────────────────────────────────────────────────
# Timestamped signing depends on Apple's timestamp service, which
# occasionally drops requests mid-run. Retry transient failures
# before giving up on the whole release.
retry() {
    _attempt=1
    while ! "$@"; do
        if [ "$_attempt" -ge 3 ]; then
            echo "Error: command failed after 3 attempts: $*"
            return 1
        fi
        echo "    Transient failure, retrying ($_attempt/3)..."
        _attempt=$((_attempt + 1))
        sleep 5
    done
}

if [ -n "$IDENTITY" ]; then
    echo "==> Signing embedded frameworks and helpers..."
    SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
    if [ -d "$SPARKLE_FW" ]; then
        for xpc in "$SPARKLE_FW"/Versions/B/XPCServices/*.xpc; do
            [ -d "$xpc" ] && retry codesign --force --options runtime --sign "$IDENTITY" --timestamp "$xpc"
        done
        for helper in "$SPARKLE_FW"/Versions/B/*.app; do
            [ -d "$helper" ] && retry codesign --force --options runtime --sign "$IDENTITY" --timestamp "$helper"
        done
        [ -f "$SPARKLE_FW/Versions/B/Autoupdate" ] && \
            retry codesign --force --options runtime --sign "$IDENTITY" --timestamp "$SPARKLE_FW/Versions/B/Autoupdate"
        retry codesign --force --options runtime --sign "$IDENTITY" --timestamp "$SPARKLE_FW"
    fi

    echo "==> Signing app with: $IDENTITY"
    retry codesign --force --options runtime \
        --sign "$IDENTITY" \
        --timestamp \
        --entitlements "$PROJECT_DIR/${APP_NAME}.entitlements" \
        "$APP_PATH"
    echo "==> Verifying signature..."
    codesign --verify --verbose=2 --deep "$APP_PATH"
    echo "    Signature OK"
fi

# ── Extract version ──────────────────────────────────────────────
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
DMG_NAME="${APP_NAME}-${VERSION}-b${BUILD_NUM}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

echo "==> Packaging ${APP_NAME} ${VERSION} (build ${BUILD_NUM}) into ${DMG_NAME}..."

# ── Create DMG ───────────────────────────────────────────────────
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
rm -f "$DMG_PATH"

ICON_PATH="$APP_PATH/Contents/Resources/AppIcon.icns"
VOL_ICON_FLAG=""
if [ -f "$ICON_PATH" ]; then
    VOL_ICON_FLAG="--volicon $ICON_PATH"
fi

if command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
        --volname "$APP_NAME" \
        $VOL_ICON_FLAG \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "${APP_NAME}.app" 175 190 \
        --app-drop-link 425 190 \
        --hide-extension "${APP_NAME}.app" \
        "$DMG_PATH" \
        "$STAGING_DIR"
else
    ln -s /Applications "$STAGING_DIR/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" \
        -ov -format UDZO "$DMG_PATH"
fi

# ── Sign the DMG itself ──────────────────────────────────────────
if [ -n "$IDENTITY" ]; then
    echo "==> Signing DMG..."
    retry codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
fi

# ── Notarize + staple ────────────────────────────────────────────
NOTARIZED=false
if [ "$SKIP_NOTARIZE" = false ] && [ -n "$IDENTITY" ]; then
    echo "==> Submitting for notarization (timeout: ${NOTARIZE_TIMEOUT})..."
    if xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait \
        --timeout "$NOTARIZE_TIMEOUT"; then

        NOTARIZED=true
        echo "==> Stapling notarization ticket to DMG..."
        xcrun stapler staple "$DMG_PATH"

        # Notarizing the DMG also records the nested app, so its ticket can
        # be stapled directly — the Sparkle zip then carries a stapled app.
        echo "==> Stapling notarization ticket to app..."
        xcrun stapler staple "$APP_PATH" || echo "    Warning: app staple failed (Sparkle updates will use online check)"

        echo "==> Verifying notarization..."
        spctl --assess --type open --context context:primary-signature "$DMG_PATH" \
            && echo "    Notarization OK" \
            || echo "    Warning: spctl check failed (may need to retry)"
    else
        echo ""
        echo "ERROR: Notarization did not complete within ${NOTARIZE_TIMEOUT}."
        echo "Check status with:"
        echo "  xcrun notarytool history --apple-id $APPLE_ID --team-id $TEAM_ID --password YOUR_PASSWORD"
        exit 1
    fi
fi

# ── Sparkle update archive + appcast ─────────────────────────────
echo "==> Creating Sparkle update archive..."
SPARKLE_DIR="$BUILD_DIR/sparkle"
rm -rf "$SPARKLE_DIR"
mkdir -p "$SPARKLE_DIR"

ZIP_NAME="${APP_NAME}-${VERSION}-b${BUILD_NUM}.zip"
ZIP_PATH="$SPARKLE_DIR/$ZIP_NAME"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
echo "    Archive: $ZIP_PATH"

GENERATE_APPCAST=$(find \
    "$PROJECT_DIR/.build/artifacts" \
    "$DERIVED_DATA/SourcePackages/artifacts" \
    -name "generate_appcast" -type f 2>/dev/null | head -1)

if [ -n "$GENERATE_APPCAST" ] && [ -x "$GENERATE_APPCAST" ]; then
    echo "==> Generating appcast..."
    "$GENERATE_APPCAST" "$SPARKLE_DIR"
    echo "    Appcast: $SPARKLE_DIR/appcast.xml"
else
    echo "WARNING: generate_appcast not found. Run 'swift package resolve' first."
fi

# ── Stage appcast to website (binaries go to GitHub Releases) ────
WWW_UPDATES="$PROJECT_DIR/../www/static/updates/prism"
if [ -d "$PROJECT_DIR/../www" ]; then
    mkdir -p "$WWW_UPDATES"
    [ -f "$SPARKLE_DIR/appcast.xml" ] && cp -f "$SPARKLE_DIR/appcast.xml" "$WWW_UPDATES/"
    echo "    Appcast staged to: $WWW_UPDATES/appcast.xml"
fi

# ── Cleanup ──────────────────────────────────────────────────────
rm -rf "$STAGING_DIR"

# ── Git commit + tag + push ──────────────────────────────────────
# Success point: from here the build number is real, so keep it.
TAG="v${VERSION}-b${BUILD_NUM}"
if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$PROJECT_DIR" add Info.plist
    git -C "$PROJECT_DIR" commit -m "Build $BUILD_NUM for v$VERSION distribution"
    ROLLBACK=0
    git -C "$PROJECT_DIR" tag -a "$TAG" -m "${APP_NAME} $VERSION build $BUILD_NUM"
    echo "    Tagged: $TAG"
    echo "==> Pushing to remote..."
    git -C "$PROJECT_DIR" push && git -C "$PROJECT_DIR" push --tags
fi

# ── GitHub Release ───────────────────────────────────────────────
if command -v gh >/dev/null 2>&1; then
    echo "==> Creating GitHub release..."
    PREV_TAG=$(git -C "$PROJECT_DIR" tag --sort=-v:refname | grep -v "^$TAG$" | head -1)
    RELEASE_NOTES=""
    if [ -n "$PREV_TAG" ]; then
        RELEASE_NOTES=$(git -C "$PROJECT_DIR" log --pretty=format:"- %s" "$PREV_TAG".."$TAG" -- . ':!Info.plist' \
            | grep -v "^- Build [0-9]" || true)
    fi
    if [ -z "$RELEASE_NOTES" ]; then
        RELEASE_NOTES="${APP_NAME} $VERSION build $BUILD_NUM"
    fi

    NOTES_BODY="## What's New

$RELEASE_NOTES

## Install

Download **$DMG_NAME**, open it, and drag ${APP_NAME} to your Applications folder.

Existing users with auto-update enabled will receive this update automatically via Sparkle."

    REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner)

    gh release create "$TAG" "$DMG_PATH" "$ZIP_PATH" \
        --title "${APP_NAME} $VERSION (build $BUILD_NUM)" \
        --notes "$NOTES_BODY" \
        && echo "    Release: https://github.com/$REPO_SLUG/releases/tag/$TAG" \
        || echo "    WARNING: GitHub release creation failed."

    # Rewrite appcast enclosure URL to point at GitHub Releases
    GITHUB_ZIP_URL="https://github.com/$REPO_SLUG/releases/download/$TAG/$ZIP_NAME"
    if [ -f "$WWW_UPDATES/appcast.xml" ]; then
        sed -i '' "s|url=\"[^\"]*$ZIP_NAME\"|url=\"$GITHUB_ZIP_URL\"|" "$WWW_UPDATES/appcast.xml"
        echo "    Appcast URL rewritten to: $GITHUB_ZIP_URL"
    fi
else
    echo "    gh CLI not found — skipping GitHub release."
fi

# ── Summary ──────────────────────────────────────────────────────
echo ""
echo "Done!"
echo "  DMG:      $DMG_PATH ($(ls -lh "$DMG_PATH" | awk '{print $5}'))"
echo "  ZIP:      $ZIP_PATH (for Sparkle auto-update)"
echo "  Version:  $VERSION (build $BUILD_NUM)"
echo "  Arch:     $ARCHS"
if [ -n "$IDENTITY" ]; then
    echo "  Signed:   $IDENTITY"
fi
echo "  Notarized: $NOTARIZED"
echo ""
if [ -d "$WWW_UPDATES" ]; then
    echo "Next: cd ../www && git add -A && git commit -m \"${APP_NAME} $VERSION build $BUILD_NUM\" && git push"
fi
