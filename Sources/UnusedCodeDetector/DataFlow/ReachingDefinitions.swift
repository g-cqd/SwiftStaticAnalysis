//  ReachingDefinitions.swift
//  SwiftStaticAnalysis
//  MIT License

import Collections
import Foundation
import SwiftStaticAnalysisCore
import SwiftSyntax

// MARK: - DefinitionSite

/// Represents a variable definition at a specific location.
internal struct DefinitionSite: Sendable, Hashable {
    // MARK: Lifecycle

    internal init(
        variable: String,
        block: BlockID,
        statementIndex: Int,
        location: SwiftStaticAnalysisCore.SourceLocation,
        value: String? = nil,
        isInitial: Bool = false,
    ) {
        self.variable = variable
        self.block = block
        self.statementIndex = statementIndex
        self.location = location
        self.value = value
        self.isInitial = isInitial
    }

    // MARK: Public

    /// The variable being defined.
    internal let variable: String

    /// Block containing the definition.
    internal let block: BlockID

    /// Index of the statement in the block.
    internal let statementIndex: Int

    /// Source location of the definition.
    internal let location: SwiftStaticAnalysisCore.SourceLocation

    /// The value being assigned (if extractable).
    internal let value: String?

    /// Whether this is an initial definition (function parameter, etc.).
    internal let isInitial: Bool
}

// MARK: - Definition Site Set Extensions

// swa:ignore-unused - Internal helper extension for reaching definitions algorithm
extension Set<DefinitionSite> {
    /// Update definitions by killing old definitions for a variable and inserting a new one.
    mutating func updateDefinition(
        for variable: String,
        block: BlockID,
        statementIndex: Int = -1,
        location: SwiftStaticAnalysisCore.SourceLocation,
        value: String? = nil,
        isInitial: Bool = false,
    ) {
        // Kill old definitions
        self = filter { $0.variable != variable }
        // Add new definition
        let newDef = DefinitionSite(
            variable: variable,
            block: block,
            statementIndex: statementIndex,
            location: location,
            value: value,
            isInitial: isInitial,
        )
        insert(newDef)
    }
}

// MARK: - UninitializedUse

/// Represents a use of a potentially uninitialized variable.
internal struct UninitializedUse: Sendable {
    // MARK: Lifecycle

    internal init(
        variable: String,
        location: SwiftStaticAnalysisCore.SourceLocation,
        reachingDefinitionCount: Int,
        definitelyUninitialized: Bool,
    ) {
        self.variable = variable
        self.location = location
        self.reachingDefinitionCount = reachingDefinitionCount
        self.definitelyUninitialized = definitelyUninitialized
    }

    // MARK: Public

    /// The variable being used.
    internal let variable: String

    /// Location of the use.
    internal let location: SwiftStaticAnalysisCore.SourceLocation

    /// The definitions that may reach this use (for diagnostics).
    internal let reachingDefinitionCount: Int

    /// Whether the variable is definitely uninitialized.
    internal let definitelyUninitialized: Bool
}

// MARK: - ReachingDefinitionsResult

/// Results from reaching definitions analysis.
internal struct ReachingDefinitionsResult: Sendable {
    // MARK: Lifecycle

    internal init(
        cfg: ControlFlowGraph,
        definitions: [DefinitionSite],
        reachIn: [BlockID: Set<DefinitionSite>],
        reachOut: [BlockID: Set<DefinitionSite>],
        uninitializedUses: [UninitializedUse],
        defUseChains: [DefinitionSite: Set<SwiftStaticAnalysisCore.SourceLocation>],
    ) {
        self.cfg = cfg
        self.definitions = definitions
        self.reachIn = reachIn
        self.reachOut = reachOut
        self.uninitializedUses = uninitializedUses
        self.defUseChains = defUseChains
    }

    // MARK: Public

    /// The analyzed CFG.
    internal let cfg: ControlFlowGraph

