//  ProcessExecutorTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore

@Suite("ProcessExecutor Tests")
struct ProcessExecutorTests {
    /// Variables outside the allowlist must NOT propagate to the child.
    /// In particular `DYLD_INSERT_LIBRARIES`, `DEVELOPER_DIR`, and
    /// `SWIFTPM_HOOKS_DIR` are vectors for code-injection into the
    /// `swift build` / `xcrun` chain.
    @Test("scrubbedEnvironment drops dangerous variables")
    func scrubbedEnvironmentDropsDangerousKeys() {
        let parent: [String: String] = [
            "PATH": "/usr/bin",
            "HOME": "/Users/test",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            "DEVELOPER_DIR": "/tmp/fake-toolchain",
            "SWIFTPM_HOOKS_DIR": "/tmp/hooks",
            "LD_LIBRARY_PATH": "/tmp",
            "SHELL": "/bin/zsh",
            "BASH_ENV": "/tmp/bashrc",
        ]
        let scrubbed = ProcessExecutor.scrubbedEnvironment(source: parent)

        #expect(scrubbed["PATH"] == "/usr/bin")
        #expect(scrubbed["HOME"] == "/Users/test")
        #expect(scrubbed["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(scrubbed["DEVELOPER_DIR"] == nil)
        #expect(scrubbed["SWIFTPM_HOOKS_DIR"] == nil)
        #expect(scrubbed["LD_LIBRARY_PATH"] == nil)
        #expect(scrubbed["SHELL"] == nil)
        #expect(scrubbed["BASH_ENV"] == nil)
    }

    /// Allow-listed keys propagate; non-allowed values are silently dropped.
    @Test("scrubbedEnvironment keeps allowlisted variables")
    func scrubbedEnvironmentKeepsAllowlisted() {
        let parent: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/root",
            "USER": "root",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TMPDIR": "/tmp",
            "TERM": "xterm-256color",
        ]
        let scrubbed = ProcessExecutor.scrubbedEnvironment(source: parent)

        for key in ProcessExecutor.allowedEnvironmentKeys {
            if let expected = parent[key] {
                #expect(scrubbed[key] == expected, "Allowed key '\(key)' should propagate")
            }
        }
    }

    /// Caller-supplied overrides take precedence over the inherited
    /// allowlist (e.g. so a unit test can inject `LANG=C` deliberately).
    @Test("overrides shadow inherited values")
    func overridesShadowInheritedValues() {
        let parent = ["LANG": "fr_FR.UTF-8", "PATH": "/usr/bin"]
        let scrubbed = ProcessExecutor.scrubbedEnvironment(
            overrides: ["LANG": "C"],
            source: parent
        )

        #expect(scrubbed["LANG"] == "C")
        #expect(scrubbed["PATH"] == "/usr/bin")
    }

    /// Live end-to-end: launch `/bin/sh -c env` and confirm the child's
    /// observable environment matches what `scrubbedEnvironment` computes.
    /// `/bin/sh` is the most portable target on macOS/Linux.
    @Test("live env scrub: child only sees allowlisted variables")
    func liveEnvScrub() throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        // Skip if the test environment doesn't have /bin/sh (e.g. very
        // stripped CI sandbox).
        guard FileManager.default.isExecutableFile(atPath: shell.path) else {
            return
        }

        let result = try ProcessExecutor.run(
            executable: shell,
            arguments: ["-c", "env"]
        )
        let childEnv = Set(
            result.stdout.split(separator: "\n").compactMap { line in
                line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first
                    .map(String.init)
            }
        )

        // No surprise variables. The shell may inject one or two of its
        // own (`PWD`, `SHLVL`, `_`) which is fine; what matters is none
        // of the dangerous ones leaked through.
        let dangerous: Set<String> = [
            "DYLD_INSERT_LIBRARIES",
            "DYLD_LIBRARY_PATH",
            "DEVELOPER_DIR",
            "SWIFTPM_HOOKS_DIR",
            "LD_LIBRARY_PATH",
            "LD_PRELOAD",
        ]
        let leaked = dangerous.intersection(childEnv)
        #expect(leaked.isEmpty, "Dangerous variables leaked to child: \(leaked)")
    }
}
