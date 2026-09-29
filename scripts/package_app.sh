#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
BUILD_DIRECTORY="$PROJECT_DIRECTORY/.build/distribution"
APP_BUNDLE="$BUILD_DIRECTORY/IPPhone.app"
ARCHIVE_PATH="$BUILD_DIRECTORY/IPPhoneApp-0.1.0.zip"
DSYM_PATH="$BUILD_DIRECTORY/IPPhoneApp.dSYM"
CONTENTS_DIRECTORY="$APP_BUNDLE/Contents"
MACOS_DIRECTORY="$CONTENTS_DIRECTORY/MacOS"
FRAMEWORKS_DIRECTORY="$CONTENTS_DIRECTORY/Frameworks"
RESOURCES_DIRECTORY="$CONTENTS_DIRECTORY/Resources"
OPENSSL_PREFIX="/opt/homebrew/opt/openssl@4"
OPENSSL_CELLAR="$(realpath "$OPENSSL_PREFIX")"

cd "$PROJECT_DIRECTORY"
swift build -c release --disable-sandbox

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIRECTORY" "$FRAMEWORKS_DIRECTORY" "$RESOURCES_DIRECTORY/Licenses"

install -m 755 ".build/release/IPPhoneApp" "$MACOS_DIRECTORY/IPPhoneApp"
install -m 644 "Distribution/Info.plist" "$CONTENTS_DIRECTORY/Info.plist"
install -m 644 "Distribution/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIRECTORY/THIRD_PARTY_NOTICES.md"
install -m 644 "$OPENSSL_PREFIX/lib/libssl.4.dylib" "$FRAMEWORKS_DIRECTORY/libssl.4.dylib"
install -m 644 "$OPENSSL_PREFIX/lib/libcrypto.4.dylib" "$FRAMEWORKS_DIRECTORY/libcrypto.4.dylib"
install -m 644 "/opt/homebrew/opt/pjproject/COPYING" "$RESOURCES_DIRECTORY/Licenses/PJSIP-COPYING.txt"
install -m 644 "/opt/homebrew/opt/openssl@4/LICENSE.txt" "$RESOURCES_DIRECTORY/Licenses/OpenSSL-LICENSE.txt"

codesign --remove-signature "$FRAMEWORKS_DIRECTORY/libssl.4.dylib"
codesign --remove-signature "$FRAMEWORKS_DIRECTORY/libcrypto.4.dylib"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIRECTORY/IPPhoneApp"
install_name_tool -change \
    "/opt/homebrew/opt/openssl@4/lib/libssl.4.dylib" \
    "@rpath/libssl.4.dylib" \
    "$MACOS_DIRECTORY/IPPhoneApp"
install_name_tool -change \
    "/opt/homebrew/opt/openssl@4/lib/libcrypto.4.dylib" \
    "@rpath/libcrypto.4.dylib" \
    "$MACOS_DIRECTORY/IPPhoneApp"
install_name_tool -id "@rpath/libssl.4.dylib" "$FRAMEWORKS_DIRECTORY/libssl.4.dylib"
install_name_tool -change \
    "$OPENSSL_CELLAR/lib/libcrypto.4.dylib" \
    "@rpath/libcrypto.4.dylib" \
    "$FRAMEWORKS_DIRECTORY/libssl.4.dylib"
install_name_tool -id "@rpath/libcrypto.4.dylib" "$FRAMEWORKS_DIRECTORY/libcrypto.4.dylib"

plutil -lint "$CONTENTS_DIRECTORY/Info.plist"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

ARCHITECTURE="$(file "$MACOS_DIRECTORY/IPPhoneApp")"
if [[ "$ARCHITECTURE" != *"arm64"* ]]; then
    echo "Unexpected executable architecture: $ARCHITECTURE" >&2
    exit 1
fi
DEPENDENCIES="$(otool -L "$MACOS_DIRECTORY/IPPhoneApp" "$FRAMEWORKS_DIRECTORY/libssl.4.dylib" "$FRAMEWORKS_DIRECTORY/libcrypto.4.dylib")"
if [[ "$DEPENDENCIES" == *"/opt/homebrew"* ]]; then
    echo "The application still contains a Homebrew runtime dependency." >&2
    exit 1
fi

rm -rf "$DSYM_PATH"
ditto ".build/release/IPPhoneApp.dSYM" "$DSYM_PATH"
rm -f "$ARCHIVE_PATH"
ditto --norsrc --noextattr --noqtn --noacl -c -k --keepParent "$APP_BUNDLE" "$ARCHIVE_PATH"

echo "Created $APP_BUNDLE"
echo "Created $ARCHIVE_PATH"
echo "Created $DSYM_PATH"
