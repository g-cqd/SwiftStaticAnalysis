//  OutputFormat.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - OutputFormat

/// Output format for CLI commands and configuration files.
public enum OutputFormat: String, Sendable, Codable, CaseIterable {
    /// Compact human/LLM-readable text (default).
    case text

    /// Machine-readable JSON.
    case json

    /// Xcode-compatible diagnostic format (`file:line:col: warning: message`).
    case xcode
}
