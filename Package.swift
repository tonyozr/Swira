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
        // A flat C ABI over SwiraCore, built as a DLL on Windows. This is what SwiraWin
        // (Apps/SwiraWin, C#/WinUI) P/Invokes directly — see Sources/SwiraABI/SwiraABI.swift.
        .library(name: "SwiraABI", type: .dynamic, targets: ["SwiraABI"]),
        // Native macOS AppKit client — the canonical reference implementation (CLIENT-SPEC.md §4).
        .executable(name: "SwiraMac", targets: ["SwiraMac"]),
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
            ],
            resources: [.embedInCode("Resources/index.html")]
        ),
        .target(
            name: "SwiraABI",
            dependencies: ["SwiraCore"]
        ),
        // macOS AppKit client. macOS-only: guarded by the conditional compilation inside the
        // source files themselves. SwiftPM does not support per-target platform restrictions on
        // executables in the same way it does for libraries, so the guard lives in the code.
        .executableTarget(
            name: "SwiraMac",
            dependencies: [
                "SwiraCore",
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
