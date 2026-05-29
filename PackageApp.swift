import Foundation

let projectName = "Glint"
let bundleIdentifier = "com.glint.app"
let buildDir = "build"
let appName = "\(projectName).app"
let dmgName = "\(projectName).dmg"

@discardableResult
func shell(_ args: String...) -> Int32 {
    let task = Process()
    task.launchPath = "/usr/bin/env"
    task.arguments = args
    task.launch()
    task.waitUntilExit()
    return task.terminationStatus
}

print("🚀 Starting Simplified Build Process (dmgbuild)...")

// 1. Clean and Create Build Directory
let fm = FileManager.default
try? fm.removeItem(atPath: buildDir)
try? fm.createDirectory(atPath: buildDir, withIntermediateDirectories: true)

// 2. Build Universal Binary
print("🔨 Building Universal Binary (arm64 + x86_64)...")
let buildStatus = shell("swift", "build", "-c", "release", "--arch", "arm64", "--arch", "x86_64")
guard buildStatus == 0 else { exit(1) }

// 3. Setup .app Structure
print("🏗 Creating .app structure...")
let appPath = "\(buildDir)/\(appName)"
let contentsPath = "\(appPath)/Contents"
let macosPath = "\(contentsPath)/MacOS"
let resourcesPath = "\(contentsPath)/Resources"

try fm.createDirectory(atPath: macosPath, withIntermediateDirectories: true)
try fm.createDirectory(atPath: resourcesPath, withIntermediateDirectories: true)

// 4. Copy Binary
let binarySource = ".build/apple/Products/Release/\(projectName)"
try fm.copyItem(atPath: binarySource, toPath: "\(macosPath)/\(projectName)")
shell("chmod", "+x", "\(macosPath)/\(projectName)")

// 5. Copy Info.plist
try fm.copyItem(atPath: "Sources/Glint/Info.plist", toPath: "\(contentsPath)/Info.plist")

// 6. Generate Native .icns
print("🎨 Generating AppIcon.icns...")
let iconsetPath = "\(buildDir)/AppIcon.iconset"
try? fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)
let sourceLogo = "Sources/Glint/Assets.xcassets/AppIcon.appiconset/app_icon_512x512_2x.png"

shell("sips", "-z", "16", "16", sourceLogo, "--out", "\(iconsetPath)/icon_16x16.png")
shell("sips", "-z", "32", "32", sourceLogo, "--out", "\(iconsetPath)/icon_16x16@2x.png")
shell("sips", "-z", "32", "32", sourceLogo, "--out", "\(iconsetPath)/icon_32x32.png")
shell("sips", "-z", "64", "64", sourceLogo, "--out", "\(iconsetPath)/icon_32x32@2x.png")
shell("sips", "-z", "128", "128", sourceLogo, "--out", "\(iconsetPath)/icon_128x128.png")
shell("sips", "-z", "256", "256", sourceLogo, "--out", "\(iconsetPath)/icon_128x128@2x.png")
shell("sips", "-z", "256", "256", sourceLogo, "--out", "\(iconsetPath)/icon_256x256.png")
shell("sips", "-z", "512", "512", sourceLogo, "--out", "\(iconsetPath)/icon_256x256@2x.png")
shell("sips", "-z", "512", "512", sourceLogo, "--out", "\(iconsetPath)/icon_512x512.png")
try? fm.copyItem(atPath: sourceLogo, toPath: "\(iconsetPath)/icon_512x512@2x.png")
shell("iconutil", "-c", "icns", iconsetPath, "-o", "\(resourcesPath)/AppIcon.icns")

// 7. Copy Resource Bundle
let releaseProducts = ".build/apple/Products/Release"
if let items = try? fm.contentsOfDirectory(atPath: releaseProducts) {
    for item in items where item.hasSuffix(".bundle") {
        let bundlePath = "\(resourcesPath)/\(item)"
        try? fm.copyItem(atPath: "\(releaseProducts)/\(item)", toPath: bundlePath)
        let innerAssets = "\(bundlePath)/Contents/Resources/Assets.car"
        if fm.fileExists(atPath: innerAssets) {
            try? fm.copyItem(atPath: innerAssets, toPath: "\(resourcesPath)/Assets.car")
        }
    }
}

// 7b. Copy loose MenuBarIcon images to root resources for direct lookup
let menuBarSourceDir = "Sources/Glint/Assets.xcassets/MenuBarIcon.imageset"
try? fm.copyItem(atPath: "\(menuBarSourceDir)/menubar_icon.png", toPath: "\(resourcesPath)/MenuBarIcon.png")
try? fm.copyItem(atPath: "\(menuBarSourceDir)/menubar_icon@2x.png", toPath: "\(resourcesPath)/MenuBarIcon@2x.png")
try? fm.copyItem(atPath: "\(menuBarSourceDir)/menubar_icon@3x.png", toPath: "\(resourcesPath)/MenuBarIcon@3x.png")


// 8. Create PkgInfo & Ad-hoc signing
try "APPL????".write(toFile: "\(contentsPath)/PkgInfo", atomically: true, encoding: .utf8)
print("✍️  Ad-hoc signing...")
shell("codesign", "--force", "--deep", "--sign", "-", appPath)

// 9. PROFESSIONAL DMG (Raycast Style) via dmgbuild
print("📦 Packaging into Professional DMG (dmgbuild)...")

let currentDir = fm.currentDirectoryPath
let dmgSettings = """
import os.path

filename = '\(dmgName)'
volume_name = '\(projectName) Installer'
format = 'UDZO'

# Icon size
icon_size = 128

# Positioning [x, y]
icon_locations = {
    '\(appName)': (140, 160),
    'Applications': (340, 160)
}

# Window properties
window_rect = ((600, 200), (480, 320))

default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar_view = False
show_sidebar = False

# Symlinks
symlinks = { 'Applications': '/Applications' }

# Files to include
files = [ '\(appPath)' ]
"""

let settingsFile = "\(buildDir)/dmg_settings.py"
try? dmgSettings.write(toFile: settingsFile, atomically: true, encoding: .utf8)

try? fm.removeItem(atPath: dmgName)
print("🔨 Building DMG with dmgbuild...")
// Check for uvx in PATH or common locations
func findExecutable(_ name: String) -> String? {
    let process = Process()
    process.launchPath = "/usr/bin/which"
    process.arguments = [name]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.launch()
    process.waitUntilExit()
    if process.terminationStatus == 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
}

let uvxPath = findExecutable("uvx")
let localVenvPath = "./venv/bin/dmgbuild"
let systemPath = findExecutable("dmgbuild")

if let uvx = uvxPath {
    print("✨ Using uvx to run dmgbuild...")
    shell(uvx, "--with", "dmgbuild", "dmgbuild", "-s", settingsFile, projectName, dmgName)
} else if fm.fileExists(atPath: localVenvPath) {
    print("📦 Using local venv for dmgbuild...")
    shell(localVenvPath, "-s", settingsFile, projectName, dmgName)
} else if let systemDmgbuild = systemPath {
    print("🌐 Using system dmgbuild...")
    shell(systemDmgbuild, "-s", settingsFile, projectName, dmgName)
} else {
    print("❌ Error: dmgbuild not found. Please install it or 'uv'.")
    exit(1)
}

// 10. Cleanup
try? fm.removeItem(atPath: iconsetPath)
try? fm.removeItem(atPath: settingsFile)

print("🎉 Success! \(dmgName) is ready with a CLEAN NATIVE LAYOUT.")
