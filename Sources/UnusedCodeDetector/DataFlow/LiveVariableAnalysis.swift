//
//  LiveVariableAnalysis.swift
//  SwiftStaticAnalysis
//
//  Backward data flow analysis for live variable detection.
//  Computes which variables are "live" (may be read before being written)
//  at each program point. Used for detecting dead stores and unused variables.
//
//  Equations:
//    LIVE_in[B] = USE[B] ∪ (LIVE_out[B] - DEF[B])
//    LIVE_out[B] = ∪ LIVE_in[S] for all successors S of B
//

import Foundation
import SwiftStaticAnalysisCore
import SwiftSyntax

// MARK: - DeadStore

/// Represents an assignment to a variable that is never read.
public struct DeadStore: Sendable {
    // MARK: Lifecycle

    public init(
        variable: String,
        location: SwiftStaticAnalysisCore.SourceLocation,
        assignedValue: String? = nil,
        suggestion: String = "Consider removing this assignment",
    ) {
        self.variable = variable
        self.location = location
        self.assignedValue = assignedValue
        self.suggestion = suggestion
    }

    // MARK: Public

    /// The variable being assigned.
    public let variable: String

    /// Location of the dead store.
    public let location: SwiftStaticAnalysisCore.SourceLocation

    /// The expression being assigned (if simple).
    public let assignedValue: String?

    /// Suggested fix.
    public let suggestion: String
}

// MARK: - LiveVariableResult

/// Results from live variable analysis.
public struct LiveVariableResult: Sendable {
    // MARK: Lifecycle

    public init(
        cfg: ControlFlowGraph,
        deadStores: [DeadStore],
        unusedVariables: Set<String>,
        liveIn: [BlockID: Set<String>],
        liveOut: [BlockID: Set<String>],
    ) {
        self.cfg = cfg
        self.deadStores = deadStores
        self.unusedVariables = unusedVariables
        self.liveIn = liveIn
        self.liveOut = liveOut
    }

    // MARK: Public

    /// The analyzed CFG.
    public let cfg: ControlFlowGraph

    /// Dead stores found.
    public let deadStores: [DeadStore]

    /// Variables that are defined but never used.
    public let unusedVariables: Set<String>

    /// Live-in sets for each block.
    public let liveIn: [BlockID: Set<String>]

    /// Live-out sets for each block.
    public let liveOut: [BlockID: Set<String>]
}

// MARK: - LiveVariableAnalysis

/// Performs backward data flow analysis to find live variables.
public struct LiveVariableAnalysis: Sendable {
    // MARK: Lifecycle

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: Public

    /// Configuration for the analysis.
    public struct Configuration: Sendable {
        // MARK: Lifecycle

        public init(
            maxIterations: Int = 1000,
            detectDeadStores: Bool = true,
            interProcedural: Bool = false,
            ignoredVariables: Set<String> = ["_"],
        ) {
            self.maxIterations = maxIterations
            self.detectDeadStores = detectDeadStores
            self.interProcedural = interProcedural
            self.ignoredVariables = ignoredVariables
        }

        // MARK: Public

        public static let `default` = Configuration()

        /// Maximum iterations for fixed-point computation.
        public var maxIterations: Int

        /// Whether to detect dead stores.
        public var detectDeadStores: Bool

        /// Whether to track variables across function boundaries (conservative).
        public var interProcedural: Bool

        /// Variables to ignore in analysis.
        public var ignoredVariables: Set<String>
    }

    /// Analyze a control flow graph for live variables.
    ///
    /// - Parameter cfg: The control flow graph to analyze.
    /// - Returns: Analysis results including dead stores and unused variables.
    public func analyze(_ cfg: ControlFlowGraph) -> LiveVariableResult {
        var workCFG = cfg

        // Compute live variables using worklist algorithm
        let (liveIn, liveOut) = computeLiveVariables(&workCFG)

        // Find dead stores if enabled
        var deadStores: [DeadStore] = []
        if configuration.detectDeadStores {
            deadStores = findDeadStores(cfg: workCFG, liveOut: liveOut)
        }

        // Find completely unused variables
        let unusedVars = findUnusedVariables(cfg: workCFG, liveIn: liveIn)

        return LiveVariableResult(
            cfg: workCFG,
            deadStores: deadStores,
            unusedVariables: unusedVars,
            liveIn: liveIn,
            liveOut: liveOut,
        )
    }

