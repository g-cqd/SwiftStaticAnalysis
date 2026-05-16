//  SCCPAnalysis.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftStaticAnalysisCore
import SwiftSyntax

// MARK: - LatticeValue

/// Represents the value of a variable in the SCCP lattice.
internal enum LatticeValue: Sendable, Hashable, CustomStringConvertible {
    /// Top: unknown value (not yet computed).
    case top

    /// Constant: known compile-time constant.
    case constant(ConstantValue)

    /// Bottom: varying/non-constant (has multiple values).
    case bottom

    // MARK: Public

    internal var description: String {
        switch self {
        case .top:
            "⊤"

        case .constant(let c):
            "const(\(c))"

        case .bottom:
            "⊥"
        }
    }

    /// Check if this is a known boolean constant.
    /// Returns nil if not a boolean constant (valid tri-state: true/false/unknown).
    internal var boolValue: Bool? {  // swiftlint:disable:this discouraged_optional_boolean
        if case .constant(let c) = self, case .bool(let b) = c {
            return b
        }
        return nil
    }

    /// Meet operation: combines two lattice values.
    internal func meet(_ other: Self) -> Self {
        switch (self, other) {
        case (.top, let v),
            (let v, .top):
            v

        case (_, .bottom),
            (.bottom, _):
            .bottom

        case (.constant(let c1), .constant(let c2)):
            if c1 == c2 {
                .constant(c1)
            } else {
                .bottom
            }
        }
    }
}

// MARK: - ConstantValue

/// Represents a compile-time constant value.
internal enum ConstantValue: Sendable, Hashable, CustomStringConvertible {
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)
    case `nil`

    // MARK: Public

    internal var description: String {
        switch self {
        case .int(let i): "\(i)"
        case .double(let d): "\(d)"
        case .bool(let b): "\(b)"
        case .string(let s): "\"\(s)\""
        case .nil: "nil"
        }
    }
}

// MARK: - CFGEdge

/// Represents an edge in the CFG for SCCP.
internal struct CFGEdge: Hashable, Sendable {
    // MARK: Lifecycle

    internal init(from: BlockID, to: BlockID) {
        self.from = from
        self.to = to
    }

    // MARK: Public

    internal let from: BlockID
    internal let to: BlockID
}

// MARK: - DeadBranch

/// Represents a branch that is never taken.
internal struct DeadBranch: Sendable {
    // MARK: Lifecycle

    internal init(
        location: SwiftStaticAnalysisCore.SourceLocation,
        condition: String,
        deadBranch: BranchDirection,
        conditionValue: String,
    ) {
        self.location = location
        self.condition = condition
        self.deadBranch = deadBranch
        self.conditionValue = conditionValue
    }

    // MARK: Public

    internal enum BranchDirection: String, Sendable, Codable {
        case trueBranch
        case falseBranch
    }

    /// Location of the branch.
    internal let location: SwiftStaticAnalysisCore.SourceLocation

    /// The branch condition.
    internal let condition: String

    /// Whether the true or false branch is dead.
    internal let deadBranch: BranchDirection

    /// The constant value of the condition.
    internal let conditionValue: String
}

// MARK: - SCCPResult

/// Results from SCCP analysis.
internal struct SCCPResult: Sendable {
    // MARK: Lifecycle

    internal init(
        cfg: ControlFlowGraph,
        variableValues: [String: LatticeValue],
        executableEdges: Set<CFGEdge>,
        unreachableBlocks: Set<BlockID>,
        deadBranches: [DeadBranch],
        propagatableConstants: [(
            variable: String,
            value: ConstantValue,
            location: SwiftStaticAnalysisCore.SourceLocation,
        )],
    ) {
        self.cfg = cfg
        self.variableValues = variableValues
        self.executableEdges = executableEdges
        self.unreachableBlocks = unreachableBlocks
        self.deadBranches = deadBranches
        self.propagatableConstants = propagatableConstants
    }

    // MARK: Public

    /// The analyzed CFG.
    internal let cfg: ControlFlowGraph

