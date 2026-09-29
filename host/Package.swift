// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "JumpHost",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "153.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "JumpHost",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ]
)
