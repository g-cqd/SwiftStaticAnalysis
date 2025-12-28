// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftStaticAnalysis",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        // Core library for parsing and analysis infrastructure
        .library(
            name: "SwiftStaticAnalysisCore",
            targets: ["SwiftStaticAnalysisCore"]
        ),
        // Duplication detection module
        .library(
            name: "DuplicationDetector",
            targets: ["DuplicationDetector"]
        ),
        // Unused code detection module
        .library(
            name: "UnusedCodeDetector",
            targets: ["UnusedCodeDetector"]
        ),
        // CLI tool
        .executable(
            name: "swa",
            targets: ["SwiftStaticAnalysisCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // MARK: - Core Infrastructure
        .target(
            name: "SwiftStaticAnalysisCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        // MARK: - Duplication Detection
        .target(
            name: "DuplicationDetector",
            dependencies: [
                "SwiftStaticAnalysisCore",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        // MARK: - Unused Code Detection
        .target(
            name: "UnusedCodeDetector",
            dependencies: [
                "SwiftStaticAnalysisCore",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        // MARK: - CLI Tool
        .executableTarget(
            name: "SwiftStaticAnalysisCLI",
            dependencies: [
                "SwiftStaticAnalysisCore",
                "DuplicationDetector",
                "UnusedCodeDetector",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        // MARK: - Tests
        .testTarget(
            name: "SwiftStaticAnalysisCoreTests",
            dependencies: ["SwiftStaticAnalysisCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DuplicationDetectorTests",
            dependencies: ["DuplicationDetector"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "UnusedCodeDetectorTests",
            dependencies: ["UnusedCodeDetector"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
