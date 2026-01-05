// swift-tools-version: 6.2
//  Package.swift
//  SwiftStaticAnalysis
//  MIT License

import PackageDescription

let package = Package(
    name: "SwiftStaticAnalysis",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
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
        // Symbol lookup and actor isolation analysis
        .library(
            name: "SymbolLookup",
            targets: ["SymbolLookup"]
        ),
        // CLI tool
        .executable(
            name: "swa",
            targets: ["swa"]
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
        .package(
            url: "https://github.com/swiftlang/indexstore-db.git", revision: "cb3b960568f18a3cc018923f5824323b5c4edd0b"),
        .package(url: "https://github.com/swiftlang/swift-format.git", from: "602.0.0"),
        .package(url: "https://github.com/g-cqd/SwiftProjectKit.git", from: "0.0.21"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.4.3"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", .upToNextMajor(from: "1.1.1")),
        .package(url: "https://github.com/apple/swift-algorithms.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", .upToNextMajor(from: "1.3.0")),
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMajor(from: "1.3.0")),
    ],
    targets: [
        // MARK: - Core Infrastructure
        .target(
            name: "SwiftStaticAnalysisCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Algorithms", package: "swift-algorithms"),
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
                "UnusedCodeDetector",  // For AtomicBitmap, Bitmap
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
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
                .product(name: "IndexStoreDB", package: "indexstore-db"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        // MARK: - Symbol Lookup
        .target(
            name: "SymbolLookup",
            dependencies: [
                "SwiftStaticAnalysisCore",
                "UnusedCodeDetector",
                .product(name: "IndexStoreDB", package: "indexstore-db"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        // MARK: - CLI Tool
        .executableTarget(
            name: "swa",
            dependencies: [
                "SwiftStaticAnalysisCore",
                "DuplicationDetector",
                "UnusedCodeDetector",
                "SymbolLookup",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        // MARK: - Plugins

        .plugin(
            name: "StaticAnalysisBuildPlugin",
            capability: .buildTool(),
            dependencies: ["swa"],
            path: "Sources/StaticAnalysisBuildPlugin"
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
            dependencies: ["swa"],
            path: "Sources/StaticAnalysisCommandPlugin"
        ),

        // MARK: - Unified Module (re-exports all components)
        .target(
            name: "SwiftStaticAnalysis",
            dependencies: [
                "SwiftStaticAnalysisCore",
                "DuplicationDetector",
                "UnusedCodeDetector",
                "SymbolLookup",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        // MARK: - Tests
        .testTarget(
            name: "SwiftStaticAnalysisCoreTests",
            dependencies: ["SwiftStaticAnalysisCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "DuplicationDetectorTests",
            dependencies: ["DuplicationDetector"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "UnusedCodeDetectorTests",
            dependencies: ["UnusedCodeDetector"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SymbolLookupTests",
            dependencies: ["SymbolLookup"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "CLITests",
            dependencies: [
                "SwiftStaticAnalysisCore",
                "DuplicationDetector",
                "UnusedCodeDetector",
                "SymbolLookup",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