    /// Lattice values for variables.
    internal let variableValues: [String: LatticeValue]

    /// Executable edges.
    internal let executableEdges: Set<CFGEdge>

    /// Unreachable blocks.
    internal let unreachableBlocks: Set<BlockID>

    /// Dead branches found.
    internal let deadBranches: [DeadBranch]

    /// Constants that can be propagated.
    internal let propagatableConstants:
        [(
            variable: String,
            value: ConstantValue,
            location: SwiftStaticAnalysisCore.SourceLocation,
        )]
}

// MARK: - SCCPAnalysis

/// Performs Sparse Conditional Constant Propagation analysis.
internal final class SCCPAnalysis: Sendable {  // swiftlint:disable:this type_body_length
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
            detectDeadBranches: Bool = true,
            trackStrings: Bool = false,
            ignoredVariables: Set<String> = ["_"],
        ) {
            self.maxIterations = maxIterations
            self.detectDeadBranches = detectDeadBranches
            self.trackStrings = trackStrings
            self.ignoredVariables = ignoredVariables
        }

        // MARK: Public

        internal static let `default` = Self()

        /// Maximum iterations for fixed-point computation.
        internal var maxIterations: Int

        /// Whether to detect dead branches.
        internal var detectDeadBranches: Bool

        /// Whether to track string constants.
        internal var trackStrings: Bool

        /// Variables to ignore in analysis.
        internal var ignoredVariables: Set<String>
    }

    /// Analyze a control flow graph using SCCP.
    ///
    /// - Parameter cfg: The control flow graph to analyze.
    /// - Returns: Analysis results.
    internal func analyze(_ cfg: ControlFlowGraph) -> SCCPResult {
        var session = SCCPAnalysisSession(configuration: configuration, cfg: cfg)
        return session.run()
    }

    // MARK: Private

    private let configuration: Configuration
}

private struct SCCPAnalysisSession {
    // MARK: Lifecycle

    init(configuration: SCCPAnalysis.Configuration, cfg: ControlFlowGraph) {
        self.configuration = configuration
        self.cfg = cfg
    }

    // MARK: Private

    private let configuration: SCCPAnalysis.Configuration
    private let cfg: ControlFlowGraph

    /// Lattice values for variables.
    private var values: [String: LatticeValue] = [:]

    /// Executable edges.
    private var executableEdges: Set<CFGEdge> = []

    /// SSA definition worklist.
    private var ssaWorklist: [String] = []

    /// CFG edge worklist.
    private var cfgWorklist: [CFGEdge] = []

    /// Blocks that have been visited.
    private var visitedBlocks: Set<BlockID> = []

    /// Inverted use-chain: for each variable name, the set of blocks that reference it.
    /// Built lazily on the first call to `propagateValue` so analyses that converge
    /// without an SSA-worklist pass pay no cost.
    private var useChain: [String: Set<BlockID>] = [:]
    private var useChainBuilt = false

    // MARK: - Execution

    mutating func run() -> SCCPResult {
        cfgWorklist.append(CFGEdge(from: .entry, to: cfg.entryBlock))

        var iterations = 0

        while !cfgWorklist.isEmpty || !ssaWorklist.isEmpty, iterations < configuration.maxIterations {
            // Cooperative cancellation: pathological code (deeply nested
            // loops, sparse conditional chains) can drive iterations into
            // the thousands. A `Task.isCancelled` check every outer turn
            // lets SIGTERM / explicit cancel terminate the pass promptly
            // and return a partial result rather than wait for the
            // `maxIterations` cap.
            if Task.isCancelled { break }
            iterations += 1

            while let edge = cfgWorklist.popLast() {
                if executableEdges.insert(edge).inserted {
                    visitBlock(edge.to)
                }
            }

            while let variable = ssaWorklist.popLast() {
                propagateValue(variable)
            }
        }

        let unreachableBlocks = findUnreachableBlocks()
        let deadBranches = configuration.detectDeadBranches ? findDeadBranches() : []
        let constants = findPropagatableConstants()

        return SCCPResult(
            cfg: cfg,
            variableValues: values,
            executableEdges: executableEdges,
            unreachableBlocks: unreachableBlocks,
            deadBranches: deadBranches,
            propagatableConstants: constants,
        )
    }

