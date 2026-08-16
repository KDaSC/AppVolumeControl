#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/outputs"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$OUTPUT_DIR/AppVolumeControl.app"
ARCHIVE_PATH="$OUTPUT_DIR/AppVolumeControl.zip"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"
SIGNING_IDENTITY="${APP_VOLUME_SIGNING_IDENTITY:-}"
VERSION="0.6.0"
BUILD_NUMBER="7"
STAGING_DIR="$(mktemp -d)"
STAGED_APP_DIR="$STAGING_DIR/AppVolumeControl.app"
VERIFY_DIR=""

cleanup() {
	if [[ -n "$VERIFY_DIR" ]]; then
		rm -rf "$VERIFY_DIR"
	fi
	rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if [[ -z "$SIGNING_IDENTITY" ]]; then
	SIGNING_IDENTITY="-"
	print -u2 "Warning: using ad-hoc signing; system-audio capture permission may need to be granted again after each rebuild. Set APP_VOLUME_SIGNING_IDENTITY to a stable identity for persistent permission."
fi

cd "$ROOT_DIR"
swift build -c release

BINARY_ARCHS="$(lipo -archs "$BUILD_DIR/AppVolumeControl")"
if [[ "$BINARY_ARCHS" != "arm64" ]]; then
	print -u2 "Error: expected an arm64 release binary, got: $BINARY_ARCHS"
	exit 1
fi

mkdir -p "$STAGED_APP_DIR/Contents/MacOS" "$STAGED_APP_DIR/Contents/Resources"
cp "$BUILD_DIR/AppVolumeControl" "$STAGED_APP_DIR/Contents/MacOS/AppVolumeControl"
chmod +x "$STAGED_APP_DIR/Contents/MacOS/AppVolumeControl"

cat > "$STAGED_APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>应用音量</string>
	<key>CFBundleExecutable</key>
	<string>AppVolumeControl</string>
	<key>CFBundleIdentifier</key>
	<string>com.codex.app-volume-control</string>
	<key>CFBundleName</key>
	<string>AppVolumeControl</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUMBER}</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>18.0</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>用于在用户授权后对应用音频施加独立输出增益，不改变系统总音量。</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# Finder may add metadata xattrs to app bundles copied through the desktop.
# Remove them before signing so Dock/LaunchServices sees a clean bundle.
xattr -cr "$STAGED_APP_DIR" 2>/dev/null || true
codesign --force --sign "$SIGNING_IDENTITY" "$STAGED_APP_DIR/Contents/MacOS/AppVolumeControl" >/dev/null
codesign --force --sign "$SIGNING_IDENTITY" "$STAGED_APP_DIR" >/dev/null
# The Documents file provider can attach Finder metadata to any bundle member
# after signing. Strip all attached attributes once more before verification.
xattr -cr "$STAGED_APP_DIR" 2>/dev/null || true
codesign --verify --deep --strict "$STAGED_APP_DIR"

rm -rf "$APP_DIR"
ditto --norsrc "$STAGED_APP_DIR" "$APP_DIR"
xattr -cr "$APP_DIR" 2>/dev/null || true
if ! codesign --verify --deep --strict "$APP_DIR" 2>/dev/null; then
	if xattr -p com.apple.FinderInfo "$APP_DIR" >/dev/null 2>&1; then
		print -u2 "Warning: Documents attached FinderInfo to the direct .app copy; the ZIP below is verified from a clean extraction."
	else
		print -u2 "Error: final app signature verification failed for a reason other than FinderInfo."
		exit 1
	fi
fi
rm -f "$ARCHIVE_PATH"
(
	cd "$STAGING_DIR"
	/usr/bin/zip -qry -X "$ARCHIVE_PATH" "AppVolumeControl.app"
)
unzip -t "$ARCHIVE_PATH" >/dev/null
VERIFY_DIR="$(mktemp -d)"
/usr/bin/unzip -q "$ARCHIVE_PATH" -d "$VERIFY_DIR"
codesign --verify --deep --strict "$VERIFY_DIR/AppVolumeControl.app"
shasum -a 256 "$ARCHIVE_PATH" > "$CHECKSUM_PATH"

echo "Built: $APP_DIR"
echo "Archive: $ARCHIVE_PATH"
echo "Checksum: $CHECKSUM_PATH"
