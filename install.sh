#!/bin/bash
set -e
echo "🚀 Building and Installing Glint..."
cd "$(dirname "$0")"

PROJECT_NAME="Glint"
APP_NAME="$PROJECT_NAME.app"

# 1. Create Iconset and AppIcon.icns from existing asset
echo "🎨 Generating AppIcon.icns..."
SOURCE_ICON="Sources/Glint/Assets.xcassets/AppIcon.appiconset/app_icon_512x512_2x.png"

mkdir -p "$PROJECT_NAME.iconset"
sips -z 16 16     "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_16x16.png" > /dev/null 2>&1
sips -z 32 32     "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_16x16@2x.png" > /dev/null 2>&1
sips -z 32 32     "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_32x32.png" > /dev/null 2>&1
sips -z 64 64     "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_32x32@2x.png" > /dev/null 2>&1
sips -z 128 128   "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_128x128.png" > /dev/null 2>&1
sips -z 256 256   "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_128x128@2x.png" > /dev/null 2>&1
sips -z 256 256   "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_256x256.png" > /dev/null 2>&1
sips -z 512 512   "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_256x256@2x.png" > /dev/null 2>&1
sips -z 512 512   "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_512x512.png" > /dev/null 2>&1
sips -z 1024 1024 "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_512x512@2x.png" > /dev/null 2>&1
iconutil -c icns "$PROJECT_NAME.iconset" -o AppIcon.icns

# 2. Build Release
echo "🔨 Compiling release binary..."
swift build -c release --arch arm64

# 3. Assemble .app bundle
echo "🏗️ Assembling app bundle..."
rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"

BINARY_PATH=$(find .build -name "$PROJECT_NAME" -type f | grep "release" | head -n 1)
cp "$BINARY_PATH" "$APP_NAME/Contents/MacOS/"
chmod +x "$APP_NAME/Contents/MacOS/$PROJECT_NAME"
cp Sources/Glint/Info.plist "$APP_NAME/Contents/"
cp AppIcon.icns "$APP_NAME/Contents/Resources/"

# 4. Create PkgInfo
echo "APPL????" > "$APP_NAME/Contents/PkgInfo"

# 5. Copy Asset Catalog bundle (includes MenuBarIcon)
release_dir=".build/apple/Products/Release"
if [ -d "$release_dir/Glint_Glint.bundle" ]; then
    cp -R "$release_dir/Glint_Glint.bundle" "$APP_NAME/Contents/Resources/"
fi

# 6. Ad-hoc code signing
echo "✍️  Ad-hoc signing..."
codesign --force --deep --sign - "$APP_NAME"

# 7. Install to /Applications
echo "🚚 Installing to /Applications..."
rm -rf "/Applications/$APP_NAME"
mv "$APP_NAME" /Applications/

# 8. Cleanup
rm -rf AppIcon.icns "$PROJECT_NAME.iconset"

echo "✅ Glint installed successfully in /Applications!"