    // MARK: - Block Processing

    private mutating func visitBlock(_ blockID: BlockID) {
        guard let block = cfg.blocks[blockID] else { return }

        let firstVisit = !visitedBlocks.contains(blockID)
        visitedBlocks.insert(blockID)

        for statement in block.statements {
            evaluateStatement(statement)
        }

        if let terminator = block.terminator {
            processTerminator(terminator, in: blockID, firstVisit: firstVisit)
        }
    }

    private mutating func evaluateStatement(_ statement: CFGStatement) {
        for variable in statement.defs {
            if configuration.ignoredVariables.contains(variable.name) {
                continue
            }

            let value = evaluateExpression(statement.syntax)
            updateValue(variable: variable.name, value: value)
        }
    }

    private func evaluateExpression(_ syntax: Syntax) -> LatticeValue {
        if let intLit = syntax.as(IntegerLiteralExprSyntax.self),
            let value = Int(intLit.literal.text)
        {
            return .constant(.int(value))
        }

        if let boolLit = syntax.as(BooleanLiteralExprSyntax.self) {
            let value = boolLit.literal.text == "true"
            return .constant(.bool(value))
        }

        if configuration.trackStrings, let strLit = syntax.as(StringLiteralExprSyntax.self) {
            let content = strLit.segments.description
            return .constant(.string(content))
        }

        if syntax.is(NilLiteralExprSyntax.self) {
            return .constant(.nil)
        }

        if let declRef = syntax.as(DeclReferenceExprSyntax.self) {
            let name = declRef.baseName.text
            return values[name] ?? .top
        }

        if let infixExpr = syntax.as(InfixOperatorExprSyntax.self) {
            return evaluateBinaryOp(infixExpr)
        }

        if let prefixExpr = syntax.as(PrefixOperatorExprSyntax.self) {
            return evaluatePrefixOp(prefixExpr)
        }

        return .bottom
    }

    private func evaluateBinaryOp(_ expr: InfixOperatorExprSyntax) -> LatticeValue {
        guard let op = expr.operator.as(BinaryOperatorExprSyntax.self) else {
            return .bottom
        }

        let opText = op.operator.text
        let leftValue = evaluateExpression(Syntax(expr.leftOperand))
        let rightValue = evaluateExpression(Syntax(expr.rightOperand))

        if case .top = leftValue { return .top }
        if case .top = rightValue { return .top }
        if case .bottom = leftValue { return .bottom }
        if case .bottom = rightValue { return .bottom }

        guard case .constant(let left) = leftValue,
            case .constant(let right) = rightValue
        else {
            return .bottom
        }

        if case .int(let l) = left, case .int(let r) = right {
            switch opText {
            case "+": return .constant(.int(l + r))
            case "-": return .constant(.int(l - r))
            case "*": return .constant(.int(l * r))
            case "/": return r != 0 ? .constant(.int(l / r)) : .bottom
            case "%": return r != 0 ? .constant(.int(l % r)) : .bottom
            case "==": return .constant(.bool(l == r))
            case "!=": return .constant(.bool(l != r))
            case "<": return .constant(.bool(l < r))
            case "<=": return .constant(.bool(l <= r))
            case ">": return .constant(.bool(l > r))
            case ">=": return .constant(.bool(l >= r))
            default: break
            }
        }

        if case .bool(let l) = left, case .bool(let r) = right {
            switch opText {
            case "&&": return .constant(.bool(l && r))
            case "||": return .constant(.bool(l || r))
            case "==": return .constant(.bool(l == r))
            case "!=": return .constant(.bool(l != r))
            default: break
            }
        }

        return .bottom
    }

