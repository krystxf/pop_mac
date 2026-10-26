// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PopMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PopMac", targets: ["PopMac"]),
        .library(name: "PopCore", targets: ["PopCore"]),
    ],
    targets: [
        .target(name: "PopCore"),
        .executableTarget(
            name: "PopMac",
            dependencies: ["PopCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(name: "PopCoreTests", dependencies: ["PopCore"]),
    ],
    swiftLanguageModes: [.v5]
)
