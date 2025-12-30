// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftStaticAnalysis",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        // Unified library (re-exports all components)
        .library(
            name: "SwiftStaticAnalysis",
            targets: ["SwiftStaticAnalysis"]
        ),
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

        // Build plugin (runs on every build with Xcode reporting)
        .plugin(
            name: "StaticAnalysisBuildPlugin",
            targets: ["StaticAnalysisBuildPlugin"]
        ),

        // Command plugin for on-demand analysis
        .plugin(
            name: "StaticAnalysisCommandPlugin",
            targets: ["StaticAnalysisCommandPlugin"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/swiftlang/indexstore-db.git", branch: "main"),
        .package(url: "https://github.com/g-cqd/SwiftProjectKit.git", from: "0.0.12"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.4.3"),
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
            ],
            plugins: [
                .plugin(name: "SwiftLintBuildPlugin", package: "SwiftProjectKit"),
                .plugin(name: "SwiftFormatBuildPlugin", package: "SwiftProjectKit"),
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
            ],
            plugins: [
                .plugin(name: "SwiftLintBuildPlugin", package: "SwiftProjectKit"),
                .plugin(name: "SwiftFormatBuildPlugin", package: "SwiftProjectKit"),
            ]
        ),

        // MARK: - Unused Code Detection
        .target(
            name: "UnusedCodeDetector",
            dependencies: [
                "SwiftStaticAnalysisCore",
                .product(name: "IndexStoreDB", package: "indexstore-db"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
            ],
            plugins: [
                .plugin(name: "SwiftLintBuildPlugin", package: "SwiftProjectKit"),
                .plugin(name: "SwiftFormatBuildPlugin", package: "SwiftProjectKit"),
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
            ],
            plugins: [
                .plugin(name: "SwiftLintBuildPlugin", package: "SwiftProjectKit"),
                .plugin(name: "SwiftFormatBuildPlugin", package: "SwiftProjectKit"),
            ]
        ),

        // MARK: - Plugins

        .plugin(
            name: "StaticAnalysisBuildPlugin",
            capability: .buildTool(),
            dependencies: ["SwiftStaticAnalysisCLI"]
        ),

        .plugin(
            name: "StaticAnalysisCommandPlugin",
            capability: .command(
                intent: .custom(
                    verb: "analyze",
                    description: "Run static analysis to find unused code and duplications"
                ),
                permissions: []
            ),
            dependencies: ["SwiftStaticAnalysisCLI"]
        ),

        // MARK: - Unified Module (re-exports all components)
        .target(
            name: "SwiftStaticAnalysis",
            dependencies: [
                "SwiftStaticAnalysisCore",
                "DuplicationDetector",
                "UnusedCodeDetector",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
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
