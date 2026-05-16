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
        case timedOut(executable: String, after: Duration)
    }

    /// Default subprocess timeout. The CLI never legitimately needs to
    /// block on a child for longer than two minutes; an unresponsive
    /// `swiftc`/`xcrun` past this point is hung and should be killed
    /// instead of stalling the analyzer.
    public static let defaultTimeout: Duration = .seconds(120)

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
    ///   - timeout: Maximum wall-clock time the child is allowed to
    ///     run. After this the process is `terminate()`d and the call
    ///     throws `Error.timedOut`. Defaults to `defaultTimeout`.
    /// - Returns: stdout / stderr / exit code.
    /// - Throws: `ProcessExecutor.Error.launchFailed` if `Process.run()`
    ///   throws; `.timedOut` if the deadline expires before exit.
    public static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environmentOverrides: [String: String] = [:],
        timeout: Duration = defaultTimeout
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

        // Background watchdog: terminate the process if it outlives the
        // deadline. We can't use `withTimeout` (not in stdlib at this
        // toolchain) so a small Thread runs the timer. `terminate()` is
        // idempotent — racing a normal exit just no-ops.
        let deadline = DispatchTime.now() + .nanoseconds(
            Int(timeout.components.seconds * 1_000_000_000
                + timeout.components.attoseconds / 1_000_000_000)
        )
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: deadline, execute: watchdog
        )

        process.waitUntilExit()
        watchdog.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        // If we terminated the process via watchdog, surface that as the
        // distinct `.timedOut` error so callers don't confuse it with a
        // normal failure exit.
        if process.terminationReason == .uncaughtSignal,
            process.terminationStatus == SIGTERM
        {
            throw Error.timedOut(executable: executable.path, after: timeout)
        }

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
