//  Signposter.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

#if canImport(os.signpost)
    @preconcurrency import os.signpost
#endif

// MARK: - Signposter

/// Thin wrapper around `OSSignposter` for instrumenting analyzer phases.
///
/// Use `Signposter.shared.beginInterval(_:)` at the start of an expensive
/// async or sync section and `endInterval(_:)` at the end (or use the
/// `withInterval(_:_:)` convenience). Intervals show up as named regions
/// in Instruments' os_signpost track, which is the canonical way to
/// profile the static-analysis pipeline:
///
/// ```swift
/// try await Signposter.shared.withInterval("SwiftFileParser.parse") {
///     try await parser.parse(path)
/// }
/// ```
///
/// On Linux the signposter compiles to no-ops; the helper keeps the
/// public API stable across platforms.
public struct Signposter: Sendable {
    // MARK: Lifecycle

    /// Create a signposter scoped to a subsystem/category pair. The
    /// shared instance covers the static-analysis namespace.
    public init(subsystem: String, category: String) {
        #if canImport(os.signpost)
            self.poster = OSSignposter(subsystem: subsystem, category: category)
        #endif
    }

    // MARK: Public

    /// Process-wide singleton tagged with the SwiftStaticAnalysis namespace.
    /// Use this for ad-hoc instrumentation; create a dedicated instance
    /// only when you need a separate Instruments category.
    public static let shared = Signposter(
        subsystem: "com.swiftstaticanalysis",
        category: "Analyzer"
    )

    /// Run `body` inside a named signpost interval. Intervals nest
    /// naturally as long as they're balanced.
    @discardableResult
    public func withInterval<T>(
        _ name: StaticString,
        _ body: () throws -> T
    ) rethrows -> T {
        #if canImport(os.signpost)
            let state = poster.beginInterval(name, id: poster.makeSignpostID())
            defer { poster.endInterval(name, state) }
            return try body()
        #else
            return try body()
        #endif
    }

    /// Async variant of ``withInterval(_:_:)``.
    @discardableResult
    public func withInterval<T>(
        _ name: StaticString,
        _ body: () async throws -> T
    ) async rethrows -> T {
        #if canImport(os.signpost)
            let state = poster.beginInterval(name, id: poster.makeSignpostID())
            defer { poster.endInterval(name, state) }
            return try await body()
        #else
            return try await body()
        #endif
    }

    /// Emit a one-shot event signpost (no duration).
    public func emit(_ name: StaticString, _ message: String = "") {
        #if canImport(os.signpost)
            if message.isEmpty {
                poster.emitEvent(name)
            } else {
                poster.emitEvent(name, "\(message, privacy: .public)")
            }
        #endif
    }

    // MARK: Internal

    #if canImport(os.signpost)
        private let poster: OSSignposter
    #endif
}
