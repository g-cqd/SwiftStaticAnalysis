//  AnalysisLogger.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import OSLog

// MARK: - AnalysisLogLevel

/// Log level used by analysis components.
public enum AnalysisLogLevel: Sendable, Equatable {
    case notice
    case warning
    case error
}

// MARK: - AnalysisLogger

/// Lightweight, sendable logger wrapper for library targets.
public struct AnalysisLogger: Sendable {
    // MARK: Lifecycle

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    // MARK: Public

    public typealias Handler = @Sendable (AnalysisLogLevel, String) -> Void

    /// Logger that discards all messages.
    public static let disabled = Self { _, _ in }

    /// Create a logger backed by `OSLog`.
    public static func osLog(
        subsystem: String = "SwiftStaticAnalysis",
        category: String
    ) -> Self {
        let logger = Logger(subsystem: subsystem, category: category)

        return Self { level, message in
            switch level {
            case .notice:
                logger.notice("\(message, privacy: .public)")
            case .warning:
                logger.warning("\(message, privacy: .public)")
            case .error:
                logger.error("\(message, privacy: .public)")
            }
        }
    }

    public func log(_ level: AnalysisLogLevel, _ message: String) {
        handler(level, message)
    }

    public func notice(_ message: String) {
        log(.notice, message)
    }

    public func warning(_ message: String) {
        log(.warning, message)
    }

    public func error(_ message: String) {
        log(.error, message)
    }

    // MARK: Private

    private let handler: Handler
}
