#!/bin/bash
set -e

PROJECT_NAME="Glint"
APP_NAME="$PROJECT_NAME.app"
DMG_NAME="$PROJECT_NAME.dmg"
BUILD_DIR="build"

echo "🚀 Building $PROJECT_NAME..."

# 1. Create Iconset and AppIcon.icns from existing asset
echo "🎨 Generating AppIcon.icns..."
SOURCE_ICON="Sources/Glint/Assets.xcassets/AppIcon.appiconset/app_icon_512x512_2x.png"

mkdir -p "$PROJECT_NAME.iconset"
sips -z 16 16     "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_16x16.png"
sips -z 32 32     "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_16x16@2x.png"
sips -z 32 32     "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_32x32.png"
sips -z 64 64     "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_32x32@2x.png"
sips -z 128 128   "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_128x128.png"
sips -z 256 256   "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_128x128@2x.png"
sips -z 256 256   "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_256x256.png"
sips -z 512 512   "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_256x256@2x.png"
sips -z 512 512   "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_512x512.png"
sips -z 1024 1024 "$SOURCE_ICON" --out "$PROJECT_NAME.iconset/icon_512x512@2x.png"
iconutil -c icns "$PROJECT_NAME.iconset" -o AppIcon.icns

# 2. Build Universal Binary
echo "🔨 Compiling universal binary (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64

# 3. Assemble .app bundle
echo "🏗️ Assembling app bundle..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/$APP_NAME/Contents/MacOS"
mkdir -p "$BUILD_DIR/$APP_NAME/Contents/Resources"

cp .build/apple/Products/Release/Glint "$BUILD_DIR/$APP_NAME/Contents/MacOS/"
chmod +x "$BUILD_DIR/$APP_NAME/Contents/MacOS/Glint"
cp Sources/Glint/Info.plist "$BUILD_DIR/$APP_NAME/Contents/"
cp AppIcon.icns "$BUILD_DIR/$APP_NAME/Contents/Resources/"

# 4. Create PkgInfo
echo "APPL????" > "$BUILD_DIR/$APP_NAME/Contents/PkgInfo"

# 5. Copy Asset Catalog bundle
release_dir=".build/apple/Products/Release"
if [ -d "$release_dir/Glint_Glint.bundle" ]; then
    cp -R "$release_dir/Glint_Glint.bundle" "$BUILD_DIR/$APP_NAME/Contents/Resources/"
fi

# 6. Ad-hoc code signing
echo "✍️  Ad-hoc signing..."
codesign --force --deep --sign - "$BUILD_DIR/$APP_NAME"

# 7. Create DMG
echo "📦 Packaging DMG..."
if command -v uvx > /dev/null; then
    uvx --with dmgbuild dmgbuild -s <(echo "
filename = '$DMG_NAME'
volume_name = '$PROJECT_NAME Installer'
format = 'UDZO'
icon_size = 128
icon_locations = { '$APP_NAME': (140, 160), 'Applications': (340, 160) }
window_rect = ((600, 200), (480, 320))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar_view = False
show_sidebar = False
symlinks = { 'Applications': '/Applications' }
files = [ '$BUILD_DIR/$APP_NAME' ]
") "$PROJECT_NAME" "$DMG_NAME"
else
    echo "⚠️  uvx not found, skipping DMG creation. Please install 'uv'."
fi

# 8. Cleanup
rm -rf AppIcon.icns "$PROJECT_NAME.iconset"

echo "✅ Build complete! $DMG_NAME created."
