//  LSPSymbolResolver.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftStaticAnalysisCore
import Synchronization

// MARK: - LSPSymbolResolver

/// `SymbolResolver` backed by `SourceKitLSPClient`. Queries
/// `workspace/symbol` against a running `sourcekit-lsp` rooted at a
/// build-required workspace. Answers `simpleName` / `qualifiedName`
/// / `selector` / `regex` queries with LSP-precision results
/// (including symbols reachable only through protocol-witness
/// dispatch, which IndexStoreDB-only resolution misses).
///
/// ## Lifecycle
///
/// The resolver owns its `SourceKitLSPClient`. The client is started
/// lazily on the first `resolve(_:)` call via `start()`'s `initialize`
/// handshake; callers must invoke `shutdown()` when done to issue the
/// LSP `shutdown` / `exit` pair and join the subprocess. Drop-in
/// usage via `SymbolFinder.Configuration.lspWorkspaceRoot` handles
/// the lifecycle inside `SymbolFinder.shutdown()`.
///
/// ## Coverage
///
/// `workspace/symbol` returns `SymbolInformation` which has
/// `name`, `kind`, and `location: { uri, range }`. We map those to
/// `SymbolMatch` directly. USR queries are **not** supported —
/// LSP's `workspace/symbol` doesn't accept USRs as input; the
/// resolver throws `LSPSymbolResolverError.usrNotSupported` so
/// callers can fall back. Regex queries pass the regex pattern
/// through as a `workspace/symbol` query; the LSP server applies
/// its own fuzzy match, then we apply the regex client-side to
/// narrow.
///
/// ## Thread safety
///
/// The class is `@unchecked Sendable`. The underlying
/// `SourceKitLSPClient` serialises requests through `await`, so
/// concurrent `resolve(_:)` calls queue at the JSON-RPC layer.
public final class LSPSymbolResolver: @unchecked Sendable {
    /// Spawn a `sourcekit-lsp` rooted at `workspaceRoot`. The
    /// subprocess is started lazily on the first `resolve(_:)` call.
    public init(workspaceRoot: String, executablePath: String = "/usr/bin/sourcekit-lsp") {
        self.workspaceRoot = workspaceRoot
        self.executablePath = executablePath
    }

    deinit {
        // Best-effort: if the client survived a shutdown(), drop it
        // here. Real callers should call `shutdown()` explicitly so
        // the LSP exit handshake completes.
    }

    /// Resolve a query via LSP. Throws on USR queries (not
    /// representable in `workspace/symbol`).
    public func resolve(_ pattern: SymbolQuery.Pattern) async throws -> [SymbolMatch] {
        let client = try await ensureStarted()
        switch pattern {
        case .simpleName(let name):
            return try await workspaceQuery(query: name, client: client) { match in
                match.name == name
            }
        case .qualifiedName(let components):
            // workspace/symbol doesn't accept dotted qualifiers; query
            // by the leaf member name then filter by container.
            guard let memberName = components.last else { return [] }
            let containerChain = Array(components.dropLast())
            return try await workspaceQuery(query: memberName, client: client) { match in
                guard match.name == memberName else { return false }
                guard let container = match.containingType else { return containerChain.isEmpty }
                // Match the immediate parent. Deeper-chain filtering
                // is the syntax resolver's job; LSP only surfaces
                // the immediate container in SymbolInformation.
                return container == (containerChain.last ?? "")
            }
        case .selector(let name, _):
            // LSP doesn't carry signature info on workspace/symbol;
            // narrow by name and let the caller's filter chain apply
            // any selector check downstream.
            return try await workspaceQuery(query: name, client: client) { match in
                match.name == name
            }
        case .qualifiedSelector(let types, let name, _):
            return try await workspaceQuery(query: name, client: client) { match in
                guard match.name == name else { return false }
                guard let container = match.containingType else { return types.isEmpty }
                return container == (types.last ?? "")
            }
        case .regex(let pattern):
            let regex: Regex<AnyRegexOutput>
            do {
                regex = try Regex(pattern)
            } catch {
                return []
            }
            // LSP's workspace/symbol is fuzzy; pass the pattern through
            // (sourcekit-lsp will return its own ranked set) and refine
            // client-side with the full regex.
            return try await workspaceQuery(query: pattern, client: client) { match in
                match.name.wholeMatch(of: regex) != nil
            }
        case .usr:
            throw LSPSymbolResolverError.usrNotSupported
        }
    }

    /// Query `callHierarchy/incomingCalls` for a symbol at the given
    /// source location. Returns the count of incoming call sites,
    /// or `nil` when the LSP server reports no call-hierarchy item
    /// at that position (e.g. position outside any callable, or
    /// LSP not yet ready). Used by the build-required unused-code
    /// pass to filter out false positives — declarations the LSP
    /// server knows are reachable via protocol dispatch are dropped
    /// from the unused list.
    ///
    /// LSP positions are 0-based; callers pass 0-based `line` and
    /// `character` UTF-16 column. Our `SourceLocation` is 1-based;
    /// the `swa` CLI does the conversion at the boundary.
    public func incomingCallCount(uri: String, line: Int, character: Int) async throws -> Int? {
        let client = try await ensureStarted()
        let payload: [String: Any]
        do {
            payload = try await client.incomingCalls(
                uri: uri, line: line, character: character,
            )
        } catch SourceKitLSPError.requestFailed {
            // `prepareCallHierarchy` returned empty — position isn't
            // a callable. Surface as nil so the caller knows we
            // can't answer rather than falsely reporting "no callers".
            return nil
        }
        guard let result = payload["result"] as? [[String: Any]] else {
            return nil
        }
        return result.count
    }

