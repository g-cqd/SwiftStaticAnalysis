//  SharedJSON.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - SharedJSON

/// Process-wide pre-configured `JSONEncoder` / `JSONDecoder` pair for
/// the analyzer's caches and reports.
///
/// `JSONEncoder` and `JSONDecoder` are reference types whose constructors
/// touch class-data-stamped Foundation singletons. Re-instantiating them
/// on every cache load/save was visible in profiles for incremental
/// runs over large codebases (`AnalysisCache.save/load`, `TokenSequence
/// Cache`, `DependencyTracker`). Sharing pre-warmed instances removes
/// that allocation churn.
///
/// Both are `Sendable` because they hold no mutable user-visible state
/// after configuration.
public enum SharedJSON {
    /// Default decoder. ISO8601 dates so cache files survive the
    /// `Date` snapshot/restore round-trip without depending on the
    /// raw `timeIntervalSinceReferenceDate` representation.
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Default encoder. Sorted keys make the output deterministic so
    /// cache files and bench JSON diff cleanly across runs.
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Encoder configured for human-readable artefacts (pretty + sorted).
    /// Used by CLI text output and any consumer that wants stable diffs.
    public static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
