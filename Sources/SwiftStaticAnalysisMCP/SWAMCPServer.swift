/// SWAMCPServer.swift
/// SwiftStaticAnalysisMCP
/// MIT License

import DuplicationDetector
import Foundation
import MCP
import SwiftStaticAnalysisCore
import SymbolLookup
import UnusedCodeDetector

/// An MCP server that exposes Swift Static Analysis tools for any codebase.
///
/// The server can be initialized with an optional default codebase path. If no path is
/// provided at startup, tools must specify a `codebase_path` parameter for each call.
public actor SWAMCPServer {
    /// The default codebase context (used when no path is specified in tool calls).
    /// Will be nil if the server was started without a default path.
    public let defaultContext: CodebaseContext?

    /// Cache of codebase contexts for dynamic path support.
    private var contextCache: [String: CodebaseContext] = [:]

    /// The MCP server instance.
    private let server: Server

    /// Configuration for unused code detection.
    private var unusedConfig: UnusedCodeConfiguration

    /// Configuration for duplication detection.
    private var duplicationConfig: DuplicationConfiguration

    /// Initialize the SWA MCP server with an optional default codebase.
    /// - Parameter codebasePath: The default root path of the codebase to analyze. If nil,
    ///   tools must specify `codebase_path` for each call.
    /// - Throws: `CodebaseContextError` if the provided path is invalid.
    public init(codebasePath: String? = nil) throws {
        if let codebasePath = codebasePath {
            self.defaultContext = try CodebaseContext(rootPath: codebasePath)
        } else {
            self.defaultContext = nil
        }
        self.unusedConfig = .default
        self.duplicationConfig = .default

        self.server = Server(
            name: "swa-mcp",
            version: "0.1.0",
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )
    }

    /// Get or create a CodebaseContext for the given path.
    /// - Parameter path: The codebase path, or nil to use the default.
    /// - Returns: The CodebaseContext for the specified path.
    /// - Throws: `CodebaseContextError` if no path is provided and no default exists.
    private func getContext(for path: String?) throws -> CodebaseContext {
        if let path = path {
            // Resolve the path
            let expandedPath = NSString(string: path).expandingTildeInPath
            let resolvedPath: String
            if expandedPath.hasPrefix("/") {
                resolvedPath = expandedPath
            } else {
                resolvedPath = FileManager.default.currentDirectoryPath + "/" + expandedPath
            }

            // Check cache first
            if let cached = contextCache[resolvedPath] {
                return cached
            }

            // Create and cache new context
            let context = try CodebaseContext(rootPath: resolvedPath)
            contextCache[resolvedPath] = context
            return context
        }

        // No path provided, use default
        guard let defaultContext = defaultContext else {
            throw CodebaseContextError.noCodebaseSpecified
        }
        return defaultContext
    }

    /// Start the MCP server with the given transport.
    /// - Parameter transport: The transport to use (e.g., `StdioTransport`).
    public func start(transport: any Transport) async throws {
        // Register tool handlers
        await registerToolHandlers()

        // Register resource handlers
        await registerResourceHandlers()

        // Start the server
        try await server.start(transport: transport)
    }

    /// Stop the MCP server.
    public func stop() async {
        await server.stop()
    }
}

// MARK: - Tool Registration

