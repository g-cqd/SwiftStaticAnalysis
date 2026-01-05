//  UnusedCodeDetector.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import IndexStoreDB
import SwiftStaticAnalysisCore

// MARK: - UnusedCodeDetector

/// Detects unused code in Swift source files.
public struct UnusedCodeDetector: Sendable {
    // MARK: Lifecycle

    public init(configuration: UnusedCodeConfiguration = .default) {
        self.configuration = configuration
        analyzer = StaticAnalyzer()
        // Pre-compile ignore patterns for efficient matching
        compiledIgnorePatterns = CompiledPatterns(configuration.ignoredPatterns)
    }

    // MARK: Public

    /// Configuration for detection.
    public let configuration: UnusedCodeConfiguration

    // MARK: Private

    /// Pre-compiled ignore patterns for efficient matching.
    private let compiledIgnorePatterns: CompiledPatterns

    /// Detect unused code in the given files.
    ///
    /// - Parameter files: Array of Swift file paths.
    /// - Returns: Array of unused code findings.
    public func detectUnused(in files: [String]) async throws -> [UnusedCode] {
        switch configuration.mode {
        case .simple:
            try await detectUnusedWithSyntax(in: files)

        case .reachability:
            try await detectUnusedWithReachability(in: files)

        case .indexStore:
            try await detectUnusedWithIndexStore(in: files)
        }
    }

    /// Detect unused code from source string (for testing).
    ///
    /// - Parameters:
    ///   - source: Swift source code string.
    ///   - file: Virtual file name for reporting.
    /// - Returns: Array of unused code findings.
    public func detectFromSource(_ source: String, file: String) async throws -> [UnusedCode] {
        // Parse the source
        let result = try await analyzer.analyzeSource(source, file: file)

        switch configuration.mode {
        case .simple:
            return detectFromResult(result)

        case .reachability:
            let extractionConfig = DependencyExtractionConfiguration(
                treatPublicAsRoot: configuration.treatPublicAsRoot,
                treatObjcAsRoot: configuration.treatObjcAsRoot,
                treatTestsAsRoot: configuration.treatTestsAsRoot
            )
            let reachabilityDetector = ReachabilityBasedDetector(
                configuration: configuration,
                extractionConfiguration: extractionConfig
            )
            return await reachabilityDetector.detect(in: result)

        case .indexStore:
            // For source strings, fall back to simple mode
            return detectFromResult(result)
        }
    }

    /// Generate a reachability report for the given files.
    ///
    /// - Parameter files: Array of Swift file paths.
    /// - Returns: A reachability report.
    public func generateReachabilityReport(for files: [String]) async throws -> ReachabilityReport {
        let result = try await analyzer.analyze(files)

        let extractionConfig = DependencyExtractionConfiguration(
            treatPublicAsRoot: configuration.treatPublicAsRoot,
            treatObjcAsRoot: configuration.treatObjcAsRoot,
            treatTestsAsRoot: configuration.treatTestsAsRoot,
        )

        let reachabilityDetector = ReachabilityBasedDetector(
            configuration: configuration,
            extractionConfiguration: extractionConfig
        )

        return await reachabilityDetector.generateReport(for: result)
    }

    // MARK: Internal

    /// The analyzer for parsing files.
    let analyzer: StaticAnalyzer
}

// MARK: - Reachability Detection

extension UnusedCodeDetector {
    /// Detect unused code using reachability graph analysis.
    func detectUnusedWithReachability(in files: [String]) async throws -> [UnusedCode] {
        // Analyze all files
        let result = try await analyzer.analyze(files)

        // Configure the reachability detector
        let extractionConfig = DependencyExtractionConfiguration(
            treatPublicAsRoot: configuration.treatPublicAsRoot,
            treatObjcAsRoot: configuration.treatObjcAsRoot,
            treatTestsAsRoot: configuration.treatTestsAsRoot,
            treatProtocolRequirementsAsRoot: true,
            trackProtocolWitnesses: true,
            trackClosureCaptures: true,
        )

        let reachabilityDetector = ReachabilityBasedDetector(
            configuration: configuration,
            extractionConfiguration: extractionConfig
        )

        // Get unreachable code
        var unusedItems = await reachabilityDetector.detect(in: result)

        // Also check for imports if enabled
        if configuration.detectImports {
            let unusedImports = detectUnusedImports(result: result)
            unusedItems.append(contentsOf: unusedImports)
        }

        return
            unusedItems
            .filter { $0.confidence >= configuration.minimumConfidence }
            .sorted { $0.confidence > $1.confidence }
    }
}

// MARK: - Syntax Detection

extension UnusedCodeDetector {
    /// Detect unused code using SwiftSyntax only (fast but approximate).
    func detectUnusedWithSyntax(in files: [String]) async throws -> [UnusedCode] {
        let result = try await analyzer.analyze(files)
        var unusedItems = findUnreferencedDeclarations(in: result)

        if configuration.detectImports {
            unusedItems.append(contentsOf: detectUnusedImports(result: result))
        }

        return unusedItems.sorted { $0.confidence > $1.confidence }
    }

    /// Detect unused code from an analysis result (simple mode).
    func detectFromResult(_ result: AnalysisResult) -> [UnusedCode] {
        findUnreferencedDeclarations(in: result)
            .sorted { $0.confidence > $1.confidence }
    }

