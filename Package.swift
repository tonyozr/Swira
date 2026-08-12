// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Swira",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SwiraCore", targets: ["SwiraCore"]),
        .executable(name: "swira-probe", targets: ["swira-probe"]),
        .executable(name: "swira-web", targets: ["swira-web"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "SwiraCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .executableTarget(
            name: "swira-probe",
            dependencies: [
                "SwiraCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "swira-web",
            dependencies: [
                "SwiraCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "SwiraCoreTests",
            dependencies: ["SwiraCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