extension SWAMCPServer {
    private func registerToolHandlers() async {
        // List tools
        await server.withMethodHandler(ListTools.self) { [defaultContext] _ in
            .init(tools: Self.buildToolList(defaultRootPath: defaultContext?.rootPath))
        }

        // Call tools
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                return .init(content: [.text("Server unavailable")], isError: true)
            }
            return await self.handleToolCall(params)
        }
    }

    /// Common codebase_path property schema for all tools.
    private static let codebasePathProperty: Value = .object([
        "type": .string("string"),
        "description": .string(
            "Path to the codebase to analyze. Can be absolute or relative. If not specified, uses the default codebase."
        ),
    ])

    private static func buildToolList(defaultRootPath: String?) -> [Tool] {
        [
            Tool(
                name: "get_codebase_info",
                description: "Get information about the codebase including file count, lines of code, and size.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "codebase_path": codebasePathProperty
                    ]),
                    "required": .array([]),
                ])
            ),
            Tool(
                name: "list_swift_files",
                description: "List all Swift files in the codebase. Optionally exclude paths matching glob patterns.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "codebase_path": codebasePathProperty,
                        "exclude_patterns": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Glob patterns to exclude (e.g., '**/Tests/**')"),
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of files to return (default: all)"),
                        ]),
                    ]),
                    "required": .array([]),
                ])
            ),
            Tool(
                name: "detect_unused_code",
                description:
                    "Detect unused code in the codebase including unused functions, types, variables, and imports.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "codebase_path": codebasePathProperty,
                        "mode": .object([
                            "type": .string("string"),
                            "enum": .array([.string("simple"), .string("reachability")]),
                            "description": .string(
                                "Detection mode: 'simple' (fast, syntax-only) or 'reachability' (graph-based, more accurate)"
                            ),
                        ]),
                        "min_confidence": .object([
                            "type": .string("string"),
                            "enum": .array([.string("low"), .string("medium"), .string("high")]),
                            "description": .string("Minimum confidence level for reported issues"),
                        ]),
                        "include_public": .object([
                            "type": .string("boolean"),
                            "description": .string("Whether to include public API in analysis (default: false)"),
                        ]),
                        "treat_public_as_root": .object([
                            "type": .string("boolean"),
                            "description": .string("Treat public API as entry points (default: false)"),
                        ]),
                        "treat_objc_as_root": .object([
                            "type": .string("boolean"),
                            "description": .string("Treat @objc declarations as entry points (default: false)"),
                        ]),
                        "treat_tests_as_root": .object([
                            "type": .string("boolean"),
                            "description": .string("Treat test methods as entry points (default: false)"),
                        ]),
                        "treat_swiftui_views_as_root": .object([
                            "type": .string("boolean"),
                            "description": .string("Treat SwiftUI Views as entry points (default: true)"),
                        ]),
                        "exclude_imports": .object([
                            "type": .string("boolean"),
                            "description": .string("Exclude import statements from analysis (default: false)"),
                        ]),
                        "ignore_swiftui_property_wrappers": .object([
                            "type": .string("boolean"),
                            "description": .string(
                                "Ignore SwiftUI property wrappers (@State, @Binding, etc.) (default: false)"),
                        ]),
                        "ignore_preview_providers": .object([
                            "type": .string("boolean"),
                            "description": .string("Ignore PreviewProvider implementations (default: false)"),
                        ]),
                        "ignore_view_body": .object([
                            "type": .string("boolean"),
                            "description": .string("Ignore View body properties (default: false)"),
                        ]),
                        "index_store_path": .object([
                            "type": .string("string"),
                            "description": .string("Path to IndexStore for enhanced accuracy"),
                        ]),
                        "exclude_paths": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Glob patterns to exclude from analysis"),
                        ]),
                        "paths": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string(
                                "Specific paths within the codebase to analyze (default: entire codebase)"),
                        ]),
                    ]),
                    "required": .array([]),
                ])
            ),
            Tool(
                name: "detect_duplicates",
                description: "Detect duplicate code (clones) in the codebase.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "codebase_path": codebasePathProperty,
                        "clone_types": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("string"),
                                "enum": .array([.string("exact"), .string("near"), .string("semantic")]),
                            ]),
                            "description": .string("Types of clones to detect: 'exact', 'near', 'semantic'"),
                        ]),
                        "min_tokens": .object([
                            "type": .string("integer"),
                            "description": .string("Minimum token count to consider as duplicate (default: 50)"),
                        ]),
                        "min_similarity": .object([
                            "type": .string("number"),
                            "description": .string(
                                "Minimum similarity for near/semantic clones (0.0-1.0, default: 0.8)"),
                        ]),
                        "algorithm": .object([
                            "type": .string("string"),
                            "enum": .array([.string("rollingHash"), .string("suffixArray"), .string("minHashLSH")]),
                            "description": .string("Detection algorithm to use"),
                        ]),
                        "exclude_paths": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Glob patterns to exclude from analysis"),
                        ]),
                        "paths": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string(
                                "Specific paths within the codebase to analyze (default: entire codebase)"),
                        ]),
                    ]),
                    "required": .array([]),
                ])
            ),
            Tool(
                name: "read_file",
                description: "Read the contents of a Swift file within the codebase.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "codebase_path": codebasePathProperty,
                        "path": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Path to the file (relative to codebase root or absolute within codebase)"),
                        ]),
                        "start_line": .object([
                            "type": .string("integer"),
                            "description": .string("Starting line number (1-indexed, optional)"),
                        ]),
                        "end_line": .object([
                            "type": .string("integer"),
                            "description": .string("Ending line number (1-indexed, optional)"),
                        ]),
                    ]),
                    "required": .array([.string("path")]),
                ])
            ),
            Tool(
                name: "search_symbols",
                description: "Search for symbols (functions, types, variables) in the codebase.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "codebase_path": codebasePathProperty,
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Symbol name or pattern to search for"),
                        ]),
                        "kind": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("function"), .string("method"), .string("class"),
                                .string("struct"), .string("enum"), .string("protocol"),
                                .string("variable"), .string("constant"), .string("typealias"),
                            ]),
                            "description": .string("Filter by symbol kind"),
                        ]),
                        "access_level": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("private"), .string("fileprivate"),
                                .string("internal"), .string("public"), .string("open"),
                            ]),
                            "description": .string("Filter by minimum access level"),
                        ]),
                        "definition_only": .object([
                            "type": .string("boolean"),
                            "description": .string("Only return definitions, not references (default: true)"),
                        ]),
                        "use_regex": .object([
                            "type": .string("boolean"),
                            "description": .string("Treat query as a regex pattern (default: false)"),
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of results to return"),
                        ]),
                        "context_lines": .object([
                            "type": .string("integer"),
                            "description": .string("Lines of context before and after symbol"),
                        ]),
                        "context_before": .object([
                            "type": .string("integer"),
                            "description": .string("Lines of context before symbol"),
                        ]),
                        "context_after": .object([
                            "type": .string("integer"),
                            "description": .string("Lines of context after symbol"),
                        ]),
                        "context_scope": .object([
                            "type": .string("boolean"),
                            "description": .string("Include containing scope information"),
                        ]),
                        "context_signature": .object([
                            "type": .string("boolean"),
                            "description": .string("Include complete signature"),
                        ]),
                        "context_body": .object([
                            "type": .string("boolean"),
                            "description": .string("Include declaration body"),
                        ]),
                        "context_documentation": .object([
                            "type": .string("boolean"),
                            "description": .string("Include documentation comments"),
                        ]),
                        "context_all": .object([
                            "type": .string("boolean"),
                            "description": .string("Include all context information"),
                        ]),
                    ]),
                    "required": .array([.string("query")]),
                ])
            ),
            Tool(
                name: "analyze_file",
                description: "Perform full static analysis on a specific Swift file.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "codebase_path": codebasePathProperty,
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Path to the Swift file to analyze"),
                        ]),
                        "include_declarations": .object([
                            "type": .string("boolean"),
                            "description": .string("Include declaration listing (default: true)"),
                        ]),
                        "include_references": .object([
                            "type": .string("boolean"),
                            "description": .string("Include reference listing (default: true)"),
                        ]),
                        "max_references": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum references to return (default: 100)"),
                        ]),
                        "declaration_kinds": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("string"),
                                "enum": .array([
                                    .string("function"), .string("method"), .string("class"),
                                    .string("struct"), .string("enum"), .string("protocol"),
                                    .string("variable"), .string("constant"), .string("typealias"),
                                ]),
                            ]),
                            "description": .string("Filter declarations by kinds"),
                        ]),
                        "include_imports": .object([
                            "type": .string("boolean"),
                            "description": .string("Include import statements (default: true)"),
                        ]),
                        "include_scopes": .object([
                            "type": .string("boolean"),
                            "description": .string("Include scope hierarchy information (default: false)"),
                        ]),
                    ]),
                    "required": .array([.string("path")]),
                ])
            ),
        ]
    }

    private func handleToolCall(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            switch params.name {
            case "get_codebase_info":
                return try await handleGetCodebaseInfo(params.arguments)

            case "list_swift_files":
                return try await handleListSwiftFiles(params.arguments)

            case "detect_unused_code":
                return try await handleDetectUnusedCode(params.arguments)

            case "detect_duplicates":
                return try await handleDetectDuplicates(params.arguments)

            case "read_file":
                return try await handleReadFile(params.arguments)

            case "search_symbols":
                return try await handleSearchSymbols(params.arguments)

            case "analyze_file":
                return try await handleAnalyzeFile(params.arguments)

            default:
                return .init(
                    content: [.text("Unknown tool: \(params.name)")],
                    isError: true
                )
            }
        } catch {
            return .init(
                content: [.text("Error: \(error.localizedDescription)")],
                isError: true
            )
        }
    }
}