    /// All definition sites found.
    internal let definitions: [DefinitionSite]

    /// Definitions reaching the entry of each block.
    internal let reachIn: [BlockID: Set<DefinitionSite>]

    /// Definitions reaching the exit of each block.
    internal let reachOut: [BlockID: Set<DefinitionSite>]

    /// Potentially uninitialized variable uses.
    internal let uninitializedUses: [UninitializedUse]

    /// Definition-use chains.
    internal let defUseChains: [DefinitionSite: Set<SwiftStaticAnalysisCore.SourceLocation>]
}

// MARK: - ReachingDefinitionsAnalysis

/// Performs forward data flow analysis for reaching definitions.
internal struct ReachingDefinitionsAnalysis: Sendable {
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
            detectUninitializedUses: Bool = true,
            buildDefUseChains: Bool = true,
            ignoredVariables: Set<String> = ["_"],
        ) {
            self.maxIterations = maxIterations
            self.detectUninitializedUses = detectUninitializedUses
            self.buildDefUseChains = buildDefUseChains
            self.ignoredVariables = ignoredVariables
        }

        // MARK: Public

        internal static let `default` = Self()

        /// Maximum iterations for fixed-point computation.
        internal var maxIterations: Int

        /// Whether to detect uninitialized uses.
        internal var detectUninitializedUses: Bool

        /// Whether to build def-use chains.
        internal var buildDefUseChains: Bool

        /// Variables to ignore in analysis.
        internal var ignoredVariables: Set<String>
    }

    /// Analyze a control flow graph for reaching definitions.
    ///
    /// - Parameter cfg: The control flow graph to analyze.
    /// - Returns: Analysis results.
    internal func analyze(_ cfg: ControlFlowGraph) -> ReachingDefinitionsResult {
        // Collect all definitions
        let definitions = collectDefinitions(cfg)

        // Build GEN and KILL sets
        var genSets: [BlockID: Set<DefinitionSite>] = [:]
        var killSets: [BlockID: Set<DefinitionSite>] = [:]

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }
            let (gen, kill) = computeGenKill(
                block: block,
                definitions: definitions,
            )
            genSets[id] = gen
            killSets[id] = kill
        }

        // Compute reaching definitions using worklist algorithm
        let (reachIn, reachOut) = computeReachingDefinitions(
            cfg: cfg,
            genSets: genSets,
            killSets: killSets,
        )

        // Find uninitialized uses if enabled
        var uninitializedUses: [UninitializedUse] = []
        if configuration.detectUninitializedUses {
            uninitializedUses = findUninitializedUses(cfg: cfg, reachIn: reachIn)
        }

        // Build def-use chains if enabled
        var defUseChains: [DefinitionSite: Set<SwiftStaticAnalysisCore.SourceLocation>] = [:]
        if configuration.buildDefUseChains {
            defUseChains = buildDefUseChains(cfg: cfg, reachIn: reachIn)
        }

        return ReachingDefinitionsResult(
            cfg: cfg,
            definitions: definitions,
            reachIn: reachIn,
            reachOut: reachOut,
            uninitializedUses: uninitializedUses,
            defUseChains: defUseChains,
        )
    }

    // MARK: Private

    private let configuration: Configuration

    // MARK: - Definition Collection

    /// Collect all definition sites from the CFG.
    private func collectDefinitions(_ cfg: ControlFlowGraph) -> [DefinitionSite] {
        var definitions: [DefinitionSite] = []

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }

            for (index, statement) in block.statements.enumerated() {
                for variable in statement.defs {
                    // Skip ignored variables (by name)
                    if configuration.ignoredVariables.contains(variable.name) {
                        continue
                    }

                    let def = DefinitionSite(
                        variable: variable.name,
                        block: id,
                        statementIndex: index,
                        location: statement.location,
                        value: extractValue(from: statement),
                        isInitial: id == .entry && index == 0
                    )
                    definitions.append(def)
                }
            }
        }

        return definitions
    }

    /// Extract the assigned value from a statement.
    private func extractValue(from statement: CFGStatement) -> String? {
        statement.shortDescription(maxLength: 50)
    }

    // MARK: - GEN/KILL Sets

    /// Compute GEN and KILL sets for a block.
    private func computeGenKill(
        block: BasicBlock,
        definitions: [DefinitionSite],
    ) -> (gen: Set<DefinitionSite>, kill: Set<DefinitionSite>) {
        var gen = Set<DefinitionSite>()
        var kill = Set<DefinitionSite>()

        // Process statements in order
        for (index, statement) in block.statements.enumerated() {
            for variable in statement.defs {
                // Skip ignored variables (by name)
                if configuration.ignoredVariables.contains(variable.name) {
                    continue
                }

                // GEN: definitions created in this block
                let newDef = definitions.first {
                    $0.block == block.id && $0.statementIndex == index && $0.variable == variable.name
                }
                if let newDef {
                    gen.insert(newDef)
                }

                // KILL: all other definitions of this variable
                let killed = definitions.filter {
                    $0.variable == variable.name && ($0.block != block.id || $0.statementIndex != index)
                }
                kill.formUnion(killed)

                // Remove killed definitions from GEN (if redefined)
                gen = gen.filter { $0.variable != variable.name || $0.statementIndex == index }
            }
        }

        return (gen, kill)
    }

    // MARK: - Worklist Algorithm

    /// Compute reaching definitions using iterative worklist algorithm.
    private func computeReachingDefinitions(
        cfg: ControlFlowGraph,
        genSets: [BlockID: Set<DefinitionSite>],
        killSets: [BlockID: Set<DefinitionSite>],
    ) -> (reachIn: [BlockID: Set<DefinitionSite>], reachOut: [BlockID: Set<DefinitionSite>]) {
        var reachIn: [BlockID: Set<DefinitionSite>] = [:]
        var reachOut: [BlockID: Set<DefinitionSite>] = [:]

        // Initialize all blocks
        for id in cfg.blockOrder {
            reachIn[id] = []
            reachOut[id] = genSets[id] ?? []
        }

        // Worklist is a `Collections.Heap<Int>` keyed on a unique
        // workIndex per block. Reachable blocks get their reverse-
        // postorder index in `[0, reachableCount)`; unreachable blocks
        // get `[reachableCount, totalCount)` in `blockOrder` traversal
        // order. `blockByWorkIndex` is the 1-to-1 inverse so `popMin`
        // can recover the matching block without ambiguity. Each push
        // / pop is O(log B); total bound O(B × maxIterations × log B).
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

        var worklist = Heap<Int>()
        var inWorklist = Set<Int>()
        worklist.reserveCapacity(blockByWorkIndex.count)
        for blockID in cfg.blockOrder {
            if let index = workIndex[blockID], inWorklist.insert(index).inserted {
                worklist.insert(index)
            }
        }
        var iterations = 0

        while let nextIndex = worklist.popMin(), iterations < configuration.maxIterations {
            // Cooperative cancellation — see SCCPAnalysis.run for the same
            // pattern. Check every iteration (lightweight atomic load on
            // the task-local flag) so SIGTERM exits within one block
            // instead of waiting for `maxIterations`.
            if Task.isCancelled { break }
            iterations += 1
            inWorklist.remove(nextIndex)

            guard nextIndex >= 0, nextIndex < blockByWorkIndex.count else { continue }
            let blockID = blockByWorkIndex[nextIndex]
            guard let block = cfg.blocks[blockID] else { continue }

            // Compute REACH_in = ∪ REACH_out[P] for all predecessors P
            var newReachIn = Set<DefinitionSite>()
            for predID in block.predecessors {
                if let predReachOut = reachOut[predID] {
                    newReachIn.formUnion(predReachOut)
                }
            }

            // Compute REACH_out = GEN ∪ (REACH_in - KILL)
            let gen = genSets[blockID] ?? []
            let kill = killSets[blockID] ?? []
            let newReachOut = gen.union(newReachIn.subtracting(kill))

            // Check for changes
            if newReachIn != reachIn[blockID] || newReachOut != reachOut[blockID] {
                reachIn[blockID] = newReachIn
                reachOut[blockID] = newReachOut

                // Enqueue successors that aren't already pending.
                for successorID in block.successors {
                    if let successorIndex = workIndex[successorID],
                        inWorklist.insert(successorIndex).inserted
                    {
                        worklist.insert(successorIndex)
                    }
                }
            }
        }

        return (reachIn, reachOut)
    }

    // MARK: - Uninitialized Use Detection

    /// Find uses of potentially uninitialized variables.
    private func findUninitializedUses(
        cfg: ControlFlowGraph,
        reachIn: [BlockID: Set<DefinitionSite>],
    ) -> [UninitializedUse] {
        var uninitializedUses: [UninitializedUse] = []

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }

            // Track reaching definitions within the block
            var reachingDefs = reachIn[id] ?? []

            for statement in block.statements {
                // Check each used variable
                for usedVar in statement.uses {
                    // Skip ignored variables (by name)
                    if configuration.ignoredVariables.contains(usedVar.name) {
                        continue
                    }

                    // Find definitions of this variable that reach here
                    let varDefs = reachingDefs.filter { $0.variable == usedVar.name }

                    if varDefs.isEmpty {
                        // No definition reaches this use
                        uninitializedUses.append(
                            UninitializedUse(
                                variable: usedVar.name,
                                location: statement.location,
                                reachingDefinitionCount: 0,
                                definitelyUninitialized: true
                            ))
                    }
                }

                // Update reaching definitions for definitions in this statement
                for definedVar in statement.defs {
                    reachingDefs.updateDefinition(
                        for: definedVar.name,
                        block: id,
                        location: statement.location,
                    )
                }
            }
        }

        return uninitializedUses
    }

    // MARK: - Def-Use Chains

    /// Build definition-use chains.
    private func buildDefUseChains(
        cfg: ControlFlowGraph,
        reachIn: [BlockID: Set<DefinitionSite>],
    ) -> [DefinitionSite: Set<SwiftStaticAnalysisCore.SourceLocation>] {
        var chains: [DefinitionSite: Set<SwiftStaticAnalysisCore.SourceLocation>] = [:]

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }

            var reachingDefs = reachIn[id] ?? []

            for statement in block.statements {
                // For each use, link to reaching definitions
                for usedVar in statement.uses {
                    let varDefs = reachingDefs.filter { $0.variable == usedVar.name }
                    for def in varDefs {
                        chains[def, default: []].insert(statement.location)
                    }
                }

                // Update reaching definitions
                for definedVar in statement.defs {
                    reachingDefs.updateDefinition(
                        for: definedVar.name,
                        block: id,
                        location: statement.location
                    )
                }
            }
        }

        return chains
    }
}

