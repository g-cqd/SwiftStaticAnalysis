//  LiveVariableAnalysis.swift
//  SwiftStaticAnalysis
//  MIT License

import Collections
import Foundation
import SwiftStaticAnalysisCore
import SwiftSyntax

// MARK: - DeadStore

/// Represents an assignment to a variable that is never read.
internal struct DeadStore: Sendable {
    // MARK: Lifecycle

    internal init(
        variable: VariableID,
        location: SwiftStaticAnalysisCore.SourceLocation,
        assignedValue: String? = nil,
        suggestion: String = "Consider removing this assignment"
    ) {
        self.variable = variable
        self.location = location
        self.assignedValue = assignedValue
        self.suggestion = suggestion
    }

    // MARK: Public

    /// The variable being assigned (with scope context).
    internal let variable: VariableID

    /// Location of the dead store.
    internal let location: SwiftStaticAnalysisCore.SourceLocation

    /// The expression being assigned (if simple).
    internal let assignedValue: String?

    /// Suggested fix.
    internal let suggestion: String
}

// MARK: - LiveVariableResult

/// Results from live variable analysis.
internal struct LiveVariableResult: Sendable {
    // MARK: Lifecycle

    internal init(
        cfg: ControlFlowGraph,
        deadStores: [DeadStore],
        unusedVariables: Set<VariableID>,
        liveIn: [BlockID: Set<VariableID>],
        liveOut: [BlockID: Set<VariableID>]
    ) {
        self.cfg = cfg
        self.deadStores = deadStores
        self.unusedVariables = unusedVariables
        self.liveIn = liveIn
        self.liveOut = liveOut
    }

    // MARK: Public

    /// The analyzed CFG.
    internal let cfg: ControlFlowGraph

    /// Dead stores found.
    internal let deadStores: [DeadStore]

    /// Variables that are defined but never used (with scope context).
    internal let unusedVariables: Set<VariableID>

    /// Live-in sets for each block (with scope context).
    internal let liveIn: [BlockID: Set<VariableID>]

    /// Live-out sets for each block (with scope context).
    internal let liveOut: [BlockID: Set<VariableID>]
}

// MARK: - LiveVariableAnalysis

/// Performs backward data flow analysis to find live variables.
internal struct LiveVariableAnalysis: Sendable {
    // MARK: Lifecycle

    internal init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: Public

    /// Configuration for the analysis.
    internal struct Configuration: Sendable {
        // MARK: Lifecycle

        internal init(
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

        internal static let `default` = Self()

        /// Maximum iterations for fixed-point computation.
        internal var maxIterations: Int

        /// Whether to detect dead stores.
        internal var detectDeadStores: Bool

        /// Whether to track variables across function boundaries (conservative).
        internal var interProcedural: Bool

        /// Variables to ignore in analysis.
        internal var ignoredVariables: Set<String>
    }

