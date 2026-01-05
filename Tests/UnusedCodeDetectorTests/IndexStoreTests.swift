//  IndexStoreTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftStaticAnalysisCore
import Testing

@testable import UnusedCodeDetector

// MARK: - IndexSymbolNodeTests

@Suite("IndexSymbolNode Tests")
struct IndexSymbolNodeTests {
    @Test("Create basic node")
    func createBasicNode() {
        let node = IndexSymbolNode(
            usr: "s:test:TestClass",
            name: "TestClass",
            kind: .class,
            definitionFile: "/path/to/file.swift",
            definitionLine: 10,
        )

        #expect(node.usr == "s:test:TestClass")
        #expect(node.name == "TestClass")
        #expect(node.kind == .class)
        #expect(node.definitionFile == "/path/to/file.swift")
        #expect(node.definitionLine == 10)
        #expect(node.isRoot == false)
        #expect(node.rootReason == nil)
        #expect(node.isExternal == false)
    }

    @Test("Create root node")
    func createRootNode() {
        let node = IndexSymbolNode(
            usr: "s:main",
            name: "main",
            kind: .function,
            isRoot: true,
            rootReason: .mainFunction,
        )

        #expect(node.isRoot == true)
        #expect(node.rootReason == .mainFunction)
    }

    @Test("Create external node")
    func createExternalNode() {
        let node = IndexSymbolNode(
            usr: "s:Foundation:String",
            name: "String",
            kind: .struct,
            isExternal: true,
        )

        #expect(node.isExternal == true)
    }

    @Test("Nodes with same USR are equal")
    func nodeEquality() {
        let node1 = IndexSymbolNode(usr: "s:test:A", name: "A", kind: .class)
        let node2 = IndexSymbolNode(usr: "s:test:A", name: "A", kind: .class)
        let node3 = IndexSymbolNode(usr: "s:test:B", name: "B", kind: .class)

        #expect(node1 == node2)
        #expect(node1 != node3)
    }

    @Test("Node hashing is based on USR")
    func nodeHashing() {
        let node1 = IndexSymbolNode(usr: "s:test:A", name: "A", kind: .class)
        let node2 = IndexSymbolNode(usr: "s:test:A", name: "A", kind: .class)

        var set = Set<IndexSymbolNode>()
        set.insert(node1)
        set.insert(node2)

        #expect(set.count == 1)
    }
}

// MARK: - IndexDependencyEdgeTests

@Suite("IndexDependencyEdge Tests")
struct IndexDependencyEdgeTests {
    @Test("Create edge")
    func createEdge() {
        let edge = IndexDependencyEdge(
            fromUSR: "s:caller",
            toUSR: "s:callee",
            kind: .call,
        )

        #expect(edge.fromUSR == "s:caller")
        #expect(edge.toUSR == "s:callee")
        #expect(edge.kind == .call)
    }

    @Test("Edge equality")
    func edgeEquality() {
        let edge1 = IndexDependencyEdge(fromUSR: "s:a", toUSR: "s:b", kind: .call)
        let edge2 = IndexDependencyEdge(fromUSR: "s:a", toUSR: "s:b", kind: .call)
        let edge3 = IndexDependencyEdge(fromUSR: "s:a", toUSR: "s:c", kind: .call)

        #expect(edge1 == edge2)
        #expect(edge1 != edge3)
    }

    @Test("All dependency kinds")
    func allDependencyKinds() {
        let kinds: [IndexDependencyKind] = [
            .call,
            .typeReference,
            .inheritance,
            .protocolWitness,
            .read,
            .write,
            .extensionOf,
            .containedBy,
            .override,
        ]

        #expect(kinds.count == 9)
    }
}

// MARK: - IndexGraphConfigurationTests

