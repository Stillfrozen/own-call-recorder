// swift-tools-version: 5.9
import Foundation
import PackageDescription

let infoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/OwnRecorder/Info.plist")
    .path

let package = Package(
    name: "OwnRecorder",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OwnRecorder",
            path: "Sources/OwnRecorder",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker",
                    infoPlist,
                ], .when(platforms: [.macOS])),
            ]
        ),
    ]
)