    /// Analyze a function declaration.
    public func analyzeFunction(
        _ function: FunctionDeclSyntax,
        file: String,
        tree: SourceFileSyntax,
    ) -> LiveVariableResult {
        let builder = CFGBuilder(file: file, tree: tree)
        let cfg = builder.buildCFG(from: function)
        return analyze(cfg)
    }

    /// Analyze a closure expression.
    public func analyzeClosure(
        _ closure: ClosureExprSyntax,
        file: String,
        tree: SourceFileSyntax,
    ) -> LiveVariableResult {
        let builder = CFGBuilder(file: file, tree: tree)
        let cfg = builder.buildCFG(from: closure)
        return analyze(cfg)
    }

    // MARK: Private

    private let configuration: Configuration

    // MARK: - Worklist Algorithm

    /// Compute live variables using iterative worklist algorithm.
    private func computeLiveVariables(
        _ cfg: inout ControlFlowGraph,
    ) -> (liveIn: [BlockID: Set<String>], liveOut: [BlockID: Set<String>]) {
        var liveIn: [BlockID: Set<String>] = [:]
        var liveOut: [BlockID: Set<String>] = [:]

        // Initialize all blocks
        for id in cfg.blockOrder {
            liveIn[id] = []
            liveOut[id] = []
        }

        // Worklist (use postorder for backward analysis)
        var worklist = Set(cfg.blockOrder)
        var iterations = 0

        while !worklist.isEmpty, iterations < configuration.maxIterations {
            iterations += 1

            let blockID = worklist.removeFirst()
            guard let block = cfg.blocks[blockID] else { continue }

            // Compute LIVE_out = ∪ LIVE_in[S] for all successors S
            var newLiveOut = Set<String>()
            for succID in block.successors {
                if let succLiveIn = liveIn[succID] {
                    newLiveOut.formUnion(succLiveIn)
                }
            }

            // Compute LIVE_in = USE ∪ (LIVE_out - DEF)
            var newLiveIn = block.use
            newLiveIn.formUnion(newLiveOut.subtracting(block.def))

            // Remove ignored variables
            newLiveIn.subtract(configuration.ignoredVariables)
            newLiveOut.subtract(configuration.ignoredVariables)

            // Check for changes
            if newLiveIn != liveIn[blockID] || newLiveOut != liveOut[blockID] {
                liveIn[blockID] = newLiveIn
                liveOut[blockID] = newLiveOut

                // Update CFG block
                cfg.blocks[blockID]?.liveIn = newLiveIn
                cfg.blocks[blockID]?.liveOut = newLiveOut

                // Add predecessors to worklist
                worklist.formUnion(block.predecessors)
            }
        }

        return (liveIn, liveOut)
    }

    // MARK: - Dead Store Detection

    /// Find assignments to variables that are not live after the assignment.
    private func findDeadStores(
        cfg: ControlFlowGraph,
        liveOut: [BlockID: Set<String>],
    ) -> [DeadStore] {
        var deadStores: [DeadStore] = []

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }

            // Compute liveness at each statement point (backward within block)
            var liveAtPoint = liveOut[id] ?? []

            // Process statements in reverse order
            for statement in block.statements.reversed() {
                // Check each defined variable
                for definedVar in statement.defs {
                    // Skip ignored variables
                    if configuration.ignoredVariables.contains(definedVar) {
                        continue
                    }

                    // If defined variable is not live after this point, it's a dead store
                    if !liveAtPoint.contains(definedVar) {
                        // Check if variable is used in the same statement (like x = x + 1)
                        let usedInSameStatement = statement.uses.contains(definedVar)

                        if !usedInSameStatement {
                            deadStores.append(DeadStore(
                                variable: definedVar,
                                location: statement.location,
                                assignedValue: extractAssignedValue(statement),
                                suggestion: "Variable '\(definedVar)' is assigned but never read",
                            ))
                        }
                    }
                }

                // Update liveness for this point
                // LIVE_before = USE ∪ (LIVE_after - DEF)
                liveAtPoint.subtract(statement.defs)
                liveAtPoint.formUnion(statement.uses)
            }
        }

        return deadStores
    }

    /// Extract the assigned value from a statement (if simple).
    private func extractAssignedValue(_ statement: CFGStatement) -> String? {
        let desc = statement.syntax.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if desc.count < 100 {
            return desc
        }
        return nil
    }

    // MARK: - Unused Variable Detection

    /// Find variables that are defined but never used anywhere.
    private func findUnusedVariables(
        cfg: ControlFlowGraph,
        liveIn: [BlockID: Set<String>],
    ) -> Set<String> {
        // Collect all defined variables
        var allDefined = Set<String>()
        var allUsed = Set<String>()

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }
            allDefined.formUnion(block.def)
            allUsed.formUnion(block.use)
        }

        // Remove ignored variables
        allDefined.subtract(configuration.ignoredVariables)

        // Find variables defined but never used
        let unused = allDefined.subtracting(allUsed)

        return unused
    }
}

