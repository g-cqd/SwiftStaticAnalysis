//  Version.swift
//  SwiftStaticAnalysis
//  MIT License

// MARK: - Version

/// The package's semantic version string.
///
/// This is the single source of truth for the version reported by:
///
/// - the `swa` CLI (`--version`),
/// - the `swa-mcp` executable (`--version`),
/// - the `SWAMCPServer` MCP server (advertised to clients during capability
///   negotiation).
///
/// Bump this constant on every release and keep it aligned with `CHANGELOG.md`.
/// A CI / test gate (`SwiftStaticAnalysisCoreTests.testVersion…`) asserts the
/// alignment.
public let swaVersion = "0.3.0-beta.12"
