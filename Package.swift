// swift-tools-version:6.4
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
        // The end-to-end tests run the PopMac binary against the windows of PopTestApp.
        .executableTarget(name: "PopTestApp", path: "Tests/PopTestApp"),
        .testTarget(name: "PopE2ETests", dependencies: ["PopCore"]),
    ],
    swiftLanguageModes: [.v6]
)
