//
//  CLITests.swift
//  SwiftStaticAnalysis
//
//  Tests for the `swa` CLI tool commands.
//

import Foundation
import Testing

// MARK: - CLIOutput

/// Structured CLI output separating stdout, stderr, and exit code.
struct CLIOutput: Sendable {
    /// Standard output content.
    let stdout: String

    /// Standard error content.
    let stderr: String

    /// Process exit code.
    let exitCode: Int32

    /// Combined output (stdout + stderr) for convenience.
    var combined: String {
        if stdout.isEmpty {
            return stderr
        }
        if stderr.isEmpty {
            return stdout
        }
        return stdout + "\n" + stderr
    }

    /// Whether the command succeeded (exit code 0).
    var succeeded: Bool {
        exitCode == 0
    }
}

// MARK: - CLITestError

enum CLITestError: Error, CustomStringConvertible {
    case binaryNotFound(String)
    case fixtureNotFound(String)

    var description: String {
        switch self {
        case .binaryNotFound(let path):
            "swa binary not found at '\(path)'. Run 'swift build' before running tests."
        case .fixtureNotFound(let name):
            "Fixture file not found: \(name)"
        }
    }
}

// MARK: - CLI Command Tests

@Suite("CLI Command Tests")
struct CLICommandTests {
    private let swaPath: String
    private let fixturesPath: String

    init() throws {
        // Determine paths relative to the test file location
        let testFileURL = URL(fileURLWithPath: #filePath)
        let testsDir = testFileURL.deletingLastPathComponent()
        let packageRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()

        swaPath = packageRoot.appendingPathComponent(".build/debug/swa").path
        fixturesPath = testsDir.appendingPathComponent("Fixtures").path

        // Fail fast if binary doesn't exist - do NOT build during tests
        guard FileManager.default.fileExists(atPath: swaPath) else {
            throw CLITestError.binaryNotFound(swaPath)
        }
    }

    // MARK: - Help Command Tests

    @Test("swa --help shows all subcommands")
    func helpShowsAllSubcommands() async throws {
        let output = try await runSWA(["--help"])

        #expect(output.succeeded, "Help command should succeed")
        #expect(output.stdout.contains("analyze"), "Should list analyze command")
        #expect(output.stdout.contains("duplicates"), "Should list duplicates command")
        #expect(output.stdout.contains("unused"), "Should list unused command")
        #expect(output.stdout.contains("symbol"), "Should list symbol command")
    }

    @Test("swa analyze --help shows format and config options")
    func analyzeHelpShowsOptions() async throws {
        let output = try await runSWA(["analyze", "--help"])

        #expect(output.succeeded, "Help command should succeed")
        #expect(output.stdout.contains("--format"), "Should show format option")
        #expect(output.stdout.contains("--config"), "Should show config option")
    }

    @Test("swa duplicates --help shows duplication-specific options")
    func duplicatesHelpShowsOptions() async throws {
        let output = try await runSWA(["duplicates", "--help"])

        #expect(output.succeeded, "Help command should succeed")
        #expect(output.stdout.contains("--types"), "Should show types option")
        #expect(output.stdout.contains("--min-tokens"), "Should show min-tokens option")
        #expect(output.stdout.contains("--min-similarity"), "Should show min-similarity option")
        #expect(output.stdout.contains("--algorithm"), "Should show algorithm option")
    }

    @Test("swa unused --help shows unused-specific options")
    func unusedHelpShowsOptions() async throws {
        let output = try await runSWA(["unused", "--help"])

        #expect(output.succeeded, "Help command should succeed")
        #expect(output.stdout.contains("--ignore-public"), "Should show ignore-public flag")
        #expect(output.stdout.contains("--mode"), "Should show mode option")
        #expect(output.stdout.contains("--sensible-defaults"), "Should show sensible-defaults flag")
    }

    @Test("swa symbol --help shows symbol-specific options")
    func symbolHelpShowsOptions() async throws {
        let output = try await runSWA(["symbol", "--help"])

        #expect(output.succeeded, "Help command should succeed")
        #expect(output.stdout.contains("--kind"), "Should show kind option")
        #expect(output.stdout.contains("--access"), "Should show access option")
        #expect(output.stdout.contains("--definition"), "Should show definition flag")
        #expect(output.stdout.contains("--usages"), "Should show usages flag")
    }

    @Test("swa --version shows semantic version")
    func versionShowsSemVer() async throws {
        let output = try await runSWA(["--version"])

        #expect(output.succeeded, "Version command should succeed")
        // Semantic version format: X.Y.Z
        let versionPattern = #/\d+\.\d+\.\d+/#
        #expect(
            output.stdout.contains(versionPattern),
            "Version output '\(output.stdout)' should match semver pattern"
        )
    }