    /// Issue the LSP `shutdown` / `exit` handshake and join the
    /// subprocess. Safe to call multiple times.
    public func shutdown() async {
        let toShutdown: SourceKitLSPClient? = clientState.withLock { stored in
            let value = stored
            stored = nil
            return value
        }
        if let client = toShutdown {
            await client.shutdown()
        }
    }

    // MARK: - Private

    private let workspaceRoot: String
    private let executablePath: String
    /// `Mutex<SourceKitLSPClient?>` for lazy client creation. Using
    /// `Synchronization.Mutex` rather than `NSLock` because the
    /// latter is not async-safe.
    private let clientState: Mutex<SourceKitLSPClient?> = Mutex(nil)

    private func ensureStarted() async throws -> SourceKitLSPClient {
        // Two-phase lazy init: create-or-fetch the client inside the
        // mutex (synchronous), then issue the async `start()` outside
        // the mutex so the LSP handshake can yield to the runtime.
        let client = try clientState.withLock { stored -> SourceKitLSPClient in
            if let existing = stored {
                return existing
            }
            let client = try SourceKitLSPClient(
                workspaceRoot: workspaceRoot,
                executablePath: executablePath,
                // Preserves the historical behaviour of inheriting the
                // parent's toolchain. Resolver is opt-in from the CLI
                // (`--lsp <workspace-root>`), so this is a trusted invocation.
                options: .init(trustDeveloperDir: true, requireTrustedBinary: true)
            )
            stored = client
            return client
        }
        // The `start()` call is idempotent at the protocol level —
        // the LSP server tolerates multiple `initialize` requests
        // (a malformed-state warning would surface in stderr but
        // doesn't trap). Concurrent first-callers thus serialise on
        // the JSON-RPC layer inside the client.
        try await client.start()
        return client
    }

    /// Issue a `workspace/symbol` request and apply a client-side
    /// filter to the parsed `SymbolInformation[]` payload. Maps each
    /// surviving entry to a `SymbolMatch`.
    private func workspaceQuery(
        query: String,
        client: SourceKitLSPClient,
        filter: (LSPSymbolInformation) -> Bool
    ) async throws -> [SymbolMatch] {
        let payload = try await client.workspaceSymbol(query: query)
        var matches: [SymbolMatch] = []
        matches.reserveCapacity(payload.count)
        for entry in payload {
            guard let parsed = LSPSymbolInformation(payload: entry) else { continue }
            guard filter(parsed) else { continue }
            matches.append(parsed.toSymbolMatch())
        }
        return matches
    }
}

// MARK: - LSPSymbolResolverError

public enum LSPSymbolResolverError: Error, Sendable, CustomStringConvertible {
    case usrNotSupported

    public var description: String {
        switch self {
        case .usrNotSupported:
            return
                "LSPSymbolResolver cannot resolve USR queries — workspace/symbol does not accept USRs. Use the IndexStore-backed resolver for USR lookup."
        }
    }
}

// MARK: - LSPSymbolInformation

/// Decoded shape of `SymbolInformation` from a `workspace/symbol`
/// response, narrowed to the fields we need.
struct LSPSymbolInformation {
    let name: String
    let kind: Int
    let containingType: String?
    let file: String
    let line: Int
    let column: Int

    init?(payload: [String: Any]) {
        guard let name = payload["name"] as? String,
            let kind = payload["kind"] as? Int,
            let location = payload["location"] as? [String: Any],
            let uri = location["uri"] as? String,
            let range = location["range"] as? [String: Any],
            let start = range["start"] as? [String: Any],
            let line = start["line"] as? Int,
            let character = start["character"] as? Int
        else {
            return nil
        }
        self.name = name
        self.kind = kind
        self.containingType = payload["containerName"] as? String
        self.file = uri.hasPrefix("file://") ? String(uri.dropFirst("file://".count)) : uri
        self.line = line + 1  // LSP is 0-based; our model is 1-based
        self.column = character + 1
    }

    func toSymbolMatch() -> SymbolMatch {
        SymbolMatch(
            usr: nil,
            name: name,
            kind: lspKindToDeclarationKind(kind),
            accessLevel: .internal,
            file: file,
            line: line,
            column: column,
            isStatic: false,
            containingType: containingType,
            moduleName: nil,
            typeSignature: nil,
            source: .lsp,
        )
    }

    /// Map LSP's `SymbolKind` enum (1-based, well-known LSP spec
    /// values) to our `DeclarationKind`. LSP-spec kinds that have no
    /// direct correspondence fall to `.function` as a safe default.
    private func lspKindToDeclarationKind(_ kind: Int) -> DeclarationKind {
        switch kind {
        case 5: return .class  // Class
        case 6: return .method  // Method
        case 7: return .variable  // Property (LSP) → variable (our model)
        case 8: return .variable  // Field (LSP) → variable
        case 9: return .initializer  // Constructor
        case 10: return .enum  // Enum
        case 11: return .protocol  // Interface
        case 12: return .function  // Function
        case 13: return .variable  // Variable
        case 14: return .constant  // Constant
        case 22: return .enumCase  // EnumMember
        case 23: return .struct  // Struct
        default: return .function
        }
    }
}