    private func evaluatePrefixOp(_ expr: PrefixOperatorExprSyntax) -> LatticeValue {
        let opText = expr.operator.text
        let operandValue = evaluateExpression(Syntax(expr.expression))

        if case .top = operandValue { return .top }
        if case .bottom = operandValue { return .bottom }

        guard case .constant(let operand) = operandValue else {
            return .bottom
        }

        switch opText {
        case "!":
            if case .bool(let value) = operand {
                return .constant(.bool(!value))
            }

        case "-":
            if case .int(let value) = operand {
                return .constant(.int(-value))
            }
            if case .double(let value) = operand {
                return .constant(.double(-value))
            }

        default:
            break
        }

        return .bottom
    }

    // MARK: - Terminator Processing

    private mutating func processTerminator(_ terminator: Terminator, in blockID: BlockID, firstVisit: Bool) {
        switch terminator {
        case .branch(let target):
            cfgWorklist.append(CFGEdge(from: blockID, to: target))

        case .conditionalBranch(let condition, let trueTarget, let falseTarget):
            let condValue = evaluateCondition(condition)

            switch condValue {
            case .constant(.bool(true)):
                cfgWorklist.append(CFGEdge(from: blockID, to: trueTarget))

            case .constant(.bool(false)):
                cfgWorklist.append(CFGEdge(from: blockID, to: falseTarget))

            case .top:
                if firstVisit {
                    cfgWorklist.append(CFGEdge(from: blockID, to: trueTarget))
                    cfgWorklist.append(CFGEdge(from: blockID, to: falseTarget))
                }

            case .bottom,
                .constant:
                cfgWorklist.append(CFGEdge(from: blockID, to: trueTarget))
                cfgWorklist.append(CFGEdge(from: blockID, to: falseTarget))
            }

        case .switch(_, let cases, let defaultTarget):
            for (_, target) in cases {
                cfgWorklist.append(CFGEdge(from: blockID, to: target))
            }
            if let defaultTarget {
                cfgWorklist.append(CFGEdge(from: blockID, to: defaultTarget))
            }

        case .return,
            .throw,
            .unreachable:
            cfgWorklist.append(CFGEdge(from: blockID, to: .exit))

        case .fallthrough(let target):
            cfgWorklist.append(CFGEdge(from: blockID, to: target))

        case .break(let target):
            if let target {
                cfgWorklist.append(CFGEdge(from: blockID, to: target))
            }

        case .continue(let target):
            if let target {
                cfgWorklist.append(CFGEdge(from: blockID, to: target))
            }
        }
    }

    private func evaluateCondition(_ condition: String) -> LatticeValue {
        if condition.trimmingCharacters(in: .whitespaces) == "true" {
            return .constant(.bool(true))
        }
        if condition.trimmingCharacters(in: .whitespaces) == "false" {
            return .constant(.bool(false))
        }

        let trimmed = condition.trimmingCharacters(in: .whitespaces)
        if let value = values[trimmed] {
            return value
        }

        return .bottom
    }

    // MARK: - Value Propagation

    private mutating func updateValue(variable: String, value: LatticeValue) {
        let oldValue = values[variable] ?? .top
        let newValue = oldValue.meet(value)

        if newValue != oldValue {
            values[variable] = newValue
            ssaWorklist.append(variable)
        }
    }

    private mutating func propagateValue(_ variable: String) {
        buildUseChainIfNeeded()
        guard let users = useChain[variable] else { return }
        for blockID in users where visitedBlocks.contains(blockID) {
            visitBlock(blockID)
        }
    }

