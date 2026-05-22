#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
APP_NAME="VPinballX_BGFX"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
VERSION=$(defaults read "$APP_BUNDLE/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "10.8.1")
DMG_NAME="VPinballX-${VERSION}-macOS"
DMG_PATH="$BUILD_DIR/$DMG_NAME.dmg"
STAGING_DIR="$BUILD_DIR/dmg-staging"

usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  build       Build the project (Release)"
    echo "  sign        Ad-hoc code sign the app bundle"
    echo "  sign-dev    Sign with Developer ID (requires SIGNING_IDENTITY env var)"
    echo "  dmg         Create a DMG installer"
    echo "  notarize    Submit DMG for Apple notarization (requires APPLE_ID, TEAM_ID, APP_PASSWORD)"
    echo "  all         Build + sign + dmg"
    echo "  release     Build + sign-dev + dmg + notarize"
    echo ""
    exit 1
}

cmd_build() {
    echo "==> Building VPinballX (Release)..."
    cd "$PROJECT_ROOT"
    export PATH="$(brew --prefix bison)/bin:$PATH"

    if [ ! -f CMakeLists.txt ]; then
        cp make/CMakeLists_bgfx-macos-arm64.txt CMakeLists.txt
    fi

    cmake -DCMAKE_BUILD_TYPE=Release -B build
    cmake --build build -- -j"$(sysctl -n hw.ncpu)"
    echo "==> Build complete: $APP_BUNDLE"
}

cmd_sign() {
    echo "==> Ad-hoc signing $APP_NAME.app..."

    # Fix dylib install names to use @rpath
    find "$APP_BUNDLE/Contents/Frameworks" -name "*.dylib" 2>/dev/null | while read -r lib; do
        local libname
        libname=$(basename "$lib")
        install_name_tool -id "@rpath/$libname" "$lib" 2>/dev/null || true
    done

    # Sign all dylibs, .so, and .bundle in Frameworks
    find "$APP_BUNDLE/Contents/Frameworks" \( -name "*.dylib" -o -name "*.so" -o -name "*.bundle" \) 2>/dev/null | while read -r lib; do
        codesign --force --sign - "$lib"
    done

    # Sign all plugin libraries
    find "$APP_BUNDLE/Contents/Resources/plugins" \( -name "*.dylib" -o -name "*.so" -o -name "*.bundle" \) 2>/dev/null | while read -r lib; do
        codesign --force --sign - "$lib"
    done

    # Sign Quick Look extension
    find "$APP_BUNDLE/Contents/PlugIns" -name "*.appex" 2>/dev/null | while read -r appex; do
        codesign --force --sign - "$appex"
    done

    # Sign the main executable
    codesign --force --sign - --entitlements /dev/stdin "$APP_BUNDLE" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

    echo "==> Ad-hoc signing complete"
}

cmd_sign_dev() {
    if [ -z "${SIGNING_IDENTITY:-}" ]; then
        echo "Error: Set SIGNING_IDENTITY to your Developer ID Application certificate name"
        echo "  e.g. SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'"
        exit 1
    fi

    echo "==> Signing with: $SIGNING_IDENTITY"

    # Fix dylib install names to use @rpath
    find "$APP_BUNDLE/Contents/Frameworks" -name "*.dylib" 2>/dev/null | while read -r lib; do
        local libname
        libname=$(basename "$lib")
        install_name_tool -id "@rpath/$libname" "$lib" 2>/dev/null || true
    done

    find "$APP_BUNDLE/Contents/Frameworks" \( -name "*.dylib" -o -name "*.so" -o -name "*.bundle" \) 2>/dev/null | while read -r lib; do
        codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$lib"
    done

    find "$APP_BUNDLE/Contents/Resources/plugins" \( -name "*.dylib" -o -name "*.so" -o -name "*.bundle" \) 2>/dev/null | while read -r lib; do
        codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$lib"
    done

    # Sign Quick Look extension
    find "$APP_BUNDLE/Contents/PlugIns" -name "*.appex" 2>/dev/null | while read -r appex; do
        codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$appex"
    done

    codesign --force --options runtime --sign "$SIGNING_IDENTITY" \
        --entitlements /dev/stdin "$APP_BUNDLE" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

    echo "==> Developer signing complete"
    codesign --verify --deep --strict "$APP_BUNDLE" && echo "==> Signature verified OK"
}

