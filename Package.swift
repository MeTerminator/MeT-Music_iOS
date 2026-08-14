// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeT-Music-iOS",
    platforms: [.iOS(.v17), .macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MeTMusic",
            path: "MeTMusic",
            exclude: ["Info.plist", "Assets.xcassets"]
        ),
        .testTarget(name: "MeTMusicTests", dependencies: ["MeTMusic"])
    ]
)
