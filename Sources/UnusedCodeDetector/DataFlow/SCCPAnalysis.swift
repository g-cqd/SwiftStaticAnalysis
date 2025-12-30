//
//  SCCPAnalysis.swift
//  SwiftStaticAnalysis
//
//  Sparse Conditional Constant Propagation (SCCP) analysis.
//  Combines constant propagation with reachability analysis:
//  if a branch condition is constant, only the taken edge is marked executable.
//  Used for detecting dead branches and unreachable code.
//

import Foundation
import SwiftStaticAnalysisCore
import SwiftSyntax

// MARK: - LatticeValue

/// Represents the value of a variable in the SCCP lattice.
public enum LatticeValue: Sendable, Hashable, CustomStringConvertible {
    /// Top: unknown value (not yet computed).
    case top

    /// Constant: known compile-time constant.
    case constant(ConstantValue)

    /// Bottom: varying/non-constant (has multiple values).
    case bottom

    // MARK: Public

    public var description: String {
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
    public var boolValue: Bool? {  // swiftlint:disable:this discouraged_optional_boolean
        if case .constant(let c) = self, case .bool(let b) = c {
            return b
        }
        return nil
    }

    /// Meet operation: combines two lattice values.
    public func meet(_ other: Self) -> Self {
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
public enum ConstantValue: Sendable, Hashable, CustomStringConvertible {
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)
    case `nil`

    // MARK: Public

    public var description: String {
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
public struct CFGEdge: Hashable, Sendable {
    // MARK: Lifecycle

    public init(from: BlockID, to: BlockID) {
        self.from = from
        self.to = to
    }

    // MARK: Public

    public let from: BlockID
    public let to: BlockID
}

// MARK: - DeadBranch

/// Represents a branch that is never taken.
public struct DeadBranch: Sendable {
    // MARK: Lifecycle

    public init(
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

    public enum BranchDirection: String, Sendable, Codable {
        case trueBranch
        case falseBranch
    }

    /// Location of the branch.
    public let location: SwiftStaticAnalysisCore.SourceLocation

    /// The branch condition.
    public let condition: String

    /// Whether the true or false branch is dead.
    public let deadBranch: BranchDirection

    /// The constant value of the condition.
    public let conditionValue: String
}

// MARK: - SCCPResult

/// Results from SCCP analysis.
public struct SCCPResult: Sendable {
    // MARK: Lifecycle

    public init(
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
    public let cfg: ControlFlowGraph

    /// Lattice values for variables.
    public let variableValues: [String: LatticeValue]

    /// Executable edges.
    public let executableEdges: Set<CFGEdge>

    /// Unreachable blocks.
    public let unreachableBlocks: Set<BlockID>

    /// Dead branches found.
    public let deadBranches: [DeadBranch]

    /// Constants that can be propagated.
    public let propagatableConstants:
        [(
            variable: String,
            value: ConstantValue,
            location: SwiftStaticAnalysisCore.SourceLocation,
        )]
}

// MARK: - SCCPAnalysis

/// Performs Sparse Conditional Constant Propagation analysis.
public final class SCCPAnalysis: @unchecked Sendable {  // swiftlint:disable:this type_body_length
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

        public static let `default` = Self()

        /// Maximum iterations for fixed-point computation.
        public var maxIterations: Int

        /// Whether to detect dead branches.
        public var detectDeadBranches: Bool

        /// Whether to track string constants.
        public var trackStrings: Bool

        /// Variables to ignore in analysis.
        public var ignoredVariables: Set<String>
    }

    /// Analyze a control flow graph using SCCP.
    ///
    /// - Parameter cfg: The control flow graph to analyze.
    /// - Returns: Analysis results.
    public func analyze(_ cfg: ControlFlowGraph) -> SCCPResult {
        // Reset state
        self.cfg = cfg
        values = [:]
        executableEdges = []
        ssaWorklist = []
        cfgWorklist = []
        visitedBlocks = []

        // Initialize: entry edge is executable
        cfgWorklist.append(CFGEdge(from: .entry, to: cfg.entryBlock))

        var iterations = 0

        // Main worklist loop
        while !cfgWorklist.isEmpty || !ssaWorklist.isEmpty, iterations < configuration.maxIterations {
            iterations += 1

            // Process CFG edges
            while let edge = cfgWorklist.popLast() {
                if executableEdges.insert(edge).inserted {
                    visitBlock(edge.to)
                }
            }

            // Process SSA definitions
            while let variable = ssaWorklist.popLast() {
                propagateValue(variable)
            }
        }

        // Find unreachable blocks
        let unreachableBlocks = findUnreachableBlocks(cfg)

        // Find dead branches
        let deadBranches = configuration.detectDeadBranches ? findDeadBranches(cfg) : []

        // Find propagatable constants
        let constants = findPropagatableConstants(cfg)

        return SCCPResult(
            cfg: cfg,
            variableValues: values,
            executableEdges: executableEdges,
            unreachableBlocks: unreachableBlocks,
            deadBranches: deadBranches,
            propagatableConstants: constants,
        )
    }

    // MARK: Private

    private let configuration: Configuration

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

    /// The CFG being analyzed.
    private var cfg: ControlFlowGraph?

    // MARK: - Block Processing

    private func visitBlock(_ blockID: BlockID) {
        guard let cfg, let block = cfg.blocks[blockID] else { return }

        let firstVisit = !visitedBlocks.contains(blockID)
        visitedBlocks.insert(blockID)

        // Process statements
        for statement in block.statements {
            evaluateStatement(statement)
        }

        // Process terminator
        if let terminator = block.terminator {
            processTerminator(terminator, in: blockID, firstVisit: firstVisit)
        }
    }

    private func evaluateStatement(_ statement: CFGStatement) {
        // Try to evaluate assignments
        for variable in statement.defs {
            if configuration.ignoredVariables.contains(variable) {
                continue
            }

            let value = evaluateExpression(statement.syntax)
            updateValue(variable: variable, value: value)
        }
    }

    private func evaluateExpression(_ syntax: Syntax) -> LatticeValue {
        // Integer literals
        if let intLit = syntax.as(IntegerLiteralExprSyntax.self) {
            if let value = Int(intLit.literal.text) {
                return .constant(.int(value))
            }
        }

        // Boolean literals
        if let boolLit = syntax.as(BooleanLiteralExprSyntax.self) {
            let value = boolLit.literal.text == "true"
            return .constant(.bool(value))
        }

        // String literals
        if configuration.trackStrings, let strLit = syntax.as(StringLiteralExprSyntax.self) {
            // Extract string content (simplified)
            let content = strLit.segments.description
            return .constant(.string(content))
        }

        // Nil literal
        if syntax.is(NilLiteralExprSyntax.self) {
            return .constant(.nil)
        }

        // Variable reference - use current lattice value
        if let declRef = syntax.as(DeclReferenceExprSyntax.self) {
            let name = declRef.baseName.text
            return values[name] ?? .top
        }

        // Binary operators
        if let infixExpr = syntax.as(InfixOperatorExprSyntax.self) {
            return evaluateBinaryOp(infixExpr)
        }

        // Prefix operators (!, -)
        if let prefixExpr = syntax.as(PrefixOperatorExprSyntax.self) {
            return evaluatePrefixOp(prefixExpr)
        }

        // For complex expressions, return bottom (non-constant)
        return .bottom
    }

    private func evaluateBinaryOp(_ expr: InfixOperatorExprSyntax) -> LatticeValue {
        guard let op = expr.operator.as(BinaryOperatorExprSyntax.self) else {
            return .bottom
        }

        let opText = op.operator.text
        let leftValue = evaluateExpression(Syntax(expr.leftOperand))
        let rightValue = evaluateExpression(Syntax(expr.rightOperand))

        // If either operand is top, we can't evaluate yet
        if case .top = leftValue { return .top }
        if case .top = rightValue { return .top }

        // If either operand is bottom, result is bottom
        if case .bottom = leftValue { return .bottom }
        if case .bottom = rightValue { return .bottom }

        // Both are constants - evaluate
        guard case .constant(let left) = leftValue,
            case .constant(let right) = rightValue
        else {
            return .bottom
        }

        // Arithmetic operations
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

        // Boolean operations
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
        let op = expr.operator
        let opText = op.text
        let operandValue = evaluateExpression(Syntax(expr.expression))

        if case .top = operandValue { return .top }
        if case .bottom = operandValue { return .bottom }

        guard case .constant(let operand) = operandValue else {
            return .bottom
        }

        switch opText {
        case "!":
            if case .bool(let b) = operand {
                return .constant(.bool(!b))
            }

        case "-":
            if case .int(let i) = operand {
                return .constant(.int(-i))
            }
            if case .double(let d) = operand {
                return .constant(.double(-d))
            }

        default:
            break
        }

        return .bottom
    }

    // MARK: - Terminator Processing

    private func processTerminator(_ terminator: Terminator, in blockID: BlockID, firstVisit: Bool) {
        switch terminator {
        case .branch(let target):
            cfgWorklist.append(CFGEdge(from: blockID, to: target))

        case .conditionalBranch(let condition, let trueTarget, let falseTarget):
            // Try to evaluate the condition
            let condValue = evaluateCondition(condition)

            switch condValue {
            case .constant(.bool(true)):
                // Only true branch is executable
                cfgWorklist.append(CFGEdge(from: blockID, to: trueTarget))

            case .constant(.bool(false)):
                // Only false branch is executable
                cfgWorklist.append(CFGEdge(from: blockID, to: falseTarget))

            case .top:
                // Unknown - conservatively mark both as potentially executable
                if firstVisit {
                    cfgWorklist.append(CFGEdge(from: blockID, to: trueTarget))
                    cfgWorklist.append(CFGEdge(from: blockID, to: falseTarget))
                }

            case .bottom,
                .constant:
                // Non-constant or unknown constant type - both branches executable
                cfgWorklist.append(CFGEdge(from: blockID, to: trueTarget))
                cfgWorklist.append(CFGEdge(from: blockID, to: falseTarget))
            }

        case .switch(_, let cases, let defaultTarget):
            // For switches, conservatively mark all cases as executable
            for (_, target) in cases {
                cfgWorklist.append(CFGEdge(from: blockID, to: target))
            }
            if let defaultTarget {
                cfgWorklist.append(CFGEdge(from: blockID, to: defaultTarget))
            }

        case .return,
            .throw,
            .unreachable:
            // Terminal - connect to exit
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
        // Simple condition evaluation
        // In a full implementation, we would parse and evaluate the condition expression

        // Check for literal booleans
        if condition.trimmingCharacters(in: .whitespaces) == "true" {
            return .constant(.bool(true))
        }
        if condition.trimmingCharacters(in: .whitespaces) == "false" {
            return .constant(.bool(false))
        }

        // Check if condition is a simple variable we track
        let trimmed = condition.trimmingCharacters(in: .whitespaces)
        if let value = values[trimmed] {
            return value
        }

        // Unknown - return bottom
        return .bottom
    }

    // MARK: - Value Propagation

    private func updateValue(variable: String, value: LatticeValue) {
        let oldValue = values[variable] ?? .top
        let newValue = oldValue.meet(value)

        if newValue != oldValue {
            values[variable] = newValue
            ssaWorklist.append(variable)
        }
    }

    private func propagateValue(_ variable: String) {
        // In a full SSA-based implementation, we would propagate
        // the value to all uses of this variable.
        // For now, re-evaluation happens on the next block visit.
    }

    // MARK: - Result Computation

    private func findUnreachableBlocks(_ cfg: ControlFlowGraph) -> Set<BlockID> {
        var unreachable = Set<BlockID>()

        for id in cfg.blockOrder {
            if id == .entry { continue }

            // A block is unreachable if no executable edge leads to it
            let hasExecutableIncoming = executableEdges.contains { $0.to == id }
            if !hasExecutableIncoming {
                unreachable.insert(id)
            }
        }

        return unreachable
    }

    private func findDeadBranches(_ cfg: ControlFlowGraph) -> [DeadBranch] {
        var deadBranches: [DeadBranch] = []

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }

            if case .conditionalBranch(let condition, let trueTarget, let falseTarget) = block.terminator {
                let condValue = evaluateCondition(condition)

                // Get location from last statement or estimate
                let location: SwiftStaticAnalysisCore.SourceLocation =
                    if let lastStmt = block.statements.last {
                        lastStmt.location
                    } else {
                        SwiftStaticAnalysisCore.SourceLocation(file: cfg.file, line: 0, column: 0, offset: 0)
                    }

                switch condValue {
                case .constant(.bool(true)):
                    // False branch is dead
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
                    // True branch is dead
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

    private func findPropagatableConstants(_ cfg: ControlFlowGraph) -> [(
        variable: String,
        value: ConstantValue,
        location: SwiftStaticAnalysisCore.SourceLocation,
    )] {
        var constants: [(String, ConstantValue, SwiftStaticAnalysisCore.SourceLocation)] = []

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }

            for statement in block.statements {
                for variable in statement.defs {
                    if let latticeValue = values[variable],
                        case .constant(let constValue) = latticeValue
                    {
                        constants.append((variable, constValue, statement.location))
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
    public func debugDescription() -> String {
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
