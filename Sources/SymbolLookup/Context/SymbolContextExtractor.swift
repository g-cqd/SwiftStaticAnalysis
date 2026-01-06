//  SymbolContextExtractor.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftParser
import SwiftStaticAnalysisCore
import SwiftSyntax

/// Extracts context information for symbol matches.
///
/// This struct provides methods to extract surrounding source code,
/// documentation comments, signatures, bodies, and containing scopes
/// for symbols found via lookup operations.
///
/// ## Thread Safety
///
/// This type is `Sendable`. Each extraction operation reads source files
/// independently and does not maintain mutable state.
///
/// ## Performance
///
/// For best performance when extracting context for multiple symbols in
/// the same file, use the `extractContext(for:in:configuration:)` method
/// which reuses the parsed source and file lines.
public struct SymbolContextExtractor: Sendable {
    private let fileCache: FileContentCache?

    /// Creates a new context extractor.
    ///
    /// - Parameter fileCache: Optional cache for file contents.
    public init(fileCache: FileContentCache? = nil) {
        self.fileCache = fileCache
    }

    /// Extracts context for a symbol match.
    ///
    /// - Parameters:
    ///   - match: The symbol to extract context for.
    ///   - configuration: The context extraction configuration.
    /// - Returns: The extracted context.
    /// - Throws: If the source file cannot be read.
    public func extractContext(
        for match: SymbolMatch,
        configuration: SymbolContextConfiguration
    ) async throws -> SymbolContext {
        guard configuration.wantsContext else {
            return .empty
        }

        let source = try await readFile(match.file)
        let lines = source.components(separatedBy: "\n")

        return try extractContext(for: match, source: source, lines: lines, configuration: configuration)
    }

    /// Extracts context for a symbol match with pre-loaded source.
    ///
    /// Use this method when extracting context for multiple symbols in the
    /// same file to avoid repeated file reads.
    ///
    /// - Parameters:
    ///   - match: The symbol to extract context for.
    ///   - source: The source code of the file.
    ///   - lines: The source split into lines.
    ///   - configuration: The context extraction configuration.
    /// - Returns: The extracted context.
    public func extractContext(
        for match: SymbolMatch,
        source: String,
        lines: [String],
        configuration: SymbolContextConfiguration
    ) throws -> SymbolContext {
        guard configuration.wantsContext else {
            return .empty
        }

        var linesBefore: [SourceLine] = []
        var linesAfter: [SourceLine] = []
        var scopeContent: ScopeContent?
        var completeSignature: String?
        var body: String?
        var documentation: DocumentationComment?
        var declarationSource: String?

        // Extract line context
        if configuration.wantsLines {
            (linesBefore, linesAfter) = extractLineContext(
                lines: lines,
                symbolLine: match.line,
                linesBefore: configuration.linesBefore,
                linesAfter: configuration.linesAfter
            )
        }

        // Extract documentation
        if configuration.includeDocumentation {
            documentation = extractDocumentation(lines: lines, symbolLine: match.line)
        }

        // Parse source for syntax-based extraction
        if configuration.includeSignature || configuration.includeBody || configuration.includeScope {
            let syntaxTree = Parser.parse(source: source)

            // Extract signature and body
            if configuration.includeSignature || configuration.includeBody {
                let finder = DeclarationNodeFinder(
                    targetLine: match.line,
                    targetColumn: match.column
                )
                finder.walk(syntaxTree)

                if let declNode = finder.foundDeclaration {
                    if configuration.includeSignature {
                        completeSignature = extractSignature(from: declNode)
                    }
                    if configuration.includeBody {
                        body = extractBody(from: declNode)
                    }
                    declarationSource = declNode.trimmedDescription
                }
            }

            // Extract scope
            if configuration.includeScope {
                let scopeFinder = ScopeNodeFinder(
                    targetLine: match.line,
                    targetColumn: match.column
                )
                scopeFinder.walk(syntaxTree)

                if let scopeNode = scopeFinder.innermostScope {
                    scopeContent = extractScopeContent(from: scopeNode, source: source)
                }
            }
        }

        return SymbolContext(
            linesBefore: linesBefore,
            linesAfter: linesAfter,
            scopeContent: scopeContent,
            completeSignature: completeSignature,
            body: body,
            documentation: documentation,
            declarationSource: declarationSource
        )
    }

