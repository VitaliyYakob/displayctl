// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "displayctl",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "displayctl", targets: ["displayctl"])
    ],
    targets: [
        .executableTarget(
            name: "displayctl",
            path: "App/displayctl",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