    /// Analyze a control flow graph for live variables.
    ///
    /// - Parameter cfg: The control flow graph to analyze.
    /// - Returns: Analysis results including dead stores and unused variables.
    internal func analyze(_ cfg: ControlFlowGraph) -> LiveVariableResult {
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
    internal func analyzeFunction(
        _ function: FunctionDeclSyntax,
        file: String,
        tree: SourceFileSyntax,
    ) -> LiveVariableResult {
        let builder = CFGBuilder(file: file, tree: tree)
        let cfg = builder.buildCFG(from: function)
        return analyze(cfg)
    }

    /// Analyze a closure expression.
    internal func analyzeClosure(
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
    ///
    /// Backward analysis worklist is a `Heap<Int>` keyed on *negated*
    /// RPO index (= postorder), with a parallel `inWorklist: Set<Int>`
    /// for dedup. `Heap.popMin` returns the largest RPO index, i.e.
    /// the deepest block in the forward traversal, which is the correct
    /// frontier for liveness's backward sweep. `O(B log B × maxIterations)`.
    private func computeLiveVariables(
        _ cfg: inout ControlFlowGraph
    ) -> (liveIn: [BlockID: Set<VariableID>], liveOut: [BlockID: Set<VariableID>]) {
        var liveIn: [BlockID: Set<VariableID>] = [:]
        var liveOut: [BlockID: Set<VariableID>] = [:]

        // Initialize all blocks
        for id in cfg.blockOrder {
            liveIn[id] = []
            liveOut[id] = []
        }

        // Assign every block a unique workIndex. Reachable blocks get
        // their reverse-postorder index in `[0, reachableCount)`;
        // unreachable blocks get `[reachableCount, totalCount)` in
        // `blockOrder` traversal order. `blockByWorkIndex` is the
        // 1-to-1 inverse so `popMin` can recover the matching block.
        let reachableCount = cfg.reversePostOrder.count
        var workIndex: [BlockID: Int] = [:]
        workIndex.reserveCapacity(cfg.blockOrder.count)
        var blockByWorkIndex: [BlockID] = []
        blockByWorkIndex.reserveCapacity(cfg.blockOrder.count)
        for (index, blockID) in cfg.reversePostOrder.enumerated() {
            workIndex[blockID] = index
            blockByWorkIndex.append(blockID)
        }
        for blockID in cfg.blockOrder where workIndex[blockID] == nil {
            workIndex[blockID] = blockByWorkIndex.count
            blockByWorkIndex.append(blockID)
        }
        let lastWorkIndex = max(0, blockByWorkIndex.count - 1)

        // Backward analysis: we want the deepest reachable block popped
        // first. Key the heap on `lastWorkIndex - workIndex` so `popMin`
        // returns the largest workIndex (deepest reachable; unreachable
        // blocks fall after all reachable ones).
        @inline(__always)
        func key(for blockID: BlockID) -> Int {
            lastWorkIndex - (workIndex[blockID] ?? lastWorkIndex)
        }

        var worklist = Heap<Int>()
        var inWorklist = Set<Int>()
        worklist.reserveCapacity(blockByWorkIndex.count)
        for blockID in cfg.blockOrder {
            let k = key(for: blockID)
            if inWorklist.insert(k).inserted {
                worklist.insert(k)
            }
        }

        var iterations = 0
        while let k = worklist.popMin(), iterations < configuration.maxIterations {
            // Cooperative cancellation (same rationale as in SCCPAnalysis
            // and ReachingDefinitions). Lets SIGTERM / explicit cancel
            // terminate within one block instead of waiting for the
            // iteration cap.
            if Task.isCancelled { break }
            iterations += 1
            inWorklist.remove(k)

            let resolvedIndex = lastWorkIndex - k
            guard resolvedIndex >= 0, resolvedIndex < blockByWorkIndex.count else { continue }
            let blockID = blockByWorkIndex[resolvedIndex]
            guard let block = cfg.blocks[blockID] else { continue }

            // Compute LIVE_out = ∪ LIVE_in[S] for all successors S
            var newLiveOut = Set<VariableID>()
            for succID in block.successors {
                if let succLiveIn = liveIn[succID] {
                    newLiveOut.formUnion(succLiveIn)
                }
            }

            // Compute LIVE_in = USE ∪ (LIVE_out - DEF)
            // For subtraction, we need to match by name since the same variable
            // might have different VariableIDs at different points
            let defNames = Set(block.def.map(\.name))
            var newLiveIn = block.use
            newLiveIn.formUnion(newLiveOut.filter { !defNames.contains($0.name) })

            // Remove ignored variables (by name)
            newLiveIn = newLiveIn.filter { !configuration.ignoredVariables.contains($0.name) }
            newLiveOut = newLiveOut.filter { !configuration.ignoredVariables.contains($0.name) }

            // Check for changes
            if newLiveIn != liveIn[blockID] || newLiveOut != liveOut[blockID] {
                liveIn[blockID] = newLiveIn
                liveOut[blockID] = newLiveOut

                // Update CFG block
                cfg.blocks[blockID]?.liveIn = newLiveIn
                cfg.blocks[blockID]?.liveOut = newLiveOut

                // Add predecessors to the worklist (dedup via inWorklist).
                for predecessorID in block.predecessors {
                    let predecessorKey = key(for: predecessorID)
                    if inWorklist.insert(predecessorKey).inserted {
                        worklist.insert(predecessorKey)
                    }
                }
            }
        }

        return (liveIn, liveOut)
    }

    // MARK: - Dead Store Detection

    /// Find assignments to variables that are not live after the assignment.
    private func findDeadStores(
        cfg: ControlFlowGraph,
        liveOut: [BlockID: Set<VariableID>]
    ) -> [DeadStore] {
        var deadStores: [DeadStore] = []

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }

            // Compute liveness at each statement point (backward within block)
            var liveAtPoint = liveOut[id] ?? []
            var liveNamesAtPoint = Set(liveAtPoint.map(\.name))

            // Process statements in reverse order
            for statement in block.statements.reversed() {
                // Check each defined variable
                for definedVar in statement.defs {
                    // Skip ignored variables (by name)
                    if configuration.ignoredVariables.contains(definedVar.name) {
                        continue
                    }

                    // If defined variable is not live after this point, it's a dead store
                    // Compare by name for liveness check
                    if !liveNamesAtPoint.contains(definedVar.name) {
                        // Check if variable is used in the same statement (like x = x + 1)
                        let usedInSameStatement = statement.uses.contains { $0.name == definedVar.name }

                        if !usedInSameStatement {
                            deadStores.append(
                                DeadStore(
                                    variable: definedVar,
                                    location: statement.location,
                                    assignedValue: extractAssignedValue(statement),
                                    suggestion: "Variable '\(definedVar.name)' is assigned but never read"
                                ))
                        }
                    }
                }

                // Update liveness for this point
                // LIVE_before = USE ∪ (LIVE_after - DEF)
                let defNames = Set(statement.defs.map(\.name))
                liveAtPoint = liveAtPoint.filter { !defNames.contains($0.name) }
                liveAtPoint.formUnion(statement.uses)
                liveNamesAtPoint = Set(liveAtPoint.map(\.name))
            }
        }

        return deadStores
    }