    /// Extracts context for multiple symbols in the same file.
    ///
    /// - Parameters:
    ///   - matches: The symbols to extract context for (must be in same file).
    ///   - configuration: The context extraction configuration.
    /// - Returns: Dictionary mapping matches to their context.
    /// - Throws: If the source file cannot be read.
    public func extractContext(
        for matches: [SymbolMatch],
        configuration: SymbolContextConfiguration
    ) async throws -> [SymbolMatch: SymbolContext] {
        guard configuration.wantsContext, !matches.isEmpty else {
            return [:]
        }

        // Group matches by file
        let byFile = Dictionary(grouping: matches) { $0.file }

        var results: [SymbolMatch: SymbolContext] = [:]
        results.reserveCapacity(matches.count)

        for (file, fileMatches) in byFile {
            let source = try await readFile(file)
            let lines = source.components(separatedBy: "\n")

            for match in fileMatches {
                let context = try extractContext(
                    for: match,
                    source: source,
                    lines: lines,
                    configuration: configuration
                )
                results[match] = context
            }
        }

        return results
    }
}

// MARK: - Line Context Extraction

extension SymbolContextExtractor {
    /// Extracts lines before and after a symbol.
    func extractLineContext(
        lines: [String],
        symbolLine: Int,
        linesBefore: Int,
        linesAfter: Int
    ) -> (before: [SourceLine], after: [SourceLine]) {
        let lineIndex = symbolLine - 1  // Convert to 0-indexed

        // Extract lines before (excluding the symbol line)
        var before: [SourceLine] = []
        let startBefore = max(0, lineIndex - linesBefore)
        for i in startBefore..<lineIndex where i < lines.count {
            before.append(SourceLine(
                lineNumber: i + 1,
                content: lines[i],
                isHighlighted: false
            ))
        }

        // Extract lines after (including and after the symbol line)
        var after: [SourceLine] = []
        let endAfter = min(lines.count, lineIndex + linesAfter + 1)
        for i in lineIndex..<endAfter {
            after.append(SourceLine(
                lineNumber: i + 1,
                content: lines[i],
                isHighlighted: i == lineIndex
            ))
        }

        return (before, after)
    }
}

// MARK: - Documentation Extraction

extension SymbolContextExtractor {
    /// Extracts documentation comment for a symbol.
    func extractDocumentation(lines: [String], symbolLine: Int) -> DocumentationComment? {
        let lineIndex = symbolLine - 1
        guard lineIndex > 0 else { return nil }

        var docLines: [String] = []
        var currentLine = lineIndex - 1

        // Scan backwards for doc comments
        while currentLine >= 0 {
            let line = lines[currentLine].trimmingCharacters(in: .whitespaces)

            // Check for /// style comments
            if line.hasPrefix("///") {
                docLines.insert(line, at: 0)
                currentLine -= 1
                continue
            }

            // Check for block comment end
            if line.hasSuffix("*/") {
                // Find the start of the block comment
                var blockLines: [String] = [line]
                var foundStart = false
                var blockStart = currentLine - 1

                while blockStart >= 0 && !foundStart {
                    let blockLine = lines[blockStart]
                    blockLines.insert(blockLine, at: 0)
                    if blockLine.trimmingCharacters(in: .whitespaces).hasPrefix("/**") {
                        foundStart = true
                    }
                    blockStart -= 1
                }

                if foundStart {
                    docLines = blockLines
                }
                break
            }

            // Skip empty lines between doc and declaration
            if line.isEmpty {
                currentLine -= 1
                continue
            }

            // Skip attributes (@)
            if line.hasPrefix("@") {
                currentLine -= 1
                continue
            }

            // Not a doc comment
            break
        }

        guard !docLines.isEmpty else { return nil }

        let rawComment = docLines.joined(separator: "\n")
        return parseDocumentation(rawComment: rawComment)
    }

