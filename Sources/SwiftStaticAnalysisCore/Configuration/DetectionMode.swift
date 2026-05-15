//  DetectionMode.swift
//  SwiftStaticAnalysis
//  MIT License

// MARK: - DetectionMode

/// Mode for unused code detection.
///
/// Lives in Core (not in `UnusedCodeDetector`) because
/// `IndexStoreFallback.determineAnalysisMode(...preferredMode:)`, which is
/// also in Core, must accept this type as a parameter.
public enum DetectionMode: String, Sendable, Codable, CaseIterable {
    /// Simple reference counting (fast, approximate).
    case simple

    /// Reachability graph analysis (more accurate, considers entry points).
    case reachability

    /// IndexStoreDB-based (most accurate, requires project build).
    case indexStore
}
