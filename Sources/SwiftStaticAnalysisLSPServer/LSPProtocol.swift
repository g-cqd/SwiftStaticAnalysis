//  LSPProtocol.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - JSONRPCID

/// Identifier for a JSON-RPC request. The LSP spec allows either an
/// integer or a string. We model both shapes so we can echo the
/// caller's id verbatim in responses (clients that send strings
/// expect strings back, and vice-versa).
public enum JSONRPCID: Sendable, Hashable, Codable {
    case int(Int)
    case string(String)

    // MARK: Public

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }
        throw DecodingError.typeMismatch(
            JSONRPCID.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected Int or String for JSON-RPC id"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }
}

// MARK: - LSPPosition

/// A zero-based `(line, character)` position in a text document.
public struct LSPPosition: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    // MARK: Public

    /// Zero-based line.
    public let line: Int

    /// Zero-based UTF-16 character offset within the line.
    public let character: Int
}

// MARK: - LSPRange

/// A range in a text document, expressed as half-open `[start, end)`.
public struct LSPRange: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }

    // MARK: Public

    public let start: LSPPosition
    public let end: LSPPosition
}

// MARK: - LSPLocation

/// A `(uri, range)` pair pointing at a specific span in a document.
public struct LSPLocation: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(uri: String, range: LSPRange) {
        self.uri = uri
        self.range = range
    }

    // MARK: Public

    public let uri: String
    public let range: LSPRange
}

// MARK: - LSPDiagnosticSeverity

/// LSP diagnostic severity. Mirrors `DiagnosticSeverity` from the LSP
/// spec — error/warning/information/hint with integer raw values.
public enum LSPDiagnosticSeverity: Int, Sendable, Codable {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4
}

// MARK: - LSPDiagnostic

/// A single diagnostic to be published to the client.
public struct LSPDiagnostic: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(
        range: LSPRange,
        severity: LSPDiagnosticSeverity? = nil,
        code: String? = nil,
        source: String? = nil,
        message: String
    ) {
        self.range = range
        self.severity = severity
        self.code = code
        self.source = source
        self.message = message
    }

    // MARK: Public

    public let range: LSPRange
    public let severity: LSPDiagnosticSeverity?
    public let code: String?
    public let source: String?
    public let message: String
}

// MARK: - LSPTextDocumentIdentifier

/// `{ uri: ... }` envelope used by most `textDocument/*` requests.
public struct LSPTextDocumentIdentifier: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(uri: String) {
        self.uri = uri
    }

    // MARK: Public

    public let uri: String
}

// MARK: - LSPTextDocumentItem

/// Full document state passed in a `textDocument/didOpen` notification.
public struct LSPTextDocumentItem: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(uri: String, languageId: String, version: Int, text: String) {
        self.uri = uri
        self.languageId = languageId
        self.version = version
        self.text = text
    }

    // MARK: Public

    public let uri: String
    public let languageId: String
    public let version: Int
    public let text: String
}

// MARK: - LSPVersionedTextDocumentIdentifier

/// `{ uri, version }` used by `textDocument/didChange`.
public struct LSPVersionedTextDocumentIdentifier: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(uri: String, version: Int) {
        self.uri = uri
        self.version = version
    }

    // MARK: Public

    public let uri: String
    public let version: Int
}

// MARK: - LSPTextDocumentContentChangeEvent

/// A single content change inside a `didChange` notification. We only
/// model the full-replace variant — the server advertises
/// `textDocumentSync.change = Full` in `initialize`, so clients must
/// send full snapshots and may omit `range`/`rangeLength`.
public struct LSPTextDocumentContentChangeEvent: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(text: String) {
        self.text = text
    }

    // MARK: Public

    public let text: String
}

// MARK: - LSPDidOpenParams

public struct LSPDidOpenParams: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(textDocument: LSPTextDocumentItem) {
        self.textDocument = textDocument
    }

    // MARK: Public

    public let textDocument: LSPTextDocumentItem
}

// MARK: - LSPDidChangeParams

public struct LSPDidChangeParams: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(
        textDocument: LSPVersionedTextDocumentIdentifier,
        contentChanges: [LSPTextDocumentContentChangeEvent]
    ) {
        self.textDocument = textDocument
        self.contentChanges = contentChanges
    }

    // MARK: Public

    public let textDocument: LSPVersionedTextDocumentIdentifier
    public let contentChanges: [LSPTextDocumentContentChangeEvent]
}

// MARK: - LSPDidCloseParams

public struct LSPDidCloseParams: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(textDocument: LSPTextDocumentIdentifier) {
        self.textDocument = textDocument
    }

    // MARK: Public

    public let textDocument: LSPTextDocumentIdentifier
}

// MARK: - LSPPublishDiagnosticsParams

/// Params for the server -> client `textDocument/publishDiagnostics`
/// notification.
public struct LSPPublishDiagnosticsParams: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(uri: String, version: Int? = nil, diagnostics: [LSPDiagnostic]) {
        self.uri = uri
        self.version = version
        self.diagnostics = diagnostics
    }

    // MARK: Public

    public let uri: String
    public let version: Int?
    public let diagnostics: [LSPDiagnostic]
}