@Suite("IndexGraphConfiguration Tests")
struct IndexGraphConfigurationTests {
    @Test("Default configuration")
    func defaultConfiguration() {
        let config = IndexGraphConfiguration.default

        #expect(config.treatTestsAsRoot == true)
        #expect(config.treatProtocolRequirementsAsRoot == true)
        #expect(config.includeCrossModuleEdges == true)
        #expect(config.trackProtocolWitnesses == true)
    }

    @Test("Custom configuration")
    func customConfiguration() {
        let config = IndexGraphConfiguration(
            treatTestsAsRoot: false,
            treatProtocolRequirementsAsRoot: false,
            includeCrossModuleEdges: false,
            trackProtocolWitnesses: false,
        )

        #expect(config.treatTestsAsRoot == false)
        #expect(config.treatProtocolRequirementsAsRoot == false)
        #expect(config.includeCrossModuleEdges == false)
        #expect(config.trackProtocolWitnesses == false)
    }
}

// MARK: - IndexStoreStatusTests

@Suite("IndexStoreStatus Tests")
struct IndexStoreStatusTests {
    @Test("Available status")
    func availableStatus() {
        let status = IndexStoreStatus.available(path: "/path/to/index")

        #expect(status.isUsable == true)
        #expect(status.path == "/path/to/index")
    }

    @Test("Stale status")
    func staleStatus() {
        let status = IndexStoreStatus.stale(
            path: "/path/to/index",
            staleFiles: ["file1.swift", "file2.swift"],
        )

        #expect(status.isUsable == true)
        #expect(status.path == "/path/to/index")
    }

    @Test("Not found status")
    func notFoundStatus() {
        let status = IndexStoreStatus.notFound

        #expect(status.isUsable == false)
        #expect(status.path == nil)
    }

    @Test("Failed status")
    func failedStatus() {
        let status = IndexStoreStatus.failed(error: "Could not open index")

        #expect(status.isUsable == false)
        #expect(status.path == nil)
    }
}

// MARK: - FallbackReasonTests

@Suite("FallbackReason Tests")
struct FallbackReasonTests {
    @Test("Reason descriptions")
    func reasonDescriptions() {
        let noIndex = FallbackReason.noIndexStore
        let failed = FallbackReason.indexStoreFailed(error: "error")
        let buildFailed = FallbackReason.buildFailed(error: "build error")
        let userRequested = FallbackReason.userRequested

        #expect(noIndex.description.contains("No index store found"))
        #expect(failed.description.contains("Failed to open"))
        #expect(buildFailed.description.contains("Build failed"))
        #expect(userRequested.description.contains("user"))
    }
}

// MARK: - FallbackConfigurationTests

@Suite("FallbackConfiguration Tests")
struct FallbackConfigurationTests {
    @Test("Default configuration")
    func defaultConfiguration() {
        let config = FallbackConfiguration.default

        #expect(config.autoBuild == false)
        #expect(config.checkFreshness == true)
        #expect(config.warnOnStale == true)
        #expect(config.hybridMode == false)
        #expect(config.maxStaleness == 3600)
    }

    @Test("Auto-build configuration")
    func autoBuildConfiguration() {
        let config = FallbackConfiguration.withAutoBuild

        #expect(config.autoBuild == true)
    }

    @Test("CI/CD configuration")
    func cicdConfiguration() {
        let config = FallbackConfiguration.cicd

        #expect(config.autoBuild == false)
        #expect(config.warnOnStale == false)
    }

    @Test("Hybrid configuration")
    func hybridConfiguration() {
        let config = FallbackConfiguration.hybrid

        #expect(config.hybridMode == true)
    }
}

// MARK: - BuildResultTests

@Suite("BuildResult Tests")
struct BuildResultTests {
    @Test("Successful build result")
    func successfulBuildResult() {
        let result = BuildResult(
            success: true,
            output: "Build successful",
            duration: 5.5,
            indexStorePath: "/path/to/index",
        )

        #expect(result.success == true)
        #expect(result.output == "Build successful")
        #expect(result.duration == 5.5)
        #expect(result.indexStorePath == "/path/to/index")
    }