    /// Parses a raw documentation comment into structured form.
    func parseDocumentation(rawComment: String) -> DocumentationComment {
        var summary: String?
        var parameters: [ParameterDoc] = []
        var returns: String?
        var throwsDoc: String?
        var notes: [String] = []

        // Clean up comment markers
        let cleanedLines = rawComment.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var cleaned = String(line).trimmingCharacters(in: .whitespaces)
            // Remove /// prefix
            if cleaned.hasPrefix("///") {
                cleaned = String(cleaned.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            // Remove /** prefix
            if cleaned.hasPrefix("/**") {
                cleaned = String(cleaned.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            // Remove */ suffix
            if cleaned.hasSuffix("*/") {
                cleaned = String(cleaned.dropLast(2)).trimmingCharacters(in: .whitespaces)
            }
            // Remove leading * for block comments
            if cleaned.hasPrefix("*") && !cleaned.hasPrefix("*/") {
                cleaned = String(cleaned.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            return cleaned
        }

        var inSummary = true
        var summaryLines: [String] = []
        var currentNoteLines: [String] = []

        for line in cleanedLines {
            let lowercased = line.lowercased()

            // Check for - Parameter:
            if let paramMatch = parseParameterDoc(line) {
                inSummary = false
                parameters.append(paramMatch)
                continue
            }

            // Check for - Returns:
            if lowercased.hasPrefix("- returns:") || lowercased.hasPrefix("- return:") {
                inSummary = false
                returns = String(line.dropFirst(lowercased.hasPrefix("- returns:") ? 10 : 9)).trimmingCharacters(in: .whitespaces)
                continue
            }

            // Check for - Throws:
            if lowercased.hasPrefix("- throws:") {
                inSummary = false
                throwsDoc = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
                continue
            }

            // Check for - Note:
            if lowercased.hasPrefix("- note:") {
                inSummary = false
                if !currentNoteLines.isEmpty {
                    notes.append(currentNoteLines.joined(separator: " "))
                }
                currentNoteLines = [String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)]
                continue
            }

            // Empty line ends summary
            if line.isEmpty && inSummary && !summaryLines.isEmpty {
                inSummary = false
                continue
            }

            if inSummary {
                summaryLines.append(line)
            } else if !currentNoteLines.isEmpty {
                currentNoteLines.append(line)
            }
        }

        if !currentNoteLines.isEmpty {
            notes.append(currentNoteLines.joined(separator: " "))
        }

        if !summaryLines.isEmpty {
            summary = summaryLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if summary?.isEmpty == true {
                summary = nil
            }
        }

        return DocumentationComment(
            summary: summary,
            parameters: parameters,
            returns: returns,
            throws: throwsDoc,
            notes: notes,
            rawComment: rawComment
        )
    }

    /// Parses a parameter documentation line.
    private func parseParameterDoc(_ line: String) -> ParameterDoc? {
        let lowercased = line.lowercased()

        // - Parameter name: description
        if lowercased.hasPrefix("- parameter ") {
            let rest = String(line.dropFirst(12))
            if let colonIndex = rest.firstIndex(of: ":") {
                let name = String(rest[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let desc = String(rest[rest.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                return ParameterDoc(name: name, description: desc)
            }
        }

        // - Parameters:
        //   - name: description
        if lowercased.hasPrefix("- ") && !lowercased.hasPrefix("- parameter") &&
           !lowercased.hasPrefix("- returns") && !lowercased.hasPrefix("- throws") &&
           !lowercased.hasPrefix("- note") && !lowercased.hasPrefix("- return") {
            let rest = String(line.dropFirst(2))
            if let colonIndex = rest.firstIndex(of: ":") {
                let name = String(rest[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let desc = String(rest[rest.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                // Only treat as parameter if the name looks like an identifier
                if name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    return ParameterDoc(name: name, description: desc)
                }
            }
        }

        return nil
    }
}

// MARK: - Signature and Body Extraction

extension SymbolContextExtractor {
    /// Extracts the signature from a declaration node (without body).
    func extractSignature(from node: Syntax) -> String? {
        switch node.as(SyntaxEnum.self) {
        case .functionDecl(let funcDecl):
            return extractFunctionSignature(funcDecl)
        case .initializerDecl(let initDecl):
            return extractInitializerSignature(initDecl)
        case .subscriptDecl(let subDecl):
            return extractSubscriptSignature(subDecl)
        case .variableDecl(let varDecl):
            return extractVariableSignature(varDecl)
        case .classDecl(let classDecl):
            return extractTypeSignature(classDecl, keyword: "class")
        case .structDecl(let structDecl):
            return extractTypeSignature(structDecl, keyword: "struct")
        case .enumDecl(let enumDecl):
            return extractTypeSignature(enumDecl, keyword: "enum")
        case .protocolDecl(let protocolDecl):
            return extractTypeSignature(protocolDecl, keyword: "protocol")
        case .actorDecl(let actorDecl):
            return extractTypeSignature(actorDecl, keyword: "actor")
        case .typeAliasDecl(let aliasDecl):
            return aliasDecl.trimmedDescription
        default:
            return nil
        }
    }

    /// Extracts function signature without body.
    private func extractFunctionSignature(_ decl: FunctionDeclSyntax) -> String {
        var parts: [String] = []

        // Attributes
        if !decl.attributes.isEmpty {
            parts.append(decl.attributes.trimmedDescription)
        }

        // Modifiers
        if !decl.modifiers.isEmpty {
            parts.append(decl.modifiers.trimmedDescription)
        }

        // func keyword and name
        parts.append("func \(decl.name.text)")

        // Generic parameters
        if let generics = decl.genericParameterClause {
            parts.append(generics.trimmedDescription)
        }

        // Signature
        parts.append(decl.signature.trimmedDescription)

        // Generic where clause
        if let whereClause = decl.genericWhereClause {
            parts.append(whereClause.trimmedDescription)
        }

        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Extracts initializer signature without body.
    private func extractInitializerSignature(_ decl: InitializerDeclSyntax) -> String {
        var parts: [String] = []

        if !decl.attributes.isEmpty {
            parts.append(decl.attributes.trimmedDescription)
        }

        if !decl.modifiers.isEmpty {
            parts.append(decl.modifiers.trimmedDescription)
        }

        parts.append("init")

        if let optionalMark = decl.optionalMark {
            parts.append(optionalMark.text)
        }

        if let generics = decl.genericParameterClause {
            parts.append(generics.trimmedDescription)
        }

        parts.append(decl.signature.trimmedDescription)

        if let whereClause = decl.genericWhereClause {
            parts.append(whereClause.trimmedDescription)
        }

        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Extracts subscript signature without body.
    private func extractSubscriptSignature(_ decl: SubscriptDeclSyntax) -> String {
        var parts: [String] = []

        if !decl.attributes.isEmpty {
            parts.append(decl.attributes.trimmedDescription)
        }

        if !decl.modifiers.isEmpty {
            parts.append(decl.modifiers.trimmedDescription)
        }

        parts.append("subscript")

        if let generics = decl.genericParameterClause {
            parts.append(generics.trimmedDescription)
        }

        parts.append(decl.parameterClause.trimmedDescription)
        parts.append(decl.returnClause.trimmedDescription)

        if let whereClause = decl.genericWhereClause {
            parts.append(whereClause.trimmedDescription)
        }

        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Extracts variable/property signature.
    private func extractVariableSignature(_ decl: VariableDeclSyntax) -> String {
        var parts: [String] = []

        if !decl.attributes.isEmpty {
            parts.append(decl.attributes.trimmedDescription)
        }

        if !decl.modifiers.isEmpty {
            parts.append(decl.modifiers.trimmedDescription)
        }

        parts.append(decl.bindingSpecifier.text)

        // Get binding without initializer or accessors
        for binding in decl.bindings {
            var bindingParts: [String] = [binding.pattern.trimmedDescription]
            if let typeAnnotation = binding.typeAnnotation {
                bindingParts.append(typeAnnotation.trimmedDescription)
            }
            parts.append(bindingParts.joined())
        }

        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Extracts type signature without body.
    private func extractTypeSignature<T: DeclSyntaxProtocol>(_ decl: T, keyword: String) -> String {
        // Get everything up to the opening brace
        let source = decl.trimmedDescription
        if let braceIndex = source.firstIndex(of: "{") {
            return String(source[..<braceIndex]).trimmingCharacters(in: .whitespaces)
        }
        return source
    }

    /// Extracts the body of a declaration.
    func extractBody(from node: Syntax) -> String? {
        switch node.as(SyntaxEnum.self) {
        case .functionDecl(let funcDecl):
            return funcDecl.body?.statements.trimmedDescription
        case .initializerDecl(let initDecl):
            return initDecl.body?.statements.trimmedDescription
        case .subscriptDecl(let subDecl):
            return subDecl.accessorBlock?.trimmedDescription
        case .variableDecl(let varDecl):
            // Get accessor block if present
            for binding in varDecl.bindings {
                if let accessors = binding.accessorBlock {
                    return accessors.trimmedDescription
                }
            }
            // Get initializer if present
            for binding in varDecl.bindings {
                if let initializer = binding.initializer {
                    return initializer.value.trimmedDescription
                }
            }
            return nil
        case .classDecl(let classDecl):
            return classDecl.memberBlock.members.trimmedDescription
        case .structDecl(let structDecl):
            return structDecl.memberBlock.members.trimmedDescription
        case .enumDecl(let enumDecl):
            return enumDecl.memberBlock.members.trimmedDescription
        case .actorDecl(let actorDecl):
            return actorDecl.memberBlock.members.trimmedDescription
        default:
            return nil
        }
    }
}

// MARK: - Scope Extraction

extension SymbolContextExtractor {
    /// Extracts scope content from a syntax node.
    func extractScopeContent(from node: Syntax, source: String) -> ScopeContent? {
        let kind: ContextScopeKind
        var name: String?

        switch node.as(SyntaxEnum.self) {
        case .classDecl(let decl):
            kind = .class
            name = decl.name.text
        case .structDecl(let decl):
            kind = .struct
            name = decl.name.text
        case .enumDecl(let decl):
            kind = .enum
            name = decl.name.text
        case .protocolDecl(let decl):
            kind = .protocol
            name = decl.name.text
        case .extensionDecl(let decl):
            kind = .extension
            name = decl.extendedType.trimmedDescription
        case .actorDecl(let decl):
            kind = .actor
            name = decl.name.text
        case .functionDecl(let decl):
            kind = .function
            name = decl.name.text
        case .initializerDecl:
            kind = .initializer
            name = "init"
        case .deinitializerDecl:
            kind = .deinitializer
            name = "deinit"
        case .closureExpr:
            kind = .closure
            name = nil
        case .accessorDecl(let decl):
            kind = .accessor
            name = decl.accessorSpecifier.text
        default:
            kind = .file
            name = nil
        }

        let converter = SourceLocationConverter(fileName: "", tree: node.root)
        let startLoc = node.startLocation(converter: converter)
        let endLoc = node.endLocation(converter: converter)

        return ScopeContent(
            kind: kind,
            name: name,
            startLine: startLoc.line,
            endLine: endLoc.line,
            source: node.trimmedDescription
        )
    }
}

// MARK: - File Reading

extension SymbolContextExtractor {
    /// Reads a file's content.
    private func readFile(_ path: String) async throws -> String {
        if let cache = fileCache {
            return try await cache.content(for: path)
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }
}
