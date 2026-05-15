import Foundation
import Testing

struct SWAMCPCLIOutput: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var succeeded: Bool {
        exitCode == 0
    }
}

enum SWAMCPCommandTestError: Error, CustomStringConvertible {
    case binaryNotFound(String)

    var description: String {
        switch self {
        case .binaryNotFound(let path):
            "swa-mcp binary not found at '\(path)'. Run 'swift build' before running tests."
        }
    }
}

@Suite("SWAMCP Command Tests")
struct SWAMCPCommandTests {
    private let binaryPath: String

    init() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let testsDir = testFileURL.deletingLastPathComponent()
        let packageRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()

        binaryPath = packageRoot.appendingPathComponent(".build/debug/swa-mcp").path

        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw SWAMCPCommandTestError.binaryNotFound(binaryPath)
        }
    }

    @Test("swa-mcp --help shows usage and path options")
    func helpShowsUsage() async throws {
        let output = try await runCommand(["--help"])

        #expect(output.succeeded)
        #expect(output.stdout.contains("USAGE:"))
        #expect(output.stdout.contains("--path"))
        #expect(output.stdout.contains("AVAILABLE TOOLS:"))
    }

    @Test("swa-mcp --version shows semantic version")
    func versionShowsSemVer() async throws {
        let output = try await runCommand(["--version"])

        // 0.3.0-α: swa-mcp adopted ArgumentParser, which prints just the
        // version literal — no "swa-mcp" prefix — to match the contract
        // of the `swa` CLI (`swa --version` is identical).
        #expect(output.succeeded)
        #expect(output.stdout.contains(#/\d+\.\d+\.\d+/#))
    }

    private func runCommand(_ arguments: [String]) async throws -> SWAMCPCLIOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        let stderrData = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()

        return SWAMCPCLIOutput(
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            exitCode: process.terminationStatus,
        )
    }
}
