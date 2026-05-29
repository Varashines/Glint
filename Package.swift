// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Glint",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Glint", targets: ["Glint"])
    ],
    targets: [
        .executableTarget(
            name: "Glint",
            exclude: ["Info.plist"],
            resources: [
                .process("Assets.xcassets")
            ]
        )
    ]
)