    /// Find declarations that are not referenced in the analysis result.
    private func findUnreferencedDeclarations(in result: AnalysisResult) -> [UnusedCode] {
        let referencedIdentifiers = result.references.uniqueIdentifiers

        return result.declarations.declarations.compactMap { declaration -> UnusedCode? in
            guard shouldCheck(declaration) else { return nil }

            let isReferenced = referencedIdentifiers.contains(declaration.name)
            guard !isReferenced else { return nil }

            let confidence = declaration.unusedConfidence
            guard confidence >= configuration.minimumConfidence else { return nil }

            let reason = determineReason(for: declaration, result: result)
            let suggestion = generateSuggestion(for: declaration, reason: reason)

            return UnusedCode(
                declaration: declaration,
                reason: reason,
                confidence: confidence,
                suggestion: suggestion,
            )
        }
    }
}

// MARK: - Declaration Filtering

extension UnusedCodeDetector {
    /// Check if a declaration should be analyzed for unused code.
    func shouldCheck(_ declaration: Declaration) -> Bool {
        // Skip underscore declarations - they're explicitly unused by design
        guard declaration.name != "_" else { return false }

        // Check kind filter
        guard shouldCheckKind(declaration) else { return false }

        // Check access level filter
        guard shouldCheckAccessLevel(declaration) else { return false }

        // Check entry point attributes
        guard !isEntryPoint(declaration) else { return false }

        // Check SwiftUI exclusions
        guard !isSwiftUIExcluded(declaration) else { return false }

        // Check ignored patterns
        guard !matchesIgnoredPattern(declaration) else { return false }

        return true
    }

    /// Check if the declaration kind should be analyzed.
    private func shouldCheckKind(_ declaration: Declaration) -> Bool {
        switch declaration.kind {
        case .constant,
            .variable:
            configuration.detectVariables

        case .function,
            .method:
            configuration.detectFunctions

        case .class,
            .enum,
            .protocol,
            .struct:
            configuration.detectTypes

        case .parameter:
            configuration.detectParameters

        case .import:
            false  // Handled separately

        default:
            true
        }
    }

    /// Check if the declaration access level should be analyzed.
    private func shouldCheckAccessLevel(_ declaration: Declaration) -> Bool {
        if configuration.ignorePublicAPI, declaration.accessLevel >= .public {
            return false
        }
        return true
    }

    /// Check if the declaration is an entry point.
    private func isEntryPoint(_ declaration: Declaration) -> Bool {
        let entryPointAttributes = ["main", "UIApplicationMain", "NSApplicationMain"]
        return declaration.attributes.contains { entryPointAttributes.contains($0) }
    }

    /// Check if the declaration should be excluded due to SwiftUI rules.
    private func isSwiftUIExcluded(_ declaration: Declaration) -> Bool {
        // Ignore SwiftUI property wrappers (@State, @Binding, etc.)
        if configuration.ignoreSwiftUIPropertyWrappers, declaration.hasImplicitUsageWrapper {
            return true
        }

        // Ignore SwiftUI View types
        if configuration.treatSwiftUIViewsAsRoot, declaration.isSwiftUIView {
            return true
        }

        // Ignore PreviewProvider implementations
        if configuration.ignorePreviewProviders, declaration.isSwiftUIPreview {
            return true
        }

        // Ignore View body computed property
        if configuration.ignoreViewBody,
            declaration.name == "body",
            declaration.kind == .variable
        {
            return true
        }

        return false
    }

    /// Check if the declaration matches an ignored pattern.
    private func matchesIgnoredPattern(_ declaration: Declaration) -> Bool {
        compiledIgnorePatterns.anyMatches(declaration.name)
    }
}

// MARK: - Helper Methods

extension UnusedCodeDetector {
    func determineReason(
        for declaration: Declaration,
        result: AnalysisResult,
    ) -> UnusedReason {
        switch declaration.kind {
        case .constant,
            .variable:
            // Check if only written to
            let refs = result.references.find(identifier: declaration.name)
            let hasReads = refs.contains { $0.context == .read }
            if !hasReads, refs.contains(where: { $0.context == .write }) {
                return .onlyAssigned
            }
            return .neverReferenced

        case .parameter:
            return .parameterUnused

        case .import:
            return .importNotUsed

        default:
            return .neverReferenced
        }
    }

    func generateSuggestion(
        for declaration: Declaration,
        reason: UnusedReason,
    ) -> String {
        switch reason {
        case .neverReferenced:
            "Consider removing unused \(declaration.kind.rawValue) '\(declaration.name)'"

        case .onlyAssigned:
            "Variable '\(declaration.name)' is assigned but never read"

        case .onlySelfReferenced:
            "'\(declaration.name)' is only used within its own implementation"

        case .importNotUsed:
            "Import '\(declaration.name)' is not used"

        case .parameterUnused:
            "Parameter '\(declaration.name)' is never used; consider renaming to '_'"
        }
    }

    func detectUnusedImports(result: AnalysisResult) -> [UnusedCode] {
        var unusedImports: [UnusedCode] = []

        // Get all import declarations
        let imports = result.declarations.find(kind: .import)

        // For each import, check if any reference uses that module
        for importDecl in imports {
            let moduleName = importDecl.name

            // Check if any type reference might be from this module
            // This is approximate without semantic analysis
            let potentiallyUsed = result.references.references.contains { ref in
                ref.context == .typeAnnotation || ref.context == .inheritance || ref.context == .call
            }

            // For now, mark as low confidence since we can't be certain
            if !potentiallyUsed {
                unusedImports.append(
                    UnusedCode(
                        declaration: importDecl,
                        reason: .importNotUsed,
                        confidence: .low,
                        suggestion: "Import '\(moduleName)' may not be used",
                    ))
            }
        }

        return unusedImports
    }
}