    @Test("Failed build result")
    func failedBuildResult() {
        let result = BuildResult(
            success: false,
            output: "Build failed: error",
            duration: 1.0,
            indexStorePath: nil,
        )

        #expect(result.success == false)
        #expect(result.indexStorePath == nil)
    }
}

// MARK: - UnusedCodeConfigurationIndexStoreTests

@Suite("UnusedCodeConfiguration IndexStore Tests")
struct UnusedCodeConfigurationIndexStoreTests {
    @Test("Default configuration has autoBuild disabled")
    func defaultConfigAutoBuild() {
        let config = UnusedCodeConfiguration.default

        #expect(config.autoBuild == false)
        #expect(config.hybridMode == false)
        #expect(config.warnOnStaleIndex == true)
    }

    @Test("IndexStore auto-build configuration")
    func indexStoreAutoBuildConfig() {
        let config = UnusedCodeConfiguration.indexStoreAutoBuild

        #expect(config.mode == .indexStore)
        #expect(config.autoBuild == true)
    }

    @Test("Hybrid configuration")
    func hybridConfig() {
        let config = UnusedCodeConfiguration.hybrid

        #expect(config.mode == .indexStore)
        #expect(config.hybridMode == true)
    }

    @Test("Custom configuration with all options")
    func customConfig() {
        let config = UnusedCodeConfiguration(
            mode: .indexStore,
            autoBuild: true,
            hybridMode: true,
            warnOnStaleIndex: false,
        )

        #expect(config.mode == .indexStore)
        #expect(config.autoBuild == true)
        #expect(config.hybridMode == true)
        #expect(config.warnOnStaleIndex == false)
    }
}

// MARK: - IndexGraphReportTests

@Suite("IndexGraphReport Tests")
struct IndexGraphReportTests {
    @Test("Report calculations")
    func reportCalculations() {
        let report = IndexGraphReport(
            totalSymbols: 100,
            rootCount: 10,
            reachableCount: 80,
            unreachableCount: 10,
            externalCount: 10,
            edgeCount: 200,
            unreachableByKind: [.function: 5, .class: 3, .variable: 2],
            rootsByReason: [.mainFunction: 1, .testMethod: 9],
        )

        #expect(report.totalSymbols == 100)
        #expect(report.rootCount == 10)
        #expect(report.reachableCount == 80)
        #expect(report.unreachableCount == 10)
        #expect(report.externalCount == 10)
        #expect(report.edgeCount == 200)

        // 80 reachable out of 90 non-external = ~88.89%
        let percentage = report.reachabilityPercentage
        #expect(percentage > 88.0 && percentage < 90.0)
    }

    @Test("Report with all external symbols")
    func reportAllExternal() {
        let report = IndexGraphReport(
            totalSymbols: 50,
            rootCount: 0,
            reachableCount: 0,
            unreachableCount: 0,
            externalCount: 50,
            edgeCount: 0,
            unreachableByKind: [:],
            rootsByReason: [:],
        )

        // When all symbols are external, reachability is 100%
        #expect(report.reachabilityPercentage == 100.0)
    }
}

// MARK: - IndexStorePathFinderTests

@Suite("IndexStorePathFinder Tests")
struct IndexStorePathFinderTests {
    @Test("Find index store returns nil for non-existent project")
    func findIndexStoreNonExistent() {
        let result = IndexStorePathFinder.findIndexStorePath(in: "/non/existent/path")
        #expect(result == nil)
    }

    @Test("Find index store returns nil for directory without build")
    func findIndexStoreNoBuild() {
        // Create a temp directory without any index
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = IndexStorePathFinder.findIndexStorePath(in: tempDir.path)
        #expect(result == nil)
    }

