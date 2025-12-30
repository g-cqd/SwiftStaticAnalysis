//
//  ReachingDefinitions.swift
//  SwiftStaticAnalysis
//
//  Forward data flow analysis for reaching definitions.
//  Determines which variable definitions may reach a given program point.
//  Used for detecting uninitialized variable use and supporting constant propagation.
//
//  Equations:
//    REACH_out[B] = GEN[B] ∪ (REACH_in[B] - KILL[B])
//    REACH_in[B] = ∪ REACH_out[P] for all predecessors P of B
//

import Foundation
import SwiftStaticAnalysisCore
import SwiftSyntax

// MARK: - DefinitionSite

/// Represents a variable definition at a specific location.
public struct DefinitionSite: Sendable, Hashable {
    // MARK: Lifecycle

    public init(
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
    public let variable: String

    /// Block containing the definition.
    public let block: BlockID

    /// Index of the statement in the block.
    public let statementIndex: Int

    /// Source location of the definition.
    public let location: SwiftStaticAnalysisCore.SourceLocation

    /// The value being assigned (if extractable).
    public let value: String?

    /// Whether this is an initial definition (function parameter, etc.).
    public let isInitial: Bool
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
public struct UninitializedUse: Sendable {
    // MARK: Lifecycle

    public init(
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
    public let variable: String

    /// Location of the use.
    public let location: SwiftStaticAnalysisCore.SourceLocation

    /// The definitions that may reach this use (for diagnostics).
    public let reachingDefinitionCount: Int

    /// Whether the variable is definitely uninitialized.
    public let definitelyUninitialized: Bool
}

// MARK: - ReachingDefinitionsResult

/// Results from reaching definitions analysis.
public struct ReachingDefinitionsResult: Sendable {
    // MARK: Lifecycle

    public init(
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
    public let cfg: ControlFlowGraph

    /// All definition sites found.
    public let definitions: [DefinitionSite]

    /// Definitions reaching the entry of each block.
    public let reachIn: [BlockID: Set<DefinitionSite>]

    /// Definitions reaching the exit of each block.
    public let reachOut: [BlockID: Set<DefinitionSite>]

    /// Potentially uninitialized variable uses.
    public let uninitializedUses: [UninitializedUse]

    /// Definition-use chains.
    public let defUseChains: [DefinitionSite: Set<SwiftStaticAnalysisCore.SourceLocation>]
}

// MARK: - ReachingDefinitionsAnalysis

/// Performs forward data flow analysis for reaching definitions.
public struct ReachingDefinitionsAnalysis: Sendable {
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

        public static let `default` = Self()

        /// Maximum iterations for fixed-point computation.
        public var maxIterations: Int

        /// Whether to detect uninitialized uses.
        public var detectUninitializedUses: Bool

        /// Whether to build def-use chains.
        public var buildDefUseChains: Bool

        /// Variables to ignore in analysis.
        public var ignoredVariables: Set<String>
    }

    /// Analyze a control flow graph for reaching definitions.
    ///
    /// - Parameter cfg: The control flow graph to analyze.
    /// - Returns: Analysis results.
    public func analyze(_ cfg: ControlFlowGraph) -> ReachingDefinitionsResult {
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
                    // Skip ignored variables
                    if configuration.ignoredVariables.contains(variable) {
                        continue
                    }

                    let def = DefinitionSite(
                        variable: variable,
                        block: id,
                        statementIndex: index,
                        location: statement.location,
                        value: extractValue(from: statement),
                        isInitial: id == .entry && index == 0,
                    )
                    definitions.append(def)
                }
            }
        }

        return definitions
    }

    /// Extract the assigned value from a statement.
    private func extractValue(from statement: CFGStatement) -> String? {
        let desc = statement.syntax.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if desc.count < 50 {
            return desc
        }
        return nil
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
                if configuration.ignoredVariables.contains(variable) {
                    continue
                }

                // GEN: definitions created in this block
                let newDef = definitions.first {
                    $0.block == block.id && $0.statementIndex == index && $0.variable == variable
                }
                if let newDef {
                    gen.insert(newDef)
                }

                // KILL: all other definitions of this variable
                let killed = definitions.filter {
                    $0.variable == variable && ($0.block != block.id || $0.statementIndex != index)
                }
                kill.formUnion(killed)

                // Remove killed definitions from GEN (if redefined)
                gen = gen.filter { $0.variable != variable || $0.statementIndex == index }
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

        // Worklist (use reverse postorder for forward analysis)
        var worklist = Set(cfg.blockOrder)
        var iterations = 0

        while !worklist.isEmpty, iterations < configuration.maxIterations {
            iterations += 1

            // Get next block (prefer reverse postorder)
            let blockID: BlockID
            if let rpoBlock = cfg.reversePostOrder.first(where: { worklist.contains($0) }) {
                blockID = rpoBlock
            } else {
                blockID = worklist.removeFirst()
                continue
            }
            worklist.remove(blockID)

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

                // Add successors to worklist
                worklist.formUnion(block.successors)
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
                    if configuration.ignoredVariables.contains(usedVar) {
                        continue
                    }

                    // Find definitions of this variable that reach here
                    let varDefs = reachingDefs.filter { $0.variable == usedVar }

                    if varDefs.isEmpty {
                        // No definition reaches this use
                        uninitializedUses.append(
                            UninitializedUse(
                                variable: usedVar,
                                location: statement.location,
                                reachingDefinitionCount: 0,
                                definitelyUninitialized: true,
                            ))
                    }
                }

                // Update reaching definitions for definitions in this statement
                for definedVar in statement.defs {
                    reachingDefs.updateDefinition(
                        for: definedVar,
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
                    let varDefs = reachingDefs.filter { $0.variable == usedVar }
                    for def in varDefs {
                        chains[def, default: []].insert(statement.location)
                    }
                }

                // Update reaching definitions
                for definedVar in statement.defs {
                    reachingDefs.updateDefinition(
                        for: definedVar,
                        block: id,
                        location: statement.location,
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
    public func debugDescription() -> String {
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
public struct CombinedDataFlowAnalysis: Sendable {
    // MARK: Lifecycle

    public init(
        liveConfig: LiveVariableAnalysis.Configuration = .default,
        reachingConfig: ReachingDefinitionsAnalysis.Configuration = .default,
    ) {
        liveAnalysis = LiveVariableAnalysis(configuration: liveConfig)
        reachingAnalysis = ReachingDefinitionsAnalysis(configuration: reachingConfig)
    }

    // MARK: Public

    /// Perform combined analysis on a CFG.
    public func analyze(_ cfg: ControlFlowGraph) -> (
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
    public func findAllDeadStores(_ cfg: ControlFlowGraph) -> [DeadStore] {
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
                    variable: def.variable,
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
    public static func == (lhs: DeadStore, rhs: DeadStore) -> Bool {
        lhs.variable == rhs.variable && lhs.location.line == rhs.location.line && lhs.location.file == rhs.location.file
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(variable)
        hasher.combine(location.line)
        hasher.combine(location.file)
    }
}