// MARK: - Debug Output

// swa:ignore-unused - Debug utilities for development and troubleshooting
extension ReachingDefinitionsResult {
    /// Generate a debug string showing reaching definitions information.
    internal func debugDescription() -> String {
        var output = "Reaching Definitions Analysis Results:\n"
        output += "======================================\n\n"

        output += "Function: \(cfg.functionName)\n"
        output += "Total Definitions: \(definitions.count)\n\n"

        for id in cfg.blockOrder {
            guard cfg.blocks[id] != nil else { continue }
            output += "Block \(id.value):\n"

            if let reach = reachIn[id], !reach.isEmpty {
                output += "  REACH_in: {\n"
                for def in reach.sorted(by: { $0.variable < $1.variable }) {
                    output += "    \(def.variable) @ \(def.block.value):\(def.statementIndex)\n"
                }
                output += "  }\n"
            } else {
                output += "  REACH_in: {}\n"
            }

            if let reach = reachOut[id], !reach.isEmpty {
                output += "  REACH_out: {\n"
                for def in reach.sorted(by: { $0.variable < $1.variable }) {
                    output += "    \(def.variable) @ \(def.block.value):\(def.statementIndex)\n"
                }
                output += "  }\n"
            } else {
                output += "  REACH_out: {}\n"
            }
            output += "\n"
        }

        if !uninitializedUses.isEmpty {
            output += "Potentially Uninitialized Uses:\n"
            for use in uninitializedUses {
                output += "  - \(use.variable) at \(use.location.file):\(use.location.line)"
                if use.definitelyUninitialized {
                    output += " (definitely uninitialized)"
                }
                output += "\n"
            }
            output += "\n"
        }

        if !defUseChains.isEmpty {
            output += "Def-Use Chains:\n"
            for (def, uses) in defUseChains.sorted(by: { $0.key.variable < $1.key.variable }) {
                output += "  \(def.variable) @ line \(def.location.line) -> "
                output += "used at lines: \(uses.map { "\($0.line)" }.sorted().joined(separator: ", "))\n"
            }
        }

        return output
    }
}