// MARK: - LSPDocumentDiagnosticParams

public struct LSPDocumentDiagnosticParams: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(textDocument: LSPTextDocumentIdentifier) {
        self.textDocument = textDocument
    }

    // MARK: Public

    public let textDocument: LSPTextDocumentIdentifier
}

// MARK: - LSPDocumentDiagnosticReport

/// Response payload for `textDocument/diagnostic`. We always return a
/// `full` report (no result-id caching) — incremental support is
/// out of scope for this server.
public struct LSPDocumentDiagnosticReport: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(items: [LSPDiagnostic]) {
        self.kind = "full"
        self.items = items
    }

    // MARK: Public

    public let kind: String
    public let items: [LSPDiagnostic]
}

// MARK: - LSPServerCapabilities

/// Subset of LSP server capabilities advertised in the `initialize`
/// response. We intentionally avoid `[String: Any]` for the response
/// payload — every leaf is statically typed.
public struct LSPServerCapabilities: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(
        textDocumentSync: LSPTextDocumentSyncOptions,
        diagnosticProvider: LSPDiagnosticOptions
    ) {
        self.textDocumentSync = textDocumentSync
        self.diagnosticProvider = diagnosticProvider
    }

    // MARK: Public

    public let textDocumentSync: LSPTextDocumentSyncOptions
    public let diagnosticProvider: LSPDiagnosticOptions
}

// MARK: - LSPTextDocumentSyncOptions

/// Sync options advertised to the client. We use `openClose = true`
/// + `change = .full` so each `didChange` carries the entire new
/// document text — simplest correct semantics for a static
/// analyzer that re-tokenises on every change.
public struct LSPTextDocumentSyncOptions: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(openClose: Bool = true, change: LSPTextDocumentSyncKind = .full) {
        self.openClose = openClose
        self.change = change
    }

    // MARK: Public

    public let openClose: Bool
    public let change: LSPTextDocumentSyncKind
}

// MARK: - LSPTextDocumentSyncKind

public enum LSPTextDocumentSyncKind: Int, Sendable, Hashable, Codable {
    case none = 0
    case full = 1
    case incremental = 2
}

// MARK: - LSPDiagnosticOptions

/// Capability advertised for the pull-diagnostic API
/// (`textDocument/diagnostic`).
public struct LSPDiagnosticOptions: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(
        identifier: String = "swa",
        interFileDependencies: Bool = false,
        workspaceDiagnostics: Bool = false
    ) {
        self.identifier = identifier
        self.interFileDependencies = interFileDependencies
        self.workspaceDiagnostics = workspaceDiagnostics
    }

    // MARK: Public

    public let identifier: String
    public let interFileDependencies: Bool
    public let workspaceDiagnostics: Bool
}

// MARK: - LSPInitializeResult

/// Response payload for `initialize`. `serverInfo` is informational
/// only; `capabilities` is the contract.
public struct LSPInitializeResult: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(capabilities: LSPServerCapabilities, serverInfo: LSPServerInfo) {
        self.capabilities = capabilities
        self.serverInfo = serverInfo
    }

    // MARK: Public

    public let capabilities: LSPServerCapabilities
    public let serverInfo: LSPServerInfo
}

// MARK: - LSPServerInfo

public struct LSPServerInfo: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }

    // MARK: Public

    public let name: String
    public let version: String
}

// MARK: - LSPError

/// Error payload returned in a JSON-RPC error response.
public struct LSPError: Sendable, Hashable, Codable, Error {
    // MARK: Lifecycle

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    // MARK: Public

    /// JSON-RPC 2.0 reserved error codes.
    public static let parseError = -32_700
    public static let invalidRequest = -32_600
    public static let methodNotFound = -32_601
    public static let invalidParams = -32_602
    public static let internalError = -32_603

    public let code: Int
    public let message: String
}

// MARK: - URIPathConverter

/// Conversions between `file://` URIs and absolute filesystem paths.
///
/// The LSP wire format uses URIs (`file:///Users/x/Foo.swift`) while
/// the analyzer pipeline expects POSIX paths. This pair of helpers is
/// the canonical seam — every URI -> path or path -> URI conversion in
/// the server must go through here.
public enum URIPathConverter {
    /// Convert a `file://` URI to an absolute filesystem path. Returns
    /// `nil` for non-file URIs or malformed input.
    public static func path(fromURI uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else {
            return nil
        }
        // `URL.path` percent-decodes for us. `url.path(percentEncoded:)`
        // is the modern API but `url.path` is fine for non-iCloud
        // file URLs and avoids the OS-version gate.
        return url.path
    }

    /// Convert an absolute filesystem path to a `file://` URI.
    /// Percent-encodes path components per RFC 3986.
    public static func uri(fromPath path: String) -> String {
        URL(fileURLWithPath: path).absoluteString
    }
}