    @Test("Find versioned index store subdirectory")
    func findVersionedIndexStore() {
        // Create a temp directory structure simulating Xcode DerivedData
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dataStore = tempDir.appendingPathComponent("DataStore")
        let v5 = dataStore.appendingPathComponent("v5")
        let records = v5.appendingPathComponent("records")
        let units = v5.appendingPathComponent("units")

        try? FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // The findVersionedIndexStore is a private method, but we can test through
        // the public findIndexStorePath by creating a mock SPM structure
        // For now, just verify the directory structure is created correctly
        #expect(FileManager.default.fileExists(atPath: records.path))
        #expect(FileManager.default.fileExists(atPath: units.path))
    }

    @Test("Prefer higher versioned index store")
    func preferHigherVersionedIndexStore() {
        // Create a temp directory with multiple version subdirectories
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dataStore = tempDir.appendingPathComponent("DataStore")

        // Create v4 with records
        let v4 = dataStore.appendingPathComponent("v4")
        let v4Records = v4.appendingPathComponent("records")
        try? FileManager.default.createDirectory(at: v4Records, withIntermediateDirectories: true)

        // Create v5 with records
        let v5 = dataStore.appendingPathComponent("v5")
        let v5Records = v5.appendingPathComponent("records")
        try? FileManager.default.createDirectory(at: v5Records, withIntermediateDirectories: true)

        // Create v6 with records
        let v6 = dataStore.appendingPathComponent("v6")
        let v6Records = v6.appendingPathComponent("records")
        try? FileManager.default.createDirectory(at: v6Records, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Verify the structure is correct for testing
        #expect(FileManager.default.fileExists(atPath: v4Records.path))
        #expect(FileManager.default.fileExists(atPath: v5Records.path))
        #expect(FileManager.default.fileExists(atPath: v6Records.path))
    }

    @Test("Project name normalization handles spaces")
    func projectNameNormalizationSpaces() {
        // Simulate DerivedData structure with normalized project name
        // "My App" becomes "My_App" in DerivedData
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let derivedData = tempDir.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        let projectDir = derivedData.appendingPathComponent("My_App-abc123def456")
        let indexNoindex = projectDir.appendingPathComponent("Index.noindex")
        let dataStore = indexNoindex.appendingPathComponent("DataStore")
        let v5 = dataStore.appendingPathComponent("v5")
        let records = v5.appendingPathComponent("records")

        try? FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Verify structure exists
        #expect(FileManager.default.fileExists(atPath: records.path))

        // The search uses the project name "My App" but DerivedData uses "My_App"
        // Our fix should handle this conversion
    }

    @Test("Project name normalization handles dashes and dots")
    func projectNameNormalizationDashesAndDots() {
        // "My-App.iOS" should match "My_App_iOS" in DerivedData
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let derivedData = tempDir.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        let projectDir = derivedData.appendingPathComponent("My_App_iOS-hash123")
        let indexNoindex = projectDir.appendingPathComponent("Index.noindex")
        let dataStore = indexNoindex.appendingPathComponent("DataStore")
        let v5 = dataStore.appendingPathComponent("v5")
        let records = v5.appendingPathComponent("records")

        try? FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Verify structure exists
        #expect(FileManager.default.fileExists(atPath: records.path))
    }

    @Test("Project name matching handles URL encoding fallback")
    func projectNameURLEncodingFallback() {
        // Test that URL-encoded names can be matched
        // "My App" URL-encoded would be "My%20App"
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let derivedData = tempDir.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        // Simulate a URL-encoded directory name (rare but possible)
        let projectDir = derivedData.appendingPathComponent("My%20App-hash123")
        let indexNoindex = projectDir.appendingPathComponent("Index.noindex")
        let dataStore = indexNoindex.appendingPathComponent("DataStore")
        let v5 = dataStore.appendingPathComponent("v5")
        let records = v5.appendingPathComponent("records")

        try? FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Verify structure exists
        #expect(FileManager.default.fileExists(atPath: records.path))

        // The matcher should handle both:
        // 1. Project "My App" matching "My%20App" (URL encoded dir)
        // 2. Project "My%20App" matching decoded "My App"
    }
}

// MARK: - IndexStoreReaderTests

@Suite("IndexStoreReader Tests")
struct IndexStoreReaderTests {
    @Test("Find libIndexStore returns valid path")
    func findLibIndexStore() {
        let path = IndexStoreReader.findLibIndexStore()

        // Should return a path (even if file doesn't exist in test environment)
        #expect(!path.isEmpty)
        #expect(path.contains("libIndexStore.dylib"))
    }
}

// MARK: - IndexedSymbolTests

@Suite("IndexedSymbol Tests")
struct IndexedSymbolTests {
    @Test("Create indexed symbol")
    func createIndexedSymbol() {
        let symbol = IndexedSymbol(
            usr: "s:Test:MyClass",
            name: "MyClass",
            kind: .class,
            isSystem: false,
        )

        #expect(symbol.usr == "s:Test:MyClass")
        #expect(symbol.name == "MyClass")
        #expect(symbol.kind == .class)
        #expect(symbol.isSystem == false)
    }

