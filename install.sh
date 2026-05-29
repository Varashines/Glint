#!/bin/bash
set -e

PROJECT_NAME="Glint"
APP_NAME="$PROJECT_NAME.app"

echo "🚀 Building and Installing Glint locally..."
cd "$(dirname "$0")"

# 1. Compile native binary
echo "🔨 Compiling release binary..."
swift build -c release

# 2. Locate built artifacts
BINARY_PATH=$(find .build -name "$PROJECT_NAME" -type f | grep "release" | head -n 1)
BUNDLE_PATH=$(find .build -name "${PROJECT_NAME}_${PROJECT_NAME}.bundle" -type d | grep "release" | head -n 1)

if [ -z "$BINARY_PATH" ]; then
    echo "❌ Error: Could not find compiled binary."
    exit 1
fi

# 3. Assemble .app bundle structure
echo "🏗️ Assembling app bundle..."
rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"

cp "$BINARY_PATH" "$APP_NAME/Contents/MacOS/"
chmod +x "$APP_NAME/Contents/MacOS/$PROJECT_NAME"
cp Sources/Glint/Info.plist "$APP_NAME/Contents/"

# 4. Create PkgInfo
echo "APPL????" > "$APP_NAME/Contents/PkgInfo"

# 5. Generate AppIcon.icns
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
iconutil -c icns "$PROJECT_NAME.iconset" -o "$APP_NAME/Contents/Resources/AppIcon.icns"
rm -rf "$PROJECT_NAME.iconset"

# 6. Copy Resource Bundle and extract Assets.car for the menu bar icon
if [ -d "$BUNDLE_PATH" ]; then
    echo "📦 Packaging resources..."
    cp -R "$BUNDLE_PATH" "$APP_NAME/Contents/Resources/"
    
    # Extract Assets.car to root resources so NSImage(named:) can resolve MenuBarIcon
    if [ -f "$BUNDLE_PATH/Contents/Resources/Assets.car" ]; then
        cp "$BUNDLE_PATH/Contents/Resources/Assets.car" "$APP_NAME/Contents/Resources/"
    fi
fi

# Copy loose menubar icon files as fallback/direct asset resolution (renaming to camelCase)
echo "🎨 Copying MenuBarIcon files..."
cp Sources/Glint/Assets.xcassets/MenuBarIcon.imageset/menubar_icon.png "$APP_NAME/Contents/Resources/MenuBarIcon.png"
cp Sources/Glint/Assets.xcassets/MenuBarIcon.imageset/menubar_icon@2x.png "$APP_NAME/Contents/Resources/MenuBarIcon@2x.png"
cp Sources/Glint/Assets.xcassets/MenuBarIcon.imageset/menubar_icon@3x.png "$APP_NAME/Contents/Resources/MenuBarIcon@3x.png"


# 7. Ad-hoc code signing
echo "✍️  Ad-hoc signing..."
codesign --force --deep --sign - "$APP_NAME"

# 8. Install to /Applications
echo "🚚 Installing to /Applications..."
rm -rf "/Applications/$APP_NAME"
mv "$APP_NAME" /Applications/

echo "✅ Glint successfully installed to /Applications with all assets configured!"
