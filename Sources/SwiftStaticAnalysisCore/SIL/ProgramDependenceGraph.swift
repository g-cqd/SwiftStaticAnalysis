//  ProgramDependenceGraph.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - SILValue

/// An SSA value identifier (`%N`) inside a SIL function.
public struct SILValue: Sendable, Hashable {
    /// The identifier text (without the leading `%`). For example,
    /// `"7"` for `%7`. Block-argument values use the same name
    /// space as instruction-result values.
    public let name: String
}

// MARK: - PDGNodeKind

public enum PDGNodeKind: Sendable, Hashable {
    /// An SSA value defined either by an instruction or by a block
    /// argument (`bbN(%M : $T)`).
    case value(SILValue)
    /// A basic block (used for control dependencies, not data
    /// dependencies). Block nodes participate in the CFG subset of
    /// the PDG.
    case block(String)
}

// MARK: - PDGEdgeKind

public enum PDGEdgeKind: Sendable, Hashable {
    /// `%N` is used as an operand of `%M`'s defining instruction.
    case dataDependence
    /// Block `B` may transfer control to block `S` via its
    /// terminator (mirrors the SIL CFG).
    case controlFlow
}

// MARK: - PDGEdge

public struct PDGEdge: Sendable, Hashable {
    public let source: PDGNodeKind
    public let target: PDGNodeKind
    public let kind: PDGEdgeKind
}

// MARK: - ProgramDependenceGraph

/// A program-dependence graph built from a parsed `SILFunction`.
/// Combines the CFG edges the parser already extracts with SSA
/// def-use chains derived from operand references in each
/// instruction.
///
/// This is the layer above `SILParser` that the SOTA research
/// queue's GNN clone-detection needs: each function's PDG becomes
/// the input to a graph encoder, and pairs of PDGs are compared
/// via subgraph / spectral similarity. Building the PDG itself is
/// bounded work (O(instructions) for def-use extraction); the
/// downstream comparison is the GNN's job and is parked behind the
/// build-required-deep-mode CLI surface.
public struct ProgramDependenceGraph: Sendable {
    public let function: SILFunction
    public let edges: [PDGEdge]
    /// Map from `%N` → defining `(block, instructionIndex)`. Block
    /// arguments use `instructionIndex == -1` to distinguish them
    /// from instruction definitions.
    public let definitions: [SILValue: (block: String, instructionIndex: Int)]
    /// Map from `%N` → list of `(block, instructionIndex)` use
    /// sites. Block-terminator uses (return / br / cond_br) use
    /// the block's last-instruction index.
    public let uses: [SILValue: [(block: String, instructionIndex: Int)]]
}

// MARK: - Construction

extension ProgramDependenceGraph {
    /// Build a PDG from a `SILFunction`. Walks each block's
    /// instructions, extracts SSA defines (`%N = ...`) and uses
    /// (any `%M` reference inside the instruction body), and
    /// records both as nodes + edges. Control-flow edges mirror
    /// the function's block successors.
    public static func build(from function: SILFunction) -> ProgramDependenceGraph {
        var definitions: [SILValue: (block: String, instructionIndex: Int)] = [:]
        var uses: [SILValue: [(block: String, instructionIndex: Int)]] = [:]
        var edges: [PDGEdge] = []

        for blockName in function.blockOrder {
            guard let block = function.blocks[blockName] else { continue }
            // Block arguments are definitions.
            for arg in block.arguments {
                let value = makeValue(from: arg)
                if let value {
                    definitions[value] = (block: blockName, instructionIndex: -1)
                }
            }
            for (index, instruction) in block.instructions.enumerated() {
                let parsed = parseInstruction(instruction)
                if let defined = parsed.defined {
                    definitions[defined] = (block: blockName, instructionIndex: index)
                }
                for used in parsed.used {
                    uses[used, default: []].append((block: blockName, instructionIndex: index))
                }
            }
        }

        // Data-dependence edges: every use draws an edge from its
        // defining value to itself.
        for (usedValue, useSites) in uses {
            for _ in useSites {
                // Single edge per (def, use-value) pair; multiple
                // uses inside one instruction collapse to one edge
                // because the PDG cares about the dependence, not
                // the multiplicity.
                edges.append(
                    PDGEdge(
                        source: .value(usedValue),
                        target: .value(usedValue),  // placeholder, replaced below
                        kind: .dataDependence,
                    )
                )
            }
        }
        // Replace placeholder edges with real def-to-use edges.
        edges.removeAll()
        for blockName in function.blockOrder {
            guard let block = function.blocks[blockName] else { continue }
            for (index, instruction) in block.instructions.enumerated() {
                let parsed = parseInstruction(instruction)
                guard let defined = parsed.defined else {
                    // Terminator: use-only. Record uses as edges
                    // from each used value into the block node.
                    for usedValue in parsed.used {
                        edges.append(
                            PDGEdge(
                                source: .value(usedValue),
                                target: .block(blockName),
                                kind: .dataDependence,
                            )
                        )
                    }
                    continue
                }
                _ = index
                for usedValue in parsed.used {
                    edges.append(
                        PDGEdge(
                            source: .value(usedValue),
                            target: .value(defined),
                            kind: .dataDependence,
                        )
                    )
                }
            }
        }

        // Control-flow edges from the CFG.
        for blockName in function.blockOrder {
            guard let block = function.blocks[blockName] else { continue }
            for successor in block.successors {
                edges.append(
                    PDGEdge(
                        source: .block(blockName),
                        target: .block(successor),
                        kind: .controlFlow,
                    )
                )
            }
        }

        return ProgramDependenceGraph(
            function: function,
            edges: edges,
            definitions: definitions,
            uses: uses,
        )
    }

