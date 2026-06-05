// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CamOrderStudio",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CamOrderStudioCore",
            targets: ["CamOrderStudioCore"]
        ),
        .executable(
            name: "CamOrderStudio",
            targets: ["CamOrderStudioApp"]
        )
    ],
    targets: [
        .target(
            name: "CamOrderStudioCore",
            dependencies: []
        ),
        .executableTarget(
            name: "CamOrderStudioApp",
            dependencies: ["CamOrderStudioCore"]
        ),
        .testTarget(
            name: "CamOrderStudioCoreTests",
            dependencies: ["CamOrderStudioCore"]
        )
    ]
)