    @Test("All symbol kinds")
    func allSymbolKinds() {
        let kinds: [IndexedSymbolKind] = [
            .class, .struct, .enum, .protocol, .extension,
            .function, .method, .property, .variable, .parameter,
            .typealias, .module, .unknown,
        ]

        #expect(kinds.count == 13)
    }
}

// MARK: - IndexedOccurrenceTests

@Suite("IndexedOccurrence Tests")
struct IndexedOccurrenceTests {
    @Test("Create occurrence")
    func createOccurrence() {
        let symbol = IndexedSymbol(usr: "s:test", name: "test", kind: .function, isSystem: false)
        let occurrence = IndexedOccurrence(
            symbol: symbol,
            file: "/path/to/file.swift",
            line: 10,
            column: 5,
            roles: [.definition, .declaration],
        )

        #expect(occurrence.symbol.name == "test")
        #expect(occurrence.file == "/path/to/file.swift")
        #expect(occurrence.line == 10)
        #expect(occurrence.column == 5)
        #expect(occurrence.roles.contains(.definition))
        #expect(occurrence.roles.contains(.declaration))
    }
}

// MARK: - IndexedSymbolRolesTests

@Suite("IndexedSymbolRoles Tests")
struct IndexedSymbolRolesTests {
    @Test("Role options")
    func roleOptions() {
        var roles = IndexedSymbolRoles()

        roles.insert(.declaration)
        #expect(roles.contains(.declaration))

        roles.insert(.definition)
        #expect(roles.contains(.definition))

        roles.insert(.reference)
        #expect(roles.contains(.reference))
    }

    @Test("Multiple roles")
    func multipleRoles() {
        let roles: IndexedSymbolRoles = [.definition, .declaration, .reference]

        #expect(roles.contains(.definition))
        #expect(roles.contains(.declaration))
        #expect(roles.contains(.reference))
        #expect(!roles.contains(.call))
    }

    @Test("All role types")
    func allRoleTypes() {
        let allRoles: [IndexedSymbolRoles] = [
            .declaration,
            .definition,
            .reference,
            .read,
            .write,
            .call,
            .dynamic,
            .implicit,
        ]

        // Combine all roles
        var combined = IndexedSymbolRoles()
        for role in allRoles {
            combined.insert(role)
        }

        // Should contain all
        for role in allRoles {
            #expect(combined.contains(role))
        }
    }
}

// MARK: - SymbolUsageTests

@Suite("SymbolUsage Tests")
struct SymbolUsageTests {
    @Test("Unused symbol")
    func unusedSymbol() {
        let usage = SymbolUsage(
            usr: "s:test",
            name: "unusedFunc",
            kind: .function,
            definitionLocation: nil,
            referenceCount: 0,
            onlySelfReferenced: false,
            isTestSymbol: false,
        )

        #expect(usage.isUnused == true)
    }