// MARK: - Statement-Level Analysis

public extension LiveVariableAnalysis {
    /// Compute live variables at each statement in a block.
    ///
    /// - Parameters:
    ///   - block: The basic block to analyze.
    ///   - liveAtExit: Variables live at block exit.
    /// - Returns: Array of (statement, liveBeforeStatement) pairs.
    func computeStatementLiveness(
        block: BasicBlock,
        liveAtExit: Set<String>,
    ) -> [(statement: CFGStatement, liveBefore: Set<String>)] {
        var result: [(CFGStatement, Set<String>)] = []
        var live = liveAtExit

        // Process statements in reverse order
        for statement in block.statements.reversed() {
            // LIVE_before = USE ∪ (LIVE_after - DEF)
            var liveBefore = live
            liveBefore.subtract(statement.defs)
            liveBefore.formUnion(statement.uses)

            result.append((statement, liveBefore))
            live = liveBefore
        }

        return result.reversed()
    }
}

// MARK: - Multi-Function Analysis

public extension LiveVariableAnalysis {
    /// Analyze all functions in a source file.
    ///
    /// - Parameters:
    ///   - file: Path to the Swift source file.
    ///   - tree: Parsed syntax tree.
    /// - Returns: Array of results for each function/closure.
    func analyzeFile(
        file: String,
        tree: SourceFileSyntax,
    ) -> [LiveVariableResult] {
        var results: [LiveVariableResult] = []

        // Collect all functions and closures
        let collector = FunctionCollector()
        collector.walk(tree)

        let builder = CFGBuilder(file: file, tree: tree)

        // Analyze each function
        for function in collector.functions {
            let cfg = builder.buildCFG(from: function)
            let result = analyze(cfg)
            results.append(result)
        }

        return results
    }
}

// MARK: - FunctionCollector

/// Collects function declarations from a syntax tree.
private final class FunctionCollector: SyntaxVisitor {
    // MARK: Lifecycle

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: Internal

    var functions: [FunctionDeclSyntax] = []
    var initializers: [InitializerDeclSyntax] = []
    var closures: [ClosureExprSyntax] = []

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        functions.append(node)
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        initializers.append(node)
        return .visitChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        closures.append(node)
        return .visitChildren
    }
}

// MARK: - Debug Output

public extension LiveVariableResult {
    /// Generate a debug string showing liveness information.
    func debugDescription() -> String {
        var output = "Live Variable Analysis Results:\n"
        output += "================================\n\n"

        output += "Function: \(cfg.functionName)\n\n"

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }
            output += "Block \(id.value):\n"
            output += "  LIVE_in:  {\(liveIn[id]?.sorted().joined(separator: ", ") ?? "")}\n"
            output += "  LIVE_out: {\(liveOut[id]?.sorted().joined(separator: ", ") ?? "")}\n"
            output += "  USE: {\(block.use.sorted().joined(separator: ", "))}\n"
            output += "  DEF: {\(block.def.sorted().joined(separator: ", "))}\n\n"
        }

        if !deadStores.isEmpty {
            output += "Dead Stores Found:\n"
            for store in deadStores {
                output += "  - \(store.variable) at \(store.location.file):\(store.location.line)\n"
                if let value = store.assignedValue {
                    output += "    Value: \(value)\n"
                }
            }
            output += "\n"
        }

        if !unusedVariables.isEmpty {
            output += "Unused Variables:\n"
            for variable in unusedVariables.sorted() {
                output += "  - \(variable)\n"
            }
        }

        return output
    }
}