// MARK: - CombinedDataFlowAnalysis

/// Combines live variable and reaching definitions analysis.
internal struct CombinedDataFlowAnalysis: Sendable {
    // MARK: Lifecycle

    internal init(
        liveConfig: LiveVariableAnalysis.Configuration = .default,
        reachingConfig: ReachingDefinitionsAnalysis.Configuration = .default,
    ) {
        liveAnalysis = LiveVariableAnalysis(configuration: liveConfig)
        reachingAnalysis = ReachingDefinitionsAnalysis(configuration: reachingConfig)
    }

    // MARK: Public

    /// Perform combined analysis on a CFG.
    internal func analyze(_ cfg: ControlFlowGraph) -> (
        live: LiveVariableResult,
        reaching: ReachingDefinitionsResult,
    ) {
        let liveResult = liveAnalysis.analyze(cfg)
        let reachingResult = reachingAnalysis.analyze(cfg)
        return (liveResult, reachingResult)
    }

    /// Find all dead stores using both analyses.
    ///
    /// A store is dead if:
    /// 1. The variable is not live after the store (from live analysis)
    /// 2. The definition doesn't reach any use (from reaching definitions)
    internal func findAllDeadStores(_ cfg: ControlFlowGraph) -> [DeadStore] {
        let liveResult = liveAnalysis.analyze(cfg)
        let reachingResult = reachingAnalysis.analyze(cfg)

        var deadStores = Set<DeadStore>()

        // Add dead stores from live analysis
        for store in liveResult.deadStores {
            deadStores.insert(store)
        }

        // Add stores that have no uses in def-use chains
        for def in reachingResult.definitions {
            let uses = reachingResult.defUseChains[def] ?? []
            if uses.isEmpty, !def.isInitial {
                let store = DeadStore(
                    variable: VariableID(name: def.variable),
                    location: def.location,
                    assignedValue: def.value,
                    suggestion: "Definition of '\(def.variable)' is never used",
                )
                deadStores.insert(store)
            }
        }

        return Array(deadStores)
    }

    // MARK: Private

    private let liveAnalysis: LiveVariableAnalysis
    private let reachingAnalysis: ReachingDefinitionsAnalysis
}

// MARK: - DeadStore + Hashable

extension DeadStore: Hashable {
    internal static func == (lhs: DeadStore, rhs: DeadStore) -> Bool {
        lhs.variable == rhs.variable && lhs.location.line == rhs.location.line && lhs.location.file == rhs.location.file
    }

    internal func hash(into hasher: inout Hasher) {
        hasher.combine(variable)
        hasher.combine(location.line)
        hasher.combine(location.file)
    }
}