cmd_dmg() {
    echo "==> Creating DMG..."

    # Clean up previous staging
    rm -rf "$STAGING_DIR"
    rm -f "$DMG_PATH"
    mkdir -p "$STAGING_DIR"

    # Copy app bundle
    cp -R "$APP_BUNDLE" "$STAGING_DIR/"

    # Create Applications symlink
    ln -s /Applications "$STAGING_DIR/Applications"

    # Create a README
    cat > "$STAGING_DIR/README.txt" <<'README'
VPinballX for macOS
===================

Installation:
  Drag VPinballX_BGFX.app to the Applications folder.

Getting Started:
  1. Launch VPinballX from Applications
  2. Open a .vpx table file (Cmd+O or drag onto the app icon)
  3. Use Left/Right Shift for flippers, Enter to launch ball
  4. Press F12 for in-game settings, F11 for FPS overlay
  5. Press Escape to exit a table

Tables:
  Download tables from https://www.vpforums.org

More Info:
  https://github.com/vpinball/vpinball
README

    # Create DMG
    hdiutil create -volname "$DMG_NAME" \
        -srcfolder "$STAGING_DIR" \
        -ov -format UDZO \
        -imagekey zlib-level=9 \
        "$DMG_PATH"

    rm -rf "$STAGING_DIR"

    local size
    size=$(du -sh "$DMG_PATH" | cut -f1)
    echo "==> DMG created: $DMG_PATH ($size)"
}

cmd_notarize() {
    if [ -z "${APPLE_ID:-}" ] || [ -z "${TEAM_ID:-}" ] || [ -z "${APP_PASSWORD:-}" ]; then
        echo "Error: Set APPLE_ID, TEAM_ID, and APP_PASSWORD environment variables"
        echo "  APPLE_ID      - Your Apple ID email"
        echo "  TEAM_ID       - Your Team ID"
        echo "  APP_PASSWORD  - App-specific password from appleid.apple.com"
        exit 1
    fi

    if [ ! -f "$DMG_PATH" ]; then
        echo "Error: DMG not found at $DMG_PATH. Run 'dmg' first."
        exit 1
    fi

    echo "==> Submitting for notarization..."
    local notarize_output
    notarize_output=$(xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait 2>&1)
    echo "$notarize_output"

    if echo "$notarize_output" | grep -q "status: Invalid"; then
        echo "Error: Notarization failed. Check the log above for details."
        local submission_id
        submission_id=$(echo "$notarize_output" | grep -oE 'id: [0-9a-f-]+' | head -1 | cut -d' ' -f2)
        if [ -n "$submission_id" ]; then
            echo "==> Fetching notarization log..."
            xcrun notarytool log "$submission_id" \
                --apple-id "$APPLE_ID" \
                --team-id "$TEAM_ID" \
                --password "$APP_PASSWORD"
        fi
        exit 1
    fi

    echo "==> Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"

    echo "==> Notarization complete"
}

cmd_all() {
    cmd_build
    cmd_sign
    cmd_dmg
}

cmd_release() {
    cmd_build
    cmd_sign_dev
    cmd_dmg
    cmd_notarize
}

case "${1:-}" in
    build)     cmd_build ;;
    sign)      cmd_sign ;;
    sign-dev)  cmd_sign_dev ;;
    dmg)       cmd_dmg ;;
    notarize)  cmd_notarize ;;
    all)       cmd_all ;;
    release)   cmd_release ;;
    *)         usage ;;
esac
