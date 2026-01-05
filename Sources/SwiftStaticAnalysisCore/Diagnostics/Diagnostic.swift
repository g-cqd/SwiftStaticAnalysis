//  Diagnostic.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - DiagnosticSeverity

/// Severity levels for diagnostics.
public enum DiagnosticSeverity: String, Sendable, Codable, CaseIterable {
    case error
    case warning
    case note
    case remark

    // MARK: Public

    /// Xcode-compatible string representation.
    public var xcodeString: String {
        rawValue
    }
}

// MARK: - DiagnosticCategory

/// Categories for diagnostics.
/// Exhaustive coverage for all diagnostic categories. // swa:ignore-unused-cases
public enum DiagnosticCategory: String, Sendable, Codable {
    case unusedCode = "unused-code"
    case duplication
    case style
    case performance
    case security
    case general
}

// MARK: - Diagnostic

/// Represents a single diagnostic message.
public struct Diagnostic: Sendable, Codable, Hashable {
    // MARK: Lifecycle

    public init(
        file: String,
        line: Int,
        column: Int,
        severity: DiagnosticSeverity,
        message: String,
        category: DiagnosticCategory = .general,
        ruleID: String? = nil,
        fixIt: FixIt? = nil,
        notes: [Self] = [],
    ) {
        self.file = file
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
        self.category = category
        self.ruleID = ruleID
        self.fixIt = fixIt
        self.notes = notes
    }

    // MARK: Public

    /// Location in source.
    public let file: String
    public let line: Int
    public let column: Int

    /// Severity level.
    public let severity: DiagnosticSeverity

    /// The diagnostic message.
    public let message: String

    /// Optional category.
    public let category: DiagnosticCategory

    /// Optional rule/check identifier.
    public let ruleID: String?

    /// Optional fix-it suggestion.
    public let fixIt: FixIt?

    /// Related notes (secondary diagnostics).
    public let notes: [Self]

    /// Unique identifier for deduplication.
    public var uniqueKey: String {
        "\(file):\(line):\(column):\(severity.rawValue):\(message.hashValue)"
    }

    /// Xcode-compatible string representation.
    ///
    /// Format: `/path/to/file.swift:42:5: warning: message`
    public var xcodeFormat: String {
        "\(file):\(line):\(column): \(severity.xcodeString): \(message)"
    }

    /// Xcode-compatible string including notes.
    public var xcodeFormatWithNotes: String {
        var result = xcodeFormat
        for note in notes {
            result += "\n\(note.xcodeFormat)"
        }
        return result
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.file == rhs.file && lhs.line == rhs.line && lhs.column == rhs.column && lhs.severity == rhs.severity
            && lhs.message == rhs.message
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(file)
        hasher.combine(line)
        hasher.combine(column)
        hasher.combine(severity)
        hasher.combine(message)
    }

    /// Create a copy of this diagnostic with additional notes appended.
    public func withNotes(_ additionalNotes: [Self]) -> Self {
        Self(
            file: file,
            line: line,
            column: column,
            severity: severity,
            message: message,
            category: category,
            ruleID: ruleID,
            fixIt: fixIt,
            notes: notes + additionalNotes,
        )
    }

    /// Create a copy of this diagnostic with a new set of notes.
    public func replacingNotes(_ newNotes: [Self]) -> Self {
        Self(
            file: file,
            line: line,
            column: column,
            severity: severity,
            message: message,
            category: category,
            ruleID: ruleID,
            fixIt: fixIt,
            notes: newNotes,
        )
    }
}

// MARK: - FixIt

/// A suggested fix for a diagnostic.
public struct FixIt: Sendable, Codable, Hashable {
    // MARK: Lifecycle

    public init(description: String, edits: [TextEdit]) {
        self.description = description
        self.edits = edits
    }

    // MARK: Public

    /// Description of the fix.
    public let description: String

    /// Text edits to apply.
    public let edits: [TextEdit]
}

// MARK: - TextEdit

/// A text edit for a fix-it.
public struct TextEdit: Sendable, Codable, Hashable {
    // MARK: Lifecycle

    public init(file: String, startOffset: Int, endOffset: Int, replacement: String) {
        self.file = file
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.replacement = replacement
    }

    // MARK: Public

    /// File to edit.
    public let file: String

    /// Start offset in file.
    public let startOffset: Int

    /// End offset in file.
    public let endOffset: Int

    /// Replacement text.
    public let replacement: String
}

// MARK: - DiagnosticBuilder

/// Builder for creating diagnostics.
public struct DiagnosticBuilder {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public func file(_ file: String) -> Self {
        var copy = self
        copy.file = file
        return copy
    }

    public func location(line: Int, column: Int) -> Self {
        var copy = self
        copy.line = line
        copy.column = column
        return copy
    }

    public func severity(_ severity: DiagnosticSeverity) -> Self {
        var copy = self
        copy.severity = severity
        return copy
    }

    public func message(_ message: String) -> Self {
        var copy = self
        copy.message = message
        return copy
    }

    public func category(_ category: DiagnosticCategory) -> Self {
        var copy = self
        copy.category = category
        return copy
    }

    public func ruleID(_ ruleID: String) -> Self {
        var copy = self
        copy.ruleID = ruleID
        return copy
    }

    public func fixIt(_ fixIt: FixIt) -> Self {
        var copy = self
        copy.fixIt = fixIt
        return copy
    }

    public func note(_ note: Diagnostic) -> Self {
        var copy = self
        copy.notes.append(note)
        return copy
    }

    public func build() -> Diagnostic {
        Diagnostic(
            file: file,
            line: line,
            column: column,
            severity: severity,
            message: message,
            category: category,
            ruleID: ruleID,
            fixIt: fixIt,
            notes: notes,
        )
    }

    // MARK: Private

    private var file: String = ""
    private var line: Int = 1
    private var column: Int = 1
    private var severity: DiagnosticSeverity = .warning
    private var message: String = ""
    private var category: DiagnosticCategory = .general
    private var ruleID: String?
    private var fixIt: FixIt?
    private var notes: [Diagnostic] = []
}