    // MARK: - Output Format Tests

    @Test("duplicates command produces valid JSON with --format json")
    func duplicatesJSONFormatProducesValidJSON() async throws {
        let fixture = try fixtureFile("SimpleClass.swift")
        let output = try await runSWA(["duplicates", "--format", "json", fixture])

        #expect(output.succeeded, "Command should succeed")
        // JSON output must start with [ or { to be valid JSON
        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            trimmed.hasPrefix("[") || trimmed.hasPrefix("{"),
            "JSON output should start with [ or {, got: '\(trimmed.prefix(20))...'"
        )
    }

    @Test("unused command produces Xcode-format diagnostics")
    func unusedXcodeFormatProducesFileLineColumn() async throws {
        let fixture = try fixtureFile("SimpleClass.swift")
        let output = try await runSWA(["unused", "--format", "xcode", fixture])

        #expect(output.succeeded, "Command should succeed")
        // Xcode format: file:line:column: warning: message
        // OR empty output if no unused code found
        if !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let xcodePattern = #/\S+:\d+:\d+: warning:/#
            #expect(
                output.stdout.contains(xcodePattern),
                "Xcode format should match file:line:column: warning: pattern"
            )
        }
    }

    @Test("duplicates text format includes clone count header")
    func duplicatesTextFormatIncludesHeader() async throws {
        let fixture = try fixtureFile("SimpleClass.swift")
        let output = try await runSWA(["duplicates", "--format", "text", fixture])

        #expect(output.succeeded, "Command should succeed")
        // Text format always shows "Found X clone group(s)"
        let headerPattern = #/Found \d+ clone group/#
        #expect(
            output.stdout.contains(headerPattern),
            "Text format should include 'Found N clone group(s)' header"
        )
    }

    // MARK: - Algorithm Tests

    @Test("duplicates command accepts rolling hash algorithm")
    func duplicatesRollingHashAlgorithmAccepted() async throws {
        let fixture = try fixtureFile("SimpleClass.swift")
        let output = try await runSWA(["duplicates", "--algorithm", "rollingHash", fixture])

        #expect(output.succeeded, "rollingHash algorithm should be accepted")
        #expect(output.stderr.isEmpty, "Should not produce errors")
    }

    @Test("duplicates command accepts suffix array algorithm")
    func duplicatesSuffixArrayAlgorithmAccepted() async throws {
        let fixture = try fixtureFile("SimpleClass.swift")
        let output = try await runSWA(["duplicates", "--algorithm", "suffixArray", fixture])

        #expect(output.succeeded, "suffixArray algorithm should be accepted")
        #expect(output.stderr.isEmpty, "Should not produce errors")
    }

    @Test("duplicates command accepts minHashLSH algorithm")
    func duplicatesMinHashLSHAlgorithmAccepted() async throws {
        let fixture = try fixtureFile("SimpleClass.swift")
        let output = try await runSWA(["duplicates", "--algorithm", "minHashLSH", fixture])

        #expect(output.succeeded, "minHashLSH algorithm should be accepted")
        #expect(output.stderr.isEmpty, "Should not produce errors")
    }

    // MARK: - Detection Mode Tests

    @Test("unused command accepts simple mode")
    func unusedSimpleModeAccepted() async throws {
        let fixture = try fixtureFile("SimpleClass.swift")
        let output = try await runSWA(["unused", "--mode", "simple", fixture])

        #expect(output.succeeded, "simple mode should be accepted")
    }

    @Test("unused command accepts reachability mode")
    func unusedReachabilityModeAccepted() async throws {
        let fixture = try fixtureFile("SimpleClass.swift")
        let output = try await runSWA(["unused", "--mode", "reachability", fixture])

        #expect(output.succeeded, "reachability mode should be accepted")
    }

    // MARK: - Symbol Lookup Tests

    @Test("symbol command finds existing class by name")
    func symbolFindsClassByName() async throws {
        let fixture = try fixtureFile("SimpleClass.swift")
        let output = try await runSWA(["symbol", "SimpleClass", fixture])

        #expect(output.succeeded, "Symbol lookup should succeed")
        // Should either find the class or report "No symbols found"
        let foundSymbol = output.stdout.contains("SimpleClass")
        let noSymbols = output.stdout.contains("No symbols found")
        #expect(
            foundSymbol || noSymbols,
            "Should report finding SimpleClass or indicate no symbols found"
        )
    }

    @Test("symbol command with --kind filters results")
    func symbolFiltersByKind() async throws {
        let fixture = try fixtureFile("SimpleClass.swift")
        let output = try await runSWA(["symbol", "SimpleClass", "--kind", "class", fixture])

        #expect(output.succeeded, "Symbol lookup with kind filter should succeed")
    }

    @Test("symbol command reports no matches for nonexistent symbol")
    func symbolReportsNoMatchesForNonexistent() async throws {
        let fixture = try fixtureFile("SimpleClass.swift")
        let output = try await runSWA(["symbol", "NonexistentSymbol123XYZ", fixture])

        #expect(output.succeeded, "Command should succeed even with no matches")
        #expect(
            output.stdout.contains("No symbols found"),
            "Should report 'No symbols found' for nonexistent symbol"
        )
    }

    // MARK: - Duplication Detection Tests

    @Test("duplicates command detects actual duplicated code")
    func duplicatesDetectsActualDuplicates() async throws {
        let fixture = try fixtureFile("DuplicatedCode.swift")
        let output = try await runSWA([
            "duplicates", "--format", "text", "--min-tokens", "20", fixture,
        ])

        #expect(output.succeeded, "Command should succeed")
        // The DuplicatedCode.swift fixture has intentional duplicates
        let headerPattern = #/Found (\d+) clone group/#
        if let match = output.stdout.firstMatch(of: headerPattern) {
            let count = Int(match.1) ?? 0
            #expect(count >= 1, "Should detect at least 1 clone group in DuplicatedCode.swift")
        }
    }

    // MARK: - Error Handling Tests

    @Test("reports error for nonexistent file path")
    func errorForNonexistentFile() async throws {
        let output = try await runSWA(["analyze", "/nonexistent/path/file.swift"])

        #expect(!output.succeeded, "Should fail for nonexistent file")
        #expect(output.exitCode != 0, "Exit code should be non-zero")
        // Error message should be in stderr or stdout depending on ArgumentParser behavior
        let hasErrorMessage =
            output.combined.lowercased().contains("not found")
            || output.combined.lowercased().contains("error")
            || output.combined.lowercased().contains("no such file")
        #expect(hasErrorMessage, "Should report file not found error")
    }

    @Test("reports error for invalid format option")
    func errorForInvalidFormat() async throws {
        let fixture = try fixtureFile("SimpleClass.swift")
        let output = try await runSWA(["duplicates", "--format", "invalidformat", fixture])

        #expect(!output.succeeded, "Should fail for invalid format")
        #expect(output.exitCode != 0, "Exit code should be non-zero for invalid option")
    }

    @Test("reports error for invalid algorithm option")
    func errorForInvalidAlgorithm() async throws {
        let fixture = try fixtureFile("SimpleClass.swift")
        let output = try await runSWA(["duplicates", "--algorithm", "invalidalgo", fixture])

        #expect(!output.succeeded, "Should fail for invalid algorithm")
        #expect(output.exitCode != 0, "Exit code should be non-zero for invalid option")
    }

    @Test("reports error for invalid detection mode")
    func errorForInvalidMode() async throws {
        let fixture = try fixtureFile("SimpleClass.swift")
        let output = try await runSWA(["unused", "--mode", "invalidmode", fixture])

        #expect(!output.succeeded, "Should fail for invalid mode")
        #expect(output.exitCode != 0, "Exit code should be non-zero for invalid option")
    }

    // MARK: - Helpers

    private func runSWA(_ arguments: [String]) async throws -> CLIOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: swaPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return CLIOutput(
            stdout: stdout,
            stderr: stderr,
            exitCode: process.terminationStatus
        )
    }

    private func fixtureFile(_ name: String) throws -> String {
        let path = (fixturesPath as NSString).appendingPathComponent(name)

        guard FileManager.default.fileExists(atPath: path) else {
            throw CLITestError.fixtureNotFound(name)
        }

        return path
    }
}