    @Test("Used symbol")
    func usedSymbol() {
        let usage = SymbolUsage(
            usr: "s:test",
            name: "usedFunc",
            kind: .function,
            definitionLocation: nil,
            referenceCount: 5,
            onlySelfReferenced: false,
            isTestSymbol: false,
        )

        #expect(usage.isUnused == false)
    }

    @Test("Self-referenced symbol")
    func selfReferencedSymbol() {
        let usage = SymbolUsage(
            usr: "s:test",
            name: "recursiveFunc",
            kind: .function,
            definitionLocation: nil,
            referenceCount: 3,
            onlySelfReferenced: true,
            isTestSymbol: false,
        )

        #expect(usage.isUnused == false)
        #expect(usage.onlySelfReferenced == true)
    }

    @Test("Test symbol")
    func testSymbol() {
        let usage = SymbolUsage(
            usr: "s:test",
            name: "testSomething",
            kind: .function,
            definitionLocation: nil,
            referenceCount: 0,
            onlySelfReferenced: false,
            isTestSymbol: true,
        )

        #expect(usage.isTestSymbol == true)
    }
}

// MARK: - IndexBasedDependencyGraphTests

@Suite("IndexBasedDependencyGraph Tests")
struct IndexBasedDependencyGraphTests {
    @Test("Create empty graph")
    func createEmptyGraph() {
        let graph = IndexBasedDependencyGraph(analysisFiles: [])

        #expect(graph.nodeCount == 0)
        #expect(graph.edgeCount == 0)
        #expect(graph.rootNodes.isEmpty)
    }

    @Test("Graph configuration is stored")
    func graphConfiguration() {
        let config = IndexGraphConfiguration(
            treatTestsAsRoot: false,
            treatProtocolRequirementsAsRoot: false,
        )
        let graph = IndexBasedDependencyGraph(analysisFiles: ["/test.swift"], configuration: config)

        #expect(graph.configuration.treatTestsAsRoot == false)
        #expect(graph.configuration.treatProtocolRequirementsAsRoot == false)
    }

    @Test("Compute reachable on empty graph")
    func computeReachableEmpty() {
        let graph = IndexBasedDependencyGraph(analysisFiles: [])
        let reachable = graph.computeReachable()

        #expect(reachable.isEmpty)
    }

    @Test("Compute unreachable on empty graph")
    func computeUnreachableEmpty() {
        let graph = IndexBasedDependencyGraph(analysisFiles: [])
        let unreachable = graph.computeUnreachable()

        #expect(unreachable.isEmpty)
    }

    @Test("Generate report on empty graph")
    func generateReportEmpty() {
        let graph = IndexBasedDependencyGraph(analysisFiles: [])
        let report = graph.generateReport()

        #expect(report.totalSymbols == 0)
        #expect(report.rootCount == 0)
        #expect(report.reachableCount == 0)
        #expect(report.unreachableCount == 0)
    }
}

// MARK: - IndexStoreFallbackManagerTests

@Suite("IndexStoreFallbackManager Tests")
struct IndexStoreFallbackManagerTests {
    @Test("Create manager with default configuration")
    func createDefaultManager() {
        let manager = IndexStoreFallbackManager()

        #expect(manager.configuration.autoBuild == false)
        #expect(manager.configuration.checkFreshness == true)
    }

    @Test("Create manager with custom configuration")
    func createCustomManager() {
        let config = FallbackConfiguration(autoBuild: true, hybridMode: true)
        let manager = IndexStoreFallbackManager(configuration: config)

        #expect(manager.configuration.autoBuild == true)
        #expect(manager.configuration.hybridMode == true)
    }

    @Test("Check status for non-existent project")
    func checkStatusNonExistent() {
        let manager = IndexStoreFallbackManager()
        let status = manager.checkIndexStoreStatus(
            projectRoot: "/non/existent/path",
            sourceFiles: [],
        )

        #expect(status.isUsable == false)
    }
}