    /// Extract the assigned value from a statement (if simple).
    private func extractAssignedValue(_ statement: CFGStatement) -> String? {
        statement.shortDescription(maxLength: 100)
    }

    // MARK: - Unused Variable Detection

    /// Find variables that are defined but never used anywhere.
    private func findUnusedVariables(
        cfg: ControlFlowGraph,
        liveIn: [BlockID: Set<VariableID>]
    ) -> Set<VariableID> {
        // Collect all defined variables
        var allDefined = Set<VariableID>()
        var allUsedNames = Set<String>()

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }
            allDefined.formUnion(block.def)
            allUsedNames.formUnion(block.use.map(\.name))
        }

        // Remove ignored variables (by name)
        allDefined = allDefined.filter { !configuration.ignoredVariables.contains($0.name) }

        // Find variables defined but never used (by name)
        return allDefined.filter { !allUsedNames.contains($0.name) }
    }
}

// MARK: - Statement-Level Analysis

// swa:ignore-unused - Advanced analysis utilities for debugging and future features
extension LiveVariableAnalysis {
    /// Compute live variables at each statement in a block.
    ///
    /// - Parameters:
    ///   - block: The basic block to analyze.
    ///   - liveAtExit: Variables live at block exit.
    /// - Returns: Array of (statement, liveBeforeStatement) pairs.
    internal func computeStatementLiveness(
        block: BasicBlock,
        liveAtExit: Set<VariableID>
    ) -> [(statement: CFGStatement, liveBefore: Set<VariableID>)] {
        var result: [(CFGStatement, Set<VariableID>)] = []
        var live = liveAtExit

        // Process statements in reverse order
        for statement in block.statements.reversed() {
            // LIVE_before = USE ∪ (LIVE_after - DEF)
            let defNames = Set(statement.defs.map(\.name))
            var liveBefore = live.filter { !defNames.contains($0.name) }
            liveBefore.formUnion(statement.uses)

            result.append((statement, liveBefore))
            live = liveBefore
        }

        return result.reversed()
    }
}

// MARK: - Multi-Function Analysis

extension LiveVariableAnalysis {
    /// Analyze all functions in a source file.
    ///
    /// - Parameters:
    ///   - file: Path to the Swift source file.
    ///   - tree: Parsed syntax tree.
    /// - Returns: Array of results for each function/closure.
    internal func analyzeFile(
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

// swa:ignore-unused - Debug utilities for development and troubleshooting
extension LiveVariableResult {
    /// Generate a debug string showing liveness information.
    internal func debugDescription() -> String {
        var output = "Live Variable Analysis Results:\n"
        output += "================================\n\n"

        output += "Function: \(cfg.functionName)\n\n"

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }
            output += "Block \(id.value):\n"
            output +=
                "  LIVE_in:  {\(liveIn[id]?.sorted().map(\.description).joined(separator: ", ") ?? "")}\n"
            output +=
                "  LIVE_out: {\(liveOut[id]?.sorted().map(\.description).joined(separator: ", ") ?? "")}\n"
            output += "  USE: {\(block.use.sorted().map(\.description).joined(separator: ", "))}\n"
            output += "  DEF: {\(block.def.sorted().map(\.description).joined(separator: ", "))}\n\n"
        }

        if !deadStores.isEmpty {
            output += "Dead Stores Found:\n"
            for store in deadStores {
                output +=
                    "  - \(store.variable.description) at \(store.location.file):\(store.location.line)\n"
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
