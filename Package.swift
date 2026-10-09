// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FakeMe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FakeMeCore", targets: ["FakeMeCore"]),
        .executable(name: "FakeMe", targets: ["FakeMeApp"]),
        .executable(name: "FakeMeExtension", targets: ["FakeMeCameraExtension"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "FakeMeCBridge",
            dependencies: [],
            path: "Sources/FakeMeCBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "FakeMeCore",
            dependencies: ["FakeMeCBridge"],
            path: "Sources/FakeMeCore"
        ),
        .target(
            name: "FakeMeUI",
            dependencies: ["FakeMeCore"],
            path: "Sources/FakeMeUI",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("Cocoa")
            ]
        ),
        .executableTarget(
            name: "FakeMeApp",
            dependencies: ["FakeMeCore", "FakeMeUI"],
            path: "Sources/FakeMeApp"
        ),
        .executableTarget(
            name: "FakeMeCameraExtension",
            dependencies: [],
            path: "Sources/FakeMeCameraExtension"
        ),
        .testTarget(
            name: "FakeMeCoreTests",
            dependencies: ["FakeMeCore"],
            path: "Tests/FakeMeCoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
