//
//  ConfigurationTests.swift
//  SwiftStaticAnalysis
//
//  Tests for SWAConfiguration and ConfigurationLoader.
//

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore

// MARK: - SWAConfigurationTests

@Suite("SWA Configuration Tests")
struct SWAConfigurationTests {
    @Test("Default configuration has correct values")
    func defaultConfiguration() {
        let config = SWAConfiguration.default

        #expect(config.version == nil)
        #expect(config.resolvedVersion == 1)
        #expect(config.format == nil)
        #expect(config.excludePaths == nil)
        #expect(config.unused == nil)
        #expect(config.duplicates == nil)
    }

    @Test("Configuration is Codable")
    func codable() throws {
        let config = SWAConfiguration(
            version: 1,
            format: "xcode",
            excludePaths: ["**/Tests/**"],
            unused: UnusedConfiguration(
                enabled: true,
                mode: "reachability",
                sensibleDefaults: true,
            ),
            duplicates: DuplicatesConfiguration(
                enabled: true,
                minTokens: 100,
            ),
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SWAConfiguration.self, from: data)

        #expect(decoded == config)
    }

    @Test("Configuration parses from JSON")
    func parseFromJSON() throws {
        let json = """
        {
            "version": 1,
            "format": "text",
            "excludePaths": ["**/Fixtures/**", "**/Generated/**"],
            "unused": {
                "enabled": true,
                "mode": "simple",
                "sensibleDefaults": true,
                "ignorePublicAPI": true
            },
            "duplicates": {
                "enabled": false,
                "minTokens": 75,
                "minSimilarity": 0.9
            }
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let config = try decoder.decode(SWAConfiguration.self, from: data)

        #expect(config.version == 1)
        #expect(config.format == "text")
        #expect(config.excludePaths == ["**/Fixtures/**", "**/Generated/**"])
        #expect(config.unused?.enabled == true)
        #expect(config.unused?.mode == "simple")
        #expect(config.unused?.sensibleDefaults == true)
        #expect(config.unused?.ignorePublicAPI == true)
        #expect(config.duplicates?.enabled == false)
        #expect(config.duplicates?.minTokens == 75)
        #expect(config.duplicates?.minSimilarity == 0.9)
    }

    @Test("Partial configuration uses nil for missing values")
    func partialConfiguration() throws {
        let json = """
        {
            "version": 1,
            "unused": {
                "mode": "reachability"
            }
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let config = try decoder.decode(SWAConfiguration.self, from: data)

        #expect(config.version == 1)
        #expect(config.format == nil)
        #expect(config.excludePaths == nil)
        #expect(config.unused?.enabled == nil)
        #expect(config.unused?.mode == "reachability")
        #expect(config.unused?.sensibleDefaults == nil)
        #expect(config.duplicates == nil)
    }

    @Test("Configuration without version field uses default version")
    func configWithoutVersion() throws {
        let json = """
        {
            "format": "xcode",
            "unused": {
                "sensibleDefaults": true
            }
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let config = try decoder.decode(SWAConfiguration.self, from: data)

        #expect(config.version == nil)
        #expect(config.resolvedVersion == SWAConfiguration.currentVersion)
        #expect(config.format == "xcode")
        #expect(config.unused?.sensibleDefaults == true)
    }

    @Test("Minimal configuration with only one setting parses correctly")
    func minimalConfiguration() throws {
        let json = """
        {
            "duplicates": {
                "minTokens": 100
            }
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let config = try decoder.decode(SWAConfiguration.self, from: data)

        #expect(config.version == nil)
        #expect(config.resolvedVersion == 1)
        #expect(config.format == nil)
        #expect(config.unused == nil)
        #expect(config.duplicates?.minTokens == 100)
    }

    @Test("Unknown keys are ignored (forward compatibility)")
    func unknownKeysIgnored() throws {
        let json = """
        {
            "version": 1,
            "futureKey": "futureValue",
            "unused": {
                "enabled": true,
                "futureOption": 42
            }
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()

        // Should not throw - unknown keys are ignored
        let config = try decoder.decode(SWAConfiguration.self, from: data)
        #expect(config.version == 1)
        #expect(config.unused?.enabled == true)
    }
}

// MARK: - UnusedConfigurationTests

@Suite("Unused Configuration Tests")
struct UnusedConfigurationTests {
    @Test("Default configuration has nil values")
    func defaultConfiguration() {
        let config = UnusedConfiguration.default

        #expect(config.enabled == nil)
        #expect(config.mode == nil)
        #expect(config.sensibleDefaults == nil)
    }

    @Test("All options can be set")
    func allOptions() {
        let config = UnusedConfiguration(
            enabled: true,
            mode: "indexStore",
            indexStorePath: "/path/to/index",
            minConfidence: "high",
            treatPublicAsRoot: true,
            treatObjcAsRoot: true,
            treatTestsAsRoot: true,
            treatSwiftUIViewsAsRoot: true,
            ignoreSwiftUIPropertyWrappers: true,
            ignorePreviewProviders: true,
            ignoreViewBody: true,
            ignorePublicAPI: true,
            sensibleDefaults: false,
            excludeImports: true,
            excludeDeinit: true,
            excludeEnumCases: true,
            excludeTestSuites: true,
            excludeNamePatterns: ["^_", "^unused"],
            excludePaths: ["**/Generated/**"],
        )

        #expect(config.enabled == true)
        #expect(config.mode == "indexStore")
        #expect(config.indexStorePath == "/path/to/index")
        #expect(config.minConfidence == "high")
        #expect(config.treatPublicAsRoot == true)
        #expect(config.treatObjcAsRoot == true)
        #expect(config.treatTestsAsRoot == true)
        #expect(config.treatSwiftUIViewsAsRoot == true)
        #expect(config.ignoreSwiftUIPropertyWrappers == true)
        #expect(config.ignorePreviewProviders == true)
        #expect(config.ignoreViewBody == true)
        #expect(config.ignorePublicAPI == true)
        #expect(config.sensibleDefaults == false)
        #expect(config.excludeImports == true)
        #expect(config.excludeDeinit == true)
        #expect(config.excludeEnumCases == true)
        #expect(config.excludeTestSuites == true)
        #expect(config.excludeNamePatterns == ["^_", "^unused"])
        #expect(config.excludePaths == ["**/Generated/**"])
    }
}

// MARK: - DuplicatesConfigurationTests

@Suite("Duplicates Configuration Tests")
struct DuplicatesConfigurationTests {
    @Test("Default configuration has nil values")
    func defaultConfiguration() {
        let config = DuplicatesConfiguration.default

        #expect(config.enabled == nil)
        #expect(config.minTokens == nil)
        #expect(config.minSimilarity == nil)
    }

    @Test("All options can be set")
    func allOptions() {
        let config = DuplicatesConfiguration(
            enabled: true,
            minTokens: 100,
            minSimilarity: 0.85,
            types: ["exact", "near"],
            algorithm: "suffixArray",
            ignoredPatterns: [".*TODO.*"],
            excludePaths: ["**/Vendor/**"],
        )

        #expect(config.enabled == true)
        #expect(config.minTokens == 100)
        #expect(config.minSimilarity == 0.85)
        #expect(config.types == ["exact", "near"])
        #expect(config.algorithm == "suffixArray")
        #expect(config.ignoredPatterns == [".*TODO.*"])
        #expect(config.excludePaths == ["**/Vendor/**"])
    }
}

// MARK: - ConfigurationLoaderTests

@Suite("Configuration Loader Tests")
struct ConfigurationLoaderTests {
    @Test("Loader finds .swa.json file")
    func findConfigFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent(".swa.json")
        let configContent = """
        {
            "version": 1,
            "format": "xcode"
        }
        """
        try configContent.write(to: configPath, atomically: true, encoding: .utf8)

        let loader = ConfigurationLoader()
        let foundPath = loader.findConfigFile(in: tempDir)

        #expect(foundPath == configPath)
    }

    @Test("Loader finds swa.json file (without dot)")
    func findConfigFileWithoutDot() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("swa.json")
        let configContent = """
        {
            "version": 1
        }
        """
        try configContent.write(to: configPath, atomically: true, encoding: .utf8)

        let loader = ConfigurationLoader()
        let foundPath = loader.findConfigFile(in: tempDir)

        #expect(foundPath == configPath)
    }

    @Test("Loader prefers .swa.json over swa.json")
    func prefersDotFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dotConfigPath = tempDir.appendingPathComponent(".swa.json")
        let configPath = tempDir.appendingPathComponent("swa.json")

        try "{\"version\": 1}".write(to: dotConfigPath, atomically: true, encoding: .utf8)
        try "{\"version\": 2}".write(to: configPath, atomically: true, encoding: .utf8)

        let loader = ConfigurationLoader()
        let foundPath = loader.findConfigFile(in: tempDir)

        #expect(foundPath == dotConfigPath)
    }

    @Test("Loader returns nil when no config file exists")
    func noConfigFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = ConfigurationLoader()
        let config = try loader.load(from: tempDir)

        #expect(config == nil)
    }

    @Test("Loader loads configuration from file")
    func loadConfigFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent(".swa.json")
        let configContent = """
        {
            "version": 1,
            "format": "json",
            "unused": {
                "enabled": true,
                "mode": "reachability"
            }
        }
        """
        try configContent.write(to: configPath, atomically: true, encoding: .utf8)

        let loader = ConfigurationLoader()
        let config = try loader.load(from: tempDir)

        #expect(config?.version == 1)
        #expect(config?.format == "json")
        #expect(config?.unused?.enabled == true)
        #expect(config?.unused?.mode == "reachability")
    }

    @Test("Loader throws on invalid JSON")
    func invalidJSON() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent(".swa.json")
        try "{ invalid json }".write(to: configPath, atomically: true, encoding: .utf8)

        let loader = ConfigurationLoader()

        #expect(throws: ConfigurationError.self) {
            _ = try loader.loadFromFile(configPath)
        }
    }

    @Test("Loader loads from explicit path")
    func loadFromExplicitPath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("custom-config.json")
        let configContent = """
        {
            "version": 1,
            "duplicates": {
                "minTokens": 200
            }
        }
        """
        try configContent.write(to: configPath, atomically: true, encoding: .utf8)

        let loader = ConfigurationLoader()
        let config = try loader.loadFromFile(configPath)

        #expect(config.version == 1)
        #expect(config.duplicates?.minTokens == 200)
    }
}

// MARK: - ConfigurationMergingTests

@Suite("Configuration Merging Tests")
struct ConfigurationMergingTests {
    @Test("CLI values override config file values")
    func cliOverridesConfig() {
        let fileConfig = SWAConfiguration(
            version: 1,
            format: "text",
            unused: UnusedConfiguration(
                enabled: true,
                mode: "simple",
                sensibleDefaults: false,
            ),
        )

        let cliConfig = SWAConfiguration(
            version: 1,
            format: "xcode",
            unused: UnusedConfiguration(
                mode: "reachability",
            ),
        )

        let merged = fileConfig.merging(with: cliConfig)

        #expect(merged.format == "xcode")
        #expect(merged.unused?.mode == "reachability")
        #expect(merged.unused?.enabled == true)
        #expect(merged.unused?.sensibleDefaults == false)
    }

    @Test("Nil CLI values preserve config file values")
    func nilCLIPreservesConfig() {
        let fileConfig = SWAConfiguration(
            version: 1,
            format: "json",
            excludePaths: ["**/Tests/**"],
            duplicates: DuplicatesConfiguration(
                enabled: true,
                minTokens: 100,
            ),
        )

        let cliConfig = SWAConfiguration(
            version: 1,
        )

        let merged = fileConfig.merging(with: cliConfig)

        #expect(merged.format == "json")
        #expect(merged.excludePaths == ["**/Tests/**"])
        #expect(merged.duplicates?.enabled == true)
        #expect(merged.duplicates?.minTokens == 100)
    }

    @Test("Empty array in CLI replaces config file array")
    func emptyArrayReplacesConfig() {
        let fileConfig = SWAConfiguration(
            version: 1,
            excludePaths: ["**/Tests/**", "**/Fixtures/**"],
        )

        // Empty array means "explicitly no exclusions"
        let cliConfig = SWAConfiguration(
            version: 1,
            excludePaths: [],
        )

        let merged = fileConfig.merging(with: cliConfig)

        // Empty array doesn't override (considered "not provided")
        #expect(merged.excludePaths == ["**/Tests/**", "**/Fixtures/**"])
    }

    @Test("Non-empty array in CLI replaces config file array")
    func nonEmptyArrayReplacesConfig() {
        let fileConfig = SWAConfiguration(
            version: 1,
            excludePaths: ["**/Tests/**", "**/Fixtures/**"],
        )

        let cliConfig = SWAConfiguration(
            version: 1,
            excludePaths: ["**/Generated/**"],
        )

        let merged = fileConfig.merging(with: cliConfig)

        #expect(merged.excludePaths == ["**/Generated/**"])
    }
}

// MARK: - ConfigurationErrorTests

@Suite("Configuration Error Tests")
struct ConfigurationErrorTests {
    @Test("File read error has descriptive message")
    func fileReadErrorDescription() {
        let error = ConfigurationError.fileReadError(
            path: "/path/to/config.json",
            underlying: NSError(domain: "Test", code: 1),
        )

        let description = error.description
        #expect(description.contains("/path/to/config.json"))
        #expect(description.contains("read"))
    }

    @Test("Parse error has descriptive message")
    func parseErrorDescription() {
        let error = ConfigurationError.parseError(
            path: "/path/to/config.json",
            underlying: NSError(domain: "Test", code: 2),
        )

        let description = error.description
        #expect(description.contains("/path/to/config.json"))
        #expect(description.contains("parse"))
    }

    @Test("Unsupported version error has descriptive message")
    func unsupportedVersionDescription() {
        let error = ConfigurationError.unsupportedVersion(
            version: 99,
            path: "/path/to/config.json",
        )

        let description = error.description
        #expect(description.contains("99"))
        #expect(description.contains("Unsupported"))
    }
}
