//  SourceKitLSPClientTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import SymbolLookup

@Suite("SourceKit-LSP Client Tests")
struct SourceKitLSPClientTests {
    /// Smoke-tests the LSP client against a real `sourcekit-lsp`
    /// binary. Skipped if the binary isn't available on the host
    /// (CI runners without Xcode tooling).
    @Test("Client completes the LSP initialize handshake against sourcekit-lsp")
    func initializeHandshake() async throws {
        let executable = "/usr/bin/sourcekit-lsp"
        guard FileManager.default.fileExists(atPath: executable) else {
            // No sourcekit-lsp on this host — skip rather than fail.
            return
        }
        let workspaceRoot = "/tmp/swa-lsp-spike-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: workspaceRoot, withIntermediateDirectories: true,
        )
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        let client = try SourceKitLSPClient(
            workspaceRoot: workspaceRoot,
            executablePath: executable,
            // Smoke test opts in to DEVELOPER_DIR pass-through — the spawned
            // sourcekit-lsp would otherwise have no toolchain selector on
            // hosts where xcrun doesn't auto-resolve.
            options: .init(trustDeveloperDir: true, requireTrustedBinary: true)
        )
        do {
            // Issue the LSP `initialize` request and let it complete.
            // We're not asserting capabilities (the response shape
            // varies by sourcekit-lsp version); we're verifying the
            // JSON-RPC plumbing — header framing, message id
            // round-trip, JSON parse — works against a real server.
            try await client.start()
            await client.shutdown()
        } catch {
            // Surface the error so a regression in the client's
            // framing reads as a test failure rather than a hang.
            Issue.record("sourcekit-lsp handshake failed: \(error)")
        }
    }

    @Test("Init rejects an untrusted (non-root-owned) executable")
    func initRejectsUntrustedBinary() throws {
        // Create a user-owned binary in a tmp dir and verify the trust
        // check refuses to spawn it. This is the regression test for the
        // attacker-plant-a-binary vector flagged in the audit.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swa-sk-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let fakeBinary = tmpDir.appendingPathComponent("sourcekit-lsp")
        // Minimal shell shim — but it's user-owned, not root.
        try "#!/bin/sh\nexit 0\n".write(to: fakeBinary, atomically: true, encoding: .utf8)
        chmod(fakeBinary.path, 0o755)

        do {
            _ = try SourceKitLSPClient(
                workspaceRoot: tmpDir.path,
                executablePath: fakeBinary.path
            )
            Issue.record("Expected untrustedExecutable error, init succeeded")
        } catch SourceKitLSPError.untrustedExecutable {
            // Expected.
        } catch {
            Issue.record("Expected .untrustedExecutable, got \(error)")
        }
    }
}