    /// Build a `name → blocks-that-use-it` index from the CFG.
    /// Walks every statement's `uses` plus every conditional / switch terminator's
    /// condition string (which `evaluateCondition` looks up by name).
    private mutating func buildUseChainIfNeeded() {
        guard !useChainBuilt else { return }
        useChainBuilt = true
        for (blockID, block) in cfg.blocks {
            for statement in block.statements {
                for use in statement.uses {
                    useChain[use.name, default: []].insert(blockID)
                }
            }
            guard let terminator = block.terminator else { continue }
            switch terminator {
            case .conditionalBranch(let condition, _, _):
                let trimmed = condition.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    useChain[trimmed, default: []].insert(blockID)
                }

            case .switch(let condition, _, _):
                let trimmed = condition.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    useChain[trimmed, default: []].insert(blockID)
                }

            default:
                break
            }
        }
    }

    // MARK: - Result Computation

    private func findUnreachableBlocks() -> Set<BlockID> {
        var unreachable = Set<BlockID>()

        for id in cfg.blockOrder {
            if id == .entry { continue }

            let hasExecutableIncoming = executableEdges.contains { $0.to == id }
            if !hasExecutableIncoming {
                unreachable.insert(id)
            }
        }

        return unreachable
    }

    private func findDeadBranches() -> [DeadBranch] {
        var deadBranches: [DeadBranch] = []

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }

            if case .conditionalBranch(let condition, let trueTarget, let falseTarget) = block.terminator {
                let condValue = evaluateCondition(condition)

                let location: SwiftStaticAnalysisCore.SourceLocation =
                    if let lastStmt = block.statements.last {
                        lastStmt.location
                    } else {
                        SwiftStaticAnalysisCore.SourceLocation(file: cfg.file, line: 0, column: 0, offset: 0)
                    }

                switch condValue {
                case .constant(.bool(true)):
                    if !executableEdges.contains(CFGEdge(from: id, to: falseTarget)) {
                        deadBranches.append(
                            DeadBranch(
                                location: location,
                                condition: condition,
                                deadBranch: .falseBranch,
                                conditionValue: "true",
                            ))
                    }

                case .constant(.bool(false)):
                    if !executableEdges.contains(CFGEdge(from: id, to: trueTarget)) {
                        deadBranches.append(
                            DeadBranch(
                                location: location,
                                condition: condition,
                                deadBranch: .trueBranch,
                                conditionValue: "false",
                            ))
                    }

                default:
                    break
                }
            }
        }

        return deadBranches
    }

    private func findPropagatableConstants() -> [(
        variable: String,
        value: ConstantValue,
        location: SwiftStaticAnalysisCore.SourceLocation,
    )] {
        var constants: [(String, ConstantValue, SwiftStaticAnalysisCore.SourceLocation)] = []

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }

            for statement in block.statements {
                for variable in statement.defs {
                    if let latticeValue = values[variable.name],
                        case .constant(let constValue) = latticeValue
                    {
                        constants.append((variable.name, constValue, statement.location))
                    }
                }
            }
        }

        return constants
    }
}

// MARK: - Debug Output

// swa:ignore-unused - Debug utilities for development and troubleshooting
extension SCCPResult {
    /// Generate a debug string showing SCCP results.
    internal func debugDescription() -> String {
        var output = "SCCP Analysis Results:\n"
        output += "======================\n\n"

        output += "Function: \(cfg.functionName)\n\n"

        output += "Variable Values:\n"
        for (variable, value) in variableValues.sorted(by: { $0.key < $1.key }) {
            output += "  \(variable) = \(value)\n"
        }
        output += "\n"

        output += "Executable Edges: \(executableEdges.count)\n"
        for edge in executableEdges.sorted(by: { $0.from.value < $1.from.value }) {
            output += "  \(edge.from.value) -> \(edge.to.value)\n"
        }
        output += "\n"

        if !unreachableBlocks.isEmpty {
            output += "Unreachable Blocks:\n"
            for block in unreachableBlocks.sorted(by: { $0.value < $1.value }) {
                output += "  - \(block.value)\n"
            }
            output += "\n"
        }

        if !deadBranches.isEmpty {
            output += "Dead Branches:\n"
            for branch in deadBranches {
                output += "  - \(branch.condition) at line \(branch.location.line): "
                output += "\(branch.deadBranch.rawValue) is dead (condition = \(branch.conditionValue))\n"
            }
            output += "\n"
        }

        if !propagatableConstants.isEmpty {
            output += "Propagatable Constants:\n"
            for (variable, value, location) in propagatableConstants {
                output += "  - \(variable) = \(value) at line \(location.line)\n"
            }
        }

        return output
    }
}
