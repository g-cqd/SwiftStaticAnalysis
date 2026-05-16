//  ProcessExecutor.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - ProcessExecutor

/// Spawns short-lived subprocesses (`swift build`, `xcodebuild`, `xcrun`)
/// with a **scrubbed environment** — only the allowlisted variables below
/// are inherited from the parent. This prevents environment-based
/// influences (`DYLD_INSERT_LIBRARIES`, `DEVELOPER_DIR`, `SWIFTPM_HOOKS_DIR`,
/// `LD_LIBRARY_PATH`, etc.) from changing how the child resolves
/// toolchain binaries or libraries.
///
/// The plugin host (`Sources/StaticAnalysisCommandPlugin`) cannot use this
/// because SPM plugins are restricted to `PackagePlugin + Foundation`;
/// every non-plugin `Process()` invocation routes through here.
///
/// `swift-subprocess` is intentionally not adopted yet: it's pre-1.0 and
/// the Foundation `Process` plumbing is correct after the env scrub.
/// When the upstream package reaches a stable release we can re-evaluate.
public enum ProcessExecutor {
    /// Environment variables inherited from the parent. Anything else is
    /// dropped — including `DYLD_INSERT_LIBRARIES`, `DEVELOPER_DIR`,
    /// `SWIFTPM_HOOKS_DIR`, all `LD_*` / `DYLD_*` overrides.
    ///
    /// The list intentionally excludes shell-related variables (`SHELL`,
    /// `BASH_ENV`) and IFS-style settings that have historically been
    /// vectors for privilege-escalation chains.
    public static let allowedEnvironmentKeys: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL",
        "LC_CTYPE", "LC_MESSAGES", "TMPDIR", "TERM",
    ]

    /// Result of a subprocess invocation.
    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String

        /// `true` if the process exited normally with code 0.
        public var succeeded: Bool { exitCode == 0 }
    }

    /// Errors raised by `ProcessExecutor.run`.
    public enum Error: Swift.Error, Sendable {
        case launchFailed(executable: String, underlying: String)
    }

    /// Run a subprocess with a scrubbed environment.
    ///
    /// - Parameters:
    ///   - executable: Absolute path to the binary.
    ///   - arguments: Command-line arguments (the binary name is NOT
    ///     prepended; it's implicit in `executable`).
    ///   - currentDirectory: Optional working directory.
    ///   - environmentOverrides: Additional environment variables on top
    ///     of the allowlist (e.g. for tests that need to inject a
    ///     deliberate value).
    /// - Returns: stdout / stderr / exit code.
    /// - Throws: `ProcessExecutor.Error.launchFailed` if `Process.run()`
    ///   throws.
    public static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environmentOverrides: [String: String] = [:]
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let cwd = currentDirectory {
            process.currentDirectoryURL = cwd
        }
        process.environment = scrubbedEnvironment(overrides: environmentOverrides)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw Error.launchFailed(
                executable: executable.path,
                underlying: error.localizedDescription
            )
        }
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// Compose the child environment from the allowlist (inheriting values
    /// from `ProcessInfo.environment`) plus any explicit overrides. Returns
    /// `nil` to fall back to the parent's environment only if both the
    /// allowlist intersection and overrides are empty (the `Process`
    /// default), which should not happen in practice — `PATH` is almost
    /// always present.
    static func scrubbedEnvironment(
        overrides: [String: String] = [:],
        source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String] = [:]
        for key in allowedEnvironmentKeys {
            if let value = source[key] {
                env[key] = value
            }
        }
        for (key, value) in overrides {
            env[key] = value
        }
        return env
    }
}