// MARK: - Tool Handlers

extension SWAMCPServer {
    private func handleGetCodebaseInfo(_ arguments: [String: Value]?) async throws -> CallTool.Result {
        let codebasePath = arguments?["codebase_path"]?.stringValue
        let context = try getContext(for: codebasePath)

        let info = try context.getCodebaseInfo()
        let json = """
            {
                "root_path": "\(info.rootPath)",
                "swift_file_count": \(info.swiftFileCount),
                "total_lines": \(info.totalLines),
                "total_size": "\(info.formattedSize)"
            }
            """
        return .init(content: [.text(json)], isError: false)
    }

    private func handleListSwiftFiles(_ arguments: [String: Value]?) async throws -> CallTool.Result {
        let codebasePath = arguments?["codebase_path"]?.stringValue
        let context = try getContext(for: codebasePath)

        var excludePatterns: [String] = []
        var limit: Int?

        if let args = arguments {
            if let patterns = args["exclude_patterns"]?.arrayValue {
                excludePatterns = patterns.compactMap { $0.stringValue }
            }
            limit = args["limit"]?.intValue
        }

        var files = try context.findSwiftFiles(excludePatterns: excludePatterns)

        if let limit {
            files = Array(files.prefix(limit))
        }

        // Make paths relative for cleaner output
        let relativePaths = files.map { path -> String in
            if path.hasPrefix(context.rootPath) {
                return String(path.dropFirst(context.rootPath.count + 1))
            }
            return path
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(relativePaths)

        return .init(content: [.text(String(data: json, encoding: .utf8) ?? "[]")], isError: false)
    }

    private func handleDetectUnusedCode(_ arguments: [String: Value]?) async throws -> CallTool.Result {
        let codebasePath = arguments?["codebase_path"]?.stringValue
        let context = try getContext(for: codebasePath)

        var config = UnusedCodeConfiguration.default

        if let args = arguments {
            // Detection mode
            if let modeStr = args["mode"]?.stringValue {
                config.mode = DetectionMode(rawValue: modeStr) ?? .simple
            }

            // Confidence level
            if let confStr = args["min_confidence"]?.stringValue {
                config.minimumConfidence = Confidence(rawValue: confStr) ?? .medium
            }

            // Public API handling
            if let includePublic = args["include_public"]?.boolValue {
                config.ignorePublicAPI = !includePublic
            }

            // Entry point configuration
            if let treatPublicAsRoot = args["treat_public_as_root"]?.boolValue {
                config.treatPublicAsRoot = treatPublicAsRoot
            }
            if let treatObjcAsRoot = args["treat_objc_as_root"]?.boolValue {
                config.treatObjcAsRoot = treatObjcAsRoot
            }
            if let treatTestsAsRoot = args["treat_tests_as_root"]?.boolValue {
                config.treatTestsAsRoot = treatTestsAsRoot
            }
            if let treatSwiftUIViewsAsRoot = args["treat_swiftui_views_as_root"]?.boolValue {
                config.treatSwiftUIViewsAsRoot = treatSwiftUIViewsAsRoot
            }

            // Detection options - exclude_imports means we should NOT detect imports
            if let excludeImports = args["exclude_imports"]?.boolValue {
                config.detectImports = !excludeImports
            }

            // SwiftUI options
            if let ignoreSwiftUIPropertyWrappers = args["ignore_swiftui_property_wrappers"]?.boolValue {
                config.ignoreSwiftUIPropertyWrappers = ignoreSwiftUIPropertyWrappers
            }
            if let ignorePreviewProviders = args["ignore_preview_providers"]?.boolValue {
                config.ignorePreviewProviders = ignorePreviewProviders
            }
            if let ignoreViewBody = args["ignore_view_body"]?.boolValue {
                config.ignoreViewBody = ignoreViewBody
            }

            // Index store path
            if let indexStorePath = args["index_store_path"]?.stringValue {
                config.indexStorePath = indexStorePath
            }
        }

        // Get files to analyze
        var files: [String]
        if let args = arguments, let paths = args["paths"]?.arrayValue {
            let relativePaths = paths.compactMap { $0.stringValue }
            files = try context.validatePaths(relativePaths)
        } else {
            files = try context.findSwiftFiles()
        }

        // Apply path exclusions
        if let args = arguments, let excludePaths = args["exclude_paths"]?.arrayValue {
            let patterns = excludePaths.compactMap { $0.stringValue }
            files = files.filter { file in
                !patterns.contains { pattern in
                    UnusedCodeFilter.matchesGlobPattern(file, pattern: pattern)
                }
            }
        }

        let detector = UnusedCodeDetector(configuration: config)
        let results = try await detector.detectUnused(in: files)

        let output = results.map { unused -> [String: Any] in
            [
                "name": unused.declaration.name,
                "kind": unused.declaration.kind.rawValue,
                "file": String(unused.declaration.location.file.dropFirst(context.rootPath.count + 1)),
                "line": unused.declaration.location.line,
                "reason": unused.reason.rawValue,
                "confidence": unused.confidence.rawValue,
                "suggestion": unused.suggestion,
            ]
        }

        let jsonData = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        return .init(content: [.text(String(data: jsonData, encoding: .utf8) ?? "[]")], isError: false)
    }

    private func handleDetectDuplicates(_ arguments: [String: Value]?) async throws -> CallTool.Result {
        let codebasePath = arguments?["codebase_path"]?.stringValue
        let context = try getContext(for: codebasePath)

        var config = DuplicationConfiguration.default

        if let args = arguments {
            if let typesArray = args["clone_types"]?.arrayValue {
                let types = typesArray.compactMap { $0.stringValue }.compactMap { CloneType(rawValue: $0) }
                if !types.isEmpty {
                    config.cloneTypes = Set(types)
                }
            }
            if let minTokens = args["min_tokens"]?.intValue {
                config.minimumTokens = minTokens
            }
            if let minSim = args["min_similarity"]?.doubleValue {
                config.minimumSimilarity = minSim
            }
            if let algoStr = args["algorithm"]?.stringValue {
                config.algorithm = DetectionAlgorithm(rawValue: algoStr) ?? .rollingHash
            }
        }

        // Get files to analyze
        var files: [String]
        if let args = arguments, let paths = args["paths"]?.arrayValue {
            let relativePaths = paths.compactMap { $0.stringValue }
            files = try context.validatePaths(relativePaths)
        } else {
            files = try context.findSwiftFiles()
        }

        // Apply path exclusions
        if let args = arguments, let excludePaths = args["exclude_paths"]?.arrayValue {
            let patterns = excludePaths.compactMap { $0.stringValue }
            files = files.filter { file in
                !patterns.contains { pattern in
                    UnusedCodeFilter.matchesGlobPattern(file, pattern: pattern)
                }
            }
        }

        let detector = DuplicationDetector(configuration: config)
        let results = try await detector.detectClones(in: files)

        let output = results.map { group -> [String: Any] in
            [
                "type": group.type.rawValue,
                "similarity": group.similarity,
                "occurrences": group.occurrences,
                "duplicated_lines": group.duplicatedLines,
                "clones": group.clones.map { clone -> [String: Any] in
                    [
                        "file": String(clone.file.dropFirst(context.rootPath.count + 1)),
                        "start_line": clone.startLine,
                        "end_line": clone.endLine,
                        "token_count": clone.tokenCount,
                    ]
                },
            ]
        }

        let jsonData = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        return .init(content: [.text(String(data: jsonData, encoding: .utf8) ?? "[]")], isError: false)
    }

    private func handleReadFile(_ arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let args = arguments, let path = args["path"]?.stringValue else {
            return .init(content: [.text("Missing required parameter: path")], isError: true)
        }

        let codebasePath = args["codebase_path"]?.stringValue
        let context = try getContext(for: codebasePath)

        let validatedPath = try context.validatePath(path)
        let content = try String(contentsOfFile: validatedPath, encoding: .utf8)

        var lines = content.components(separatedBy: .newlines)

        if let startLine = args["start_line"]?.intValue,
            let endLine = args["end_line"]?.intValue
        {
            let start = max(1, startLine) - 1
            let end = min(lines.count, endLine)
            lines = Array(lines[start..<end])
        }

        let output = lines.enumerated().map { (index, line) in
            let lineNum = (args["start_line"]?.intValue ?? 1) + index
            return "\(lineNum): \(line)"
        }.joined(separator: "\n")

        return .init(content: [.text(output)], isError: false)
    }

    private func handleSearchSymbols(_ arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let args = arguments, let query = args["query"]?.stringValue else {
            return .init(content: [.text("Missing required parameter: query")], isError: true)
        }

        let codebasePath = args["codebase_path"]?.stringValue
        let context = try getContext(for: codebasePath)

        let files = try context.findSwiftFiles()

        // Build context configuration if requested
        let contextConfig = buildContextConfiguration(from: args)

        // Check if we should use regex matching
        let useRegex = args["use_regex"]?.boolValue ?? false

        let analyzer = StaticAnalyzer()
        let result = try await analyzer.analyze(files)

        var matches = result.declarations.declarations.filter { decl in
            if useRegex {
                return (try? Regex(query).firstMatch(in: decl.name)) != nil
            } else {
                return decl.name.localizedCaseInsensitiveContains(query)
            }
        }

        // Filter by kind if specified
        if let kindStr = args["kind"]?.stringValue,
            let kind = DeclarationKind(rawValue: kindStr)
        {
            matches = matches.filter { $0.kind == kind }
        }

        // Filter by access level if specified
        if let accessStr = args["access_level"]?.stringValue,
            let access = AccessLevel(rawValue: accessStr)
        {
            matches = matches.filter { $0.accessLevel >= access }
        }

        // Apply limit if specified
        if let limit = args["limit"]?.intValue {
            matches = Array(matches.prefix(limit))
        }

        // Extract context for each match if requested
        var contextExtractor: SymbolContextExtractor?
        if contextConfig.wantsContext {
            contextExtractor = SymbolContextExtractor()
        }

        var output: [[String: Any]] = []
        for decl in matches {
            var matchOutput: [String: Any] = [
                "name": decl.name,
                "kind": decl.kind.rawValue,
                "access_level": decl.accessLevel.rawValue,
                "file": String(decl.location.file.dropFirst(context.rootPath.count + 1)),
                "line": decl.location.line,
                "column": decl.location.column,
            ]

            // Add context if requested and extractor is available
            if let extractor = contextExtractor, contextConfig.wantsContext {
                // Create a SymbolMatch from the Declaration for context extraction
                let symbolMatch = SymbolMatch.from(
                    declaration: decl,
                    source: .syntaxTree
                )

                if let symbolContext = try? await extractor.extractContext(
                    for: symbolMatch,
                    configuration: contextConfig
                ) {
                    matchOutput["context"] = buildContextOutput(symbolContext)
                }
            }

            output.append(matchOutput)
        }

        let jsonData = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        return .init(content: [.text(String(data: jsonData, encoding: .utf8) ?? "[]")], isError: false)
    }

    /// Build a SymbolContextConfiguration from MCP arguments.
    private func buildContextConfiguration(from args: [String: Value]) -> SymbolContextConfiguration {
        if args["context_all"]?.boolValue == true {
            return .all
        }

        let contextLines = args["context_lines"]?.intValue ?? 0
        let contextBefore = args["context_before"]?.intValue ?? contextLines
        let contextAfter = args["context_after"]?.intValue ?? contextLines

        return SymbolContextConfiguration(
            linesBefore: contextBefore,
            linesAfter: contextAfter,
            includeScope: args["context_scope"]?.boolValue ?? false,
            includeSignature: args["context_signature"]?.boolValue ?? false,
            includeBody: args["context_body"]?.boolValue ?? false,
            includeDocumentation: args["context_documentation"]?.boolValue ?? false
        )
    }

    /// Build context output dictionary for JSON serialization.
    private func buildContextOutput(_ context: SymbolContext) -> [String: Any] {
        var output: [String: Any] = [:]

        if !context.linesBefore.isEmpty {
            output["lines_before"] = context.linesBefore.map { line in
                ["line_number": line.lineNumber, "content": line.content]
            }
        }

        if !context.linesAfter.isEmpty {
            output["lines_after"] = context.linesAfter.map { line in
                ["line_number": line.lineNumber, "content": line.content]
            }
        }

        if let scope = context.scopeContent {
            output["scope"] = [
                "kind": scope.kind.rawValue,
                "name": scope.name as Any,
                "start_line": scope.startLine,
                "end_line": scope.endLine,
            ]
        }

        if let signature = context.completeSignature {
            output["signature"] = signature
        }

        if let body = context.body {
            output["body"] = body
        }

        if let doc = context.documentation, doc.hasContent {
            var docOutput: [String: Any] = [:]
            if let summary = doc.summary {
                docOutput["summary"] = summary
            }
            if !doc.parameters.isEmpty {
                docOutput["parameters"] = doc.parameters.map { param in
                    ["name": param.name, "description": param.description]
                }
            }
            if let returns = doc.returns {
                docOutput["returns"] = returns
            }
            if let throwsDoc = doc.throws {
                docOutput["throws"] = throwsDoc
            }
            output["documentation"] = docOutput
        }

        return output
    }

    private func handleAnalyzeFile(_ arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let args = arguments, let path = args["path"]?.stringValue else {
            return .init(content: [.text("Missing required parameter: path")], isError: true)
        }

        let codebasePath = args["codebase_path"]?.stringValue
        let context = try getContext(for: codebasePath)

        // Parse options
        let includeDeclarations = args["include_declarations"]?.boolValue ?? true
        let includeReferences = args["include_references"]?.boolValue ?? true
        let maxReferences = args["max_references"]?.intValue ?? 100
        let includeImports = args["include_imports"]?.boolValue ?? true
        let includeScopes = args["include_scopes"]?.boolValue ?? false

        // Parse declaration kind filters
        var kindFilters: Set<DeclarationKind>?
        if let kindsArray = args["declaration_kinds"]?.arrayValue {
            let kinds = kindsArray.compactMap { $0.stringValue }.compactMap { DeclarationKind(rawValue: $0) }
            if !kinds.isEmpty {
                kindFilters = Set(kinds)
            }
        }

        let validatedPath = try context.validatePath(path)
        let analyzer = StaticAnalyzer()
        let result = try await analyzer.analyze([validatedPath])

        var output: [String: Any] = [
            "file": String(validatedPath.dropFirst(context.rootPath.count + 1)),
            "declaration_count": result.declarations.declarations.count,
            "reference_count": result.references.references.count,
        ]

        if includeDeclarations {
            var declarations = result.declarations.declarations

            // Filter by kind if specified
            if let filters = kindFilters {
                declarations = declarations.filter { filters.contains($0.kind) }
            }

            // Filter out imports if requested
            if !includeImports {
                declarations = declarations.filter { $0.kind != .import }
            }

            let declarationsOutput = declarations.map { decl -> [String: Any] in
                var declOutput: [String: Any] = [
                    "name": decl.name,
                    "kind": decl.kind.rawValue,
                    "access_level": decl.accessLevel.rawValue,
                    "line": decl.location.line,
                ]

                // Include scope info if requested
                if includeScopes {
                    declOutput["scope_id"] = decl.scope.id
                }

                // Include additional metadata for better context
                if !decl.genericParameters.isEmpty {
                    declOutput["generic_parameters"] = decl.genericParameters
                }
                if let sig = decl.signature {
                    declOutput["signature"] = sig.displayString
                }

                return declOutput
            }
            output["declarations"] = declarationsOutput
        }

        if includeReferences {
            let references = result.references.references.prefix(maxReferences).map { ref -> [String: Any] in
                [
                    "identifier": ref.identifier,
                    "context": ref.context.rawValue,
                    "line": ref.location.line,
                ]
            }
            output["references"] = Array(references)
        }

        // Include scope hierarchy if requested
        if includeScopes {
            let scopes = result.scopes.scopes.values.map { scope -> [String: Any] in
                [
                    "id": scope.id.id,
                    "kind": scope.kind.rawValue,
                    "name": scope.name ?? "",
                    "line": scope.location.line,
                    "parent_id": scope.parent?.id as Any,
                ]
            }
            output["scopes"] = scopes
        }

        let jsonData = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        return .init(content: [.text(String(data: jsonData, encoding: .utf8) ?? "{}")], isError: false)
    }
}

// MARK: - Resource Registration

extension SWAMCPServer {
    private func registerResourceHandlers() async {
        // List resources
        await server.withMethodHandler(ListResources.self) { [defaultContext] _ in
            if let context = defaultContext {
                return .init(
                    resources: [
                        Resource(
                            name: "Codebase Root",
                            uri: "file://\(context.rootPath)",
                            description: "Root directory of the analyzed codebase",
                            mimeType: "inode/directory"
                        )
                    ],
                    nextCursor: nil
                )
            } else {
                return .init(resources: [], nextCursor: nil)
            }
        }

        // Read resource
        await server.withMethodHandler(ReadResource.self) { [defaultContext] params in
            let uri = params.uri

            // Only allow resources within the sandbox
            guard uri.hasPrefix("file://") else {
                throw MCPError.invalidRequest("Only file:// URIs are supported")
            }

            guard let context = defaultContext else {
                throw MCPError.invalidRequest("No default codebase configured. Resources are unavailable.")
            }

            let path = String(uri.dropFirst(7))

            do {
                let validatedPath = try context.validatePath(path)

                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: validatedPath, isDirectory: &isDirectory) else {
                    throw MCPError.invalidRequest("Resource not found: \(path)")
                }

                if isDirectory.boolValue {
                    // Return directory listing
                    let contents = try FileManager.default.contentsOfDirectory(atPath: validatedPath)
                        .filter { !$0.hasPrefix(".") }
                        .sorted()
                        .joined(separator: "\n")
                    return .init(contents: [.text(contents, uri: uri)])
                } else {
                    // Return file contents
                    let content = try String(contentsOfFile: validatedPath, encoding: .utf8)
                    return .init(contents: [.text(content, uri: uri)])
                }
            } catch let error as CodebaseContextError {
                throw MCPError.invalidRequest(error.localizedDescription)
            }
        }
    }
}

// MARK: - Value Extensions

extension Value {
    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        default: return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        default: return nil
        }
    }

    var arrayValue: [Value]? {
        switch self {
        case .array(let value): return value
        default: return nil
        }
    }
}