    /// Parsed shape of a SIL instruction.
    private struct ParsedInstruction {
        /// The `%N` this instruction defines, if any. Terminators
        /// (`return`, `br`, `cond_br`, etc.) and side-effecting
        /// instructions without an SSA result (`debug_value`,
        /// `cond_fail`) have `nil`.
        let defined: SILValue?
        /// Every `%M` referenced as an operand. Block-name
        /// references (`bb1`, `bb2`) are excluded.
        let used: [SILValue]
    }

    /// Parse a single instruction line into its (defined, used)
    /// pair. The format is either `%N = <op> <operands>` or
    /// `<op> <operands>` for non-defining instructions.
    /// Comments (`// ...`) are stripped before scanning.
    private static func parseInstruction(_ instruction: String) -> ParsedInstruction {
        // Strip any trailing `// ...` comment to avoid `%N` in
        // `// users: %N` comments being mistaken for operand uses.
        var line = instruction
        if let commentRange = line.range(of: "//") {
            line = String(line[..<commentRange.lowerBound])
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Defined value: `%N = ...` at the start.
        var defined: SILValue?
        var operandsText = trimmed
        if trimmed.hasPrefix("%") {
            // Find the `=` separator.
            if let equalsIndex = trimmed.firstIndex(of: "=") {
                let lhs = trimmed[..<equalsIndex].trimmingCharacters(in: .whitespaces)
                let rhs = trimmed[trimmed.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
                defined = makeValue(from: lhs)
                operandsText = String(rhs)
            }
        }

        // Used values: every `%N` reference in the remaining text,
        // excluding the defined value itself.
        var used: [SILValue] = []
        let scanned = scanSSAValues(in: operandsText)
        for value in scanned where value != defined {
            used.append(value)
        }
        return ParsedInstruction(defined: defined, used: used)
    }

    /// Extract a `SILValue` from a token like `%7` or `%0 : $Int`.
    private static func makeValue(from token: String) -> SILValue? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("%") else { return nil }
        let after = trimmed.dropFirst()
        let name = after.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
        guard !name.isEmpty else { return nil }
        return SILValue(name: String(name))
    }

    /// Walk a string and extract every `%N` reference. Tokens that
    /// look like `%N` but are followed by `=` (i.e. the
    /// definition) are skipped — those are handled by the caller.
    private static func scanSSAValues(in text: String) -> [SILValue] {
        var values: [SILValue] = []
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "%" {
                let after = text.index(after: index)
                guard after < text.endIndex else { break }
                let name = text[after...].prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
                if !name.isEmpty {
                    values.append(SILValue(name: String(name)))
                    index = text.index(after, offsetBy: name.count)
                    continue
                }
            }
            index = text.index(after: index)
        }
        return values
    }
}
