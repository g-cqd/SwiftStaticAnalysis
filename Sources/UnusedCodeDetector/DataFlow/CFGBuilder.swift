//
//  CFGBuilder.swift
//  SwiftStaticAnalysis
//
//  Control Flow Graph construction for data flow analysis.
//  Builds a CFG from Swift function bodies for use in
//  live variable analysis, reaching definitions, and SCCP.
//
// swiftlint:disable file_length

import Foundation
import SwiftStaticAnalysisCore
import SwiftSyntax

// MARK: - BlockID

/// A unique identifier for a basic block.
public struct BlockID: Hashable, Sendable, CustomStringConvertible {
    // MARK: Lifecycle

    public init(_ value: String) {
        self.value = value
    }

    // MARK: Public

    public static let entry = Self("entry")
    public static let exit = Self("exit")

    public let value: String

    public var description: String { value }
}

// MARK: - CFGStatement

/// Represents a statement in the CFG with its source location.
public struct CFGStatement: Sendable {
    // MARK: Lifecycle

    public init(
        syntax: Syntax,
        location: SwiftStaticAnalysisCore.SourceLocation,
        uses: Set<String>,
        defs: Set<String>
    ) {
        self.syntax = syntax
        self.location = location
        self.uses = uses
        self.defs = defs
    }

    // MARK: Public

    /// The syntax node.
    public let syntax: Syntax

    /// Source location.
    public let location: SwiftStaticAnalysisCore.SourceLocation

    /// Extracted variable uses (variables read).
    public let uses: Set<String>

    /// Extracted variable definitions (variables written).
    public let defs: Set<String>
}

// MARK: - Terminator

/// A terminator instruction for a basic block.
public enum Terminator: Sendable {
    /// Unconditional branch to another block.
    case branch(BlockID)

    /// Conditional branch based on a condition.
    case conditionalBranch(condition: String, trueTarget: BlockID, falseTarget: BlockID)

    /// Switch statement with multiple targets.
    case `switch`(expression: String, cases: [(pattern: String, target: BlockID)], default: BlockID?)

    /// Return from function.
    case `return`(expression: String?)

    /// Throw an error.
    case `throw`(expression: String)

    /// Fall through to next block (for control flow within switch cases).
    case `fallthrough`(BlockID)

    /// Break from loop or switch.
    case `break`(target: BlockID?)

    /// Continue to next loop iteration.
    case `continue`(target: BlockID?)

    /// Unreachable (after fatalError, preconditionFailure, etc.).
    case unreachable
}

// MARK: - BasicBlock

/// A basic block in the control flow graph.
public struct BasicBlock: Identifiable, Sendable {
    // MARK: Lifecycle

    public init(id: BlockID) {
        self.id = id
        statements = []
        terminator = nil
        successors = []
        predecessors = []
        use = []
        def = []
        liveIn = []
        liveOut = []
        isLoopHeader = false
        loopID = nil
    }

    // MARK: Public

    /// Unique identifier.
    public let id: BlockID

    /// Statements in this block (in order).
    public var statements: [CFGStatement]

    /// The terminator instruction.
    public var terminator: Terminator?

    /// Successor block IDs.
    public var successors: [BlockID]

    /// Predecessor block IDs.
    public var predecessors: [BlockID]

    /// Variables used before being defined in this block.
    public var use: Set<String>

    /// Variables defined in this block.
    public var def: Set<String>

    /// Live variables at block entry (computed by analysis).
    public var liveIn: Set<String>

    /// Live variables at block exit (computed by analysis).
    public var liveOut: Set<String>

    /// Whether this is a loop header.
    public var isLoopHeader: Bool

    /// The loop ID if this block is in a loop.
    public var loopID: String?
}

// MARK: - ControlFlowGraph

/// Control Flow Graph for a function.
public struct ControlFlowGraph: Sendable {
    // MARK: Lifecycle

    public init(functionName: String, file: String) {
        self.functionName = functionName
        self.file = file
        entryBlock = .entry
        exitBlock = .exit
        blocks = [
            .entry: BasicBlock(id: .entry),
            .exit: BasicBlock(id: .exit),
        ]
        blockOrder = [.entry]
        reversePostOrder = []
    }

    // MARK: Public

    /// All basic blocks indexed by ID.
    public var blocks: [BlockID: BasicBlock]

    /// Entry block ID.
    public let entryBlock: BlockID

    /// Exit block ID.
    public let exitBlock: BlockID

    /// Function name.
    public let functionName: String

    /// Source file.
    public let file: String

    /// Block order for iteration (topological order when possible).
    public var blockOrder: [BlockID]

    /// Reverse postorder for efficient iteration.
    public var reversePostOrder: [BlockID]

    /// Get all blocks in reverse postorder (for forward analysis).
    public var blocksInReversePostOrder: [BasicBlock] {
        reversePostOrder.compactMap { blocks[$0] }
    }

    /// Get all blocks in postorder (for backward analysis).
    public var blocksInPostOrder: [BasicBlock] {
        reversePostOrder.reversed().compactMap { blocks[$0] }
    }

    /// Get a block by ID.
    public func block(_ id: BlockID) -> BasicBlock? {
        blocks[id]
    }

    /// Add a block to the CFG.
    public mutating func addBlock(_ block: BasicBlock) {
        blocks[block.id] = block
        blockOrder.append(block.id)
    }

    /// Add an edge between blocks.
    public mutating func addEdge(from: BlockID, to: BlockID) {
        blocks[from]?.successors.append(to)
        blocks[to]?.predecessors.append(from)
    }

    /// Compute reverse postorder traversal.
    public mutating func computeReversePostOrder() {
        var visited = Set<BlockID>()
        var postOrder: [BlockID] = []

        func dfs(_ blockID: BlockID) {
            guard !visited.contains(blockID) else { return }
            visited.insert(blockID)

            if let block = blocks[blockID] {
                for succ in block.successors {
                    dfs(succ)
                }
            }
            postOrder.append(blockID)
        }

        dfs(entryBlock)
        reversePostOrder = postOrder.reversed()
    }
}

// MARK: - CFGBuilder

/// Builds a Control Flow Graph from Swift function declarations.
public final class CFGBuilder: SyntaxVisitor { // swiftlint:disable:this type_body_length
    // MARK: Lifecycle

    public init(file: String, tree: SourceFileSyntax) {
        self.file = file
        converter = SourceLocationConverter(fileName: file, tree: tree)
        cfg = ControlFlowGraph(functionName: "", file: file)
        currentBlockID = .entry
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: Public

    /// Build CFG for a function declaration.
    public func buildCFG(from function: FunctionDeclSyntax) -> ControlFlowGraph {
        resetAndBuild(name: function.name.text) {
            if let body = function.body {
                self.processCodeBlock(body)
            }
        }
    }

    /// Build CFG for an initializer declaration.
    public func buildCFG(from initializer: InitializerDeclSyntax) -> ControlFlowGraph {
        resetAndBuild(name: "init") {
            if let body = initializer.body {
                self.processCodeBlock(body)
            }
        }
    }

    /// Build CFG for a closure expression.
    public func buildCFG(from closure: ClosureExprSyntax) -> ControlFlowGraph {
        resetAndBuild(name: "<closure>") {
            for statement in closure.statements {
                self.processStatement(statement.item)
            }
        }
    }

    // MARK: Private

    /// Source location converter.
    private let converter: SourceLocationConverter

    /// File path.
    private let file: String

    /// Current CFG being built.
    private var cfg: ControlFlowGraph

    /// Current block being populated.
    private var currentBlockID: BlockID

    /// Block counter for generating unique IDs.
    private var blockCounter: Int = 0

    /// Stack of loop headers for break/continue.
    private var loopStack: [(header: BlockID, exit: BlockID, id: String)] = []

    /// Stack of switch exit blocks.
    private var switchStack: [BlockID] = []

    /// Pending block connections.
    private var pendingConnections: [(from: BlockID, to: BlockID)] = []

    /// Shared logic for building CFG.
    private func resetAndBuild(name: String, bodyProcessor: () -> Void) -> ControlFlowGraph {
        cfg = ControlFlowGraph(functionName: name, file: file)
        currentBlockID = .entry
        blockCounter = 0
        loopStack = []
        switchStack = []
        pendingConnections = []

        // Process body
        bodyProcessor()

        // Connect current block to exit if not already terminated
        if cfg.blocks[currentBlockID]?.terminator == nil {
            cfg.addEdge(from: currentBlockID, to: .exit)
            cfg.blocks[currentBlockID]?.terminator = .return(expression: nil)
        }

        // Apply pending connections
        for (from, to) in pendingConnections {
            cfg.addEdge(from: from, to: to)
        }

        // Compute reverse postorder
        cfg.computeReversePostOrder()

        // Compute USE and DEF sets for each block
        computeUseDef()

        return cfg
    }

    // MARK: - Block Management

    private func newBlock() -> BlockID {
        blockCounter += 1
        let id = BlockID("block_\(blockCounter)")
        cfg.addBlock(BasicBlock(id: id))
        return id
    }

    private func switchToBlock(_ id: BlockID) {
        currentBlockID = id
    }

    // MARK: - Statement Processing

    private func processCodeBlock(_ block: CodeBlockSyntax) {
        for statement in block.statements {
            processStatement(statement.item)
        }
    }

    private func processStatement(_ item: CodeBlockItemSyntax.Item) {
        switch item {
        case let .stmt(stmt):
            processStmt(stmt)

        case let .decl(decl):
            processDecl(decl)

        case let .expr(expr):
            addStatementToCurrentBlock(Syntax(expr))
        }
    }

    private func processStmt(_ stmt: StmtSyntax) {
        // Handle expression statements that contain if/switch expressions
        if let exprStmt = stmt.as(ExpressionStmtSyntax.self) {
            if let ifExpr = exprStmt.expression.as(IfExprSyntax.self) {
                processIfStatement(ifExpr)
                return
            } else if let switchExpr = exprStmt.expression.as(SwitchExprSyntax.self) {
                processSwitchStatement(switchExpr)
                return
            }
        }

        if let guardStmt = stmt.as(GuardStmtSyntax.self) {
            processGuardStatement(guardStmt)
        } else if let forStmt = stmt.as(ForStmtSyntax.self) {
            processForStatement(forStmt)
        } else if let whileStmt = stmt.as(WhileStmtSyntax.self) {
            processWhileStatement(whileStmt)
        } else if let repeatStmt = stmt.as(RepeatStmtSyntax.self) {
            processRepeatWhileStatement(repeatStmt)
        } else if let returnStmt = stmt.as(ReturnStmtSyntax.self) {
            processReturnStatement(returnStmt)
        } else if let throwStmt = stmt.as(ThrowStmtSyntax.self) {
            processThrowStatement(throwStmt)
        } else if let breakStmt = stmt.as(BreakStmtSyntax.self) {
            processBreakStatement(breakStmt)
        } else if let continueStmt = stmt.as(ContinueStmtSyntax.self) {
            processContinueStatement(continueStmt)
        } else if let fallthroughStmt = stmt.as(FallThroughStmtSyntax.self) {
            processFallthroughStatement(fallthroughStmt)
        } else if let doStmt = stmt.as(DoStmtSyntax.self) {
            processDoStatement(doStmt)
        } else if let deferStmt = stmt.as(DeferStmtSyntax.self) {
            processDeferStatement(deferStmt)
        } else {
            // Generic statement - add to current block
            addStatementToCurrentBlock(Syntax(stmt))
        }
    }

    private func processDecl(_ decl: DeclSyntax) {
        // Variable declarations and other declarations
        addStatementToCurrentBlock(Syntax(decl))
    }

    // MARK: - Control Flow Statements

    private func processIfStatement(_ ifStmt: IfExprSyntax) {
        // Add condition to current block
        let conditionText = ifStmt.conditions.description
        addStatementToCurrentBlock(Syntax(ifStmt.conditions))

        let thenBlock = newBlock()
        let elseBlock = newBlock()
        let mergeBlock = newBlock()

        // Set terminator
        cfg.blocks[currentBlockID]?.terminator = .conditionalBranch(
            condition: conditionText,
            trueTarget: thenBlock,
            falseTarget: elseBlock,
            )
        cfg.addEdge(from: currentBlockID, to: thenBlock)
        cfg.addEdge(from: currentBlockID, to: elseBlock)

        // Process then branch
        switchToBlock(thenBlock)
        processCodeBlock(ifStmt.body)
        if cfg.blocks[currentBlockID]?.terminator == nil {
            cfg.addEdge(from: currentBlockID, to: mergeBlock)
            cfg.blocks[currentBlockID]?.terminator = .branch(mergeBlock)
        }

        // Process else branch
        switchToBlock(elseBlock)
        if let elseBody = ifStmt.elseBody {
            switch elseBody {
            case let .codeBlock(block):
                processCodeBlock(block)

            case let .ifExpr(elseIf):
                processIfStatement(elseIf)
            }
        }
        if cfg.blocks[currentBlockID]?.terminator == nil {
            cfg.addEdge(from: currentBlockID, to: mergeBlock)
            cfg.blocks[currentBlockID]?.terminator = .branch(mergeBlock)
        }

        switchToBlock(mergeBlock)
    }

    private func processGuardStatement(_ guardStmt: GuardStmtSyntax) {
        let conditionText = guardStmt.conditions.description
        addStatementToCurrentBlock(Syntax(guardStmt.conditions))

        let elseBlock = newBlock()
        let continueBlock = newBlock()

        cfg.blocks[currentBlockID]?.terminator = .conditionalBranch(
            condition: conditionText,
            trueTarget: continueBlock,
            falseTarget: elseBlock,
            )
        cfg.addEdge(from: currentBlockID, to: continueBlock)
        cfg.addEdge(from: currentBlockID, to: elseBlock)

        // Process else block (must exit scope)
        switchToBlock(elseBlock)
        processCodeBlock(guardStmt.body)
        // Guard else should end with return/throw/break/continue
        // If not terminated, it's a compiler error but we handle it gracefully
        if cfg.blocks[currentBlockID]?.terminator == nil {
            cfg.addEdge(from: currentBlockID, to: .exit)
            cfg.blocks[currentBlockID]?.terminator = .unreachable
        }

        switchToBlock(continueBlock)
    }

    private func processForStatement(_ forStmt: ForStmtSyntax) {
        let loopID = "loop_\(blockCounter)"
        let headerBlock = newBlock()
        let bodyBlock = newBlock()
        let exitBlock = newBlock()

        cfg.blocks[headerBlock]?.isLoopHeader = true
        cfg.blocks[headerBlock]?.loopID = loopID

        // Connect current block to header
        cfg.addEdge(from: currentBlockID, to: headerBlock)
        cfg.blocks[currentBlockID]?.terminator = .branch(headerBlock)

        // Header block with loop condition
        switchToBlock(headerBlock)
        addStatementToCurrentBlock(Syntax(forStmt.sequence))
        cfg.blocks[headerBlock]?.terminator = .conditionalBranch(
            condition: "for \(forStmt.pattern.description) in \(forStmt.sequence.description)",
            trueTarget: bodyBlock,
            falseTarget: exitBlock,
            )
        cfg.addEdge(from: headerBlock, to: bodyBlock)
        cfg.addEdge(from: headerBlock, to: exitBlock)

        // Push loop context
        loopStack.append((header: headerBlock, exit: exitBlock, id: loopID))

        // Process loop body
        switchToBlock(bodyBlock)
        processCodeBlock(forStmt.body)
        if cfg.blocks[currentBlockID]?.terminator == nil {
            cfg.addEdge(from: currentBlockID, to: headerBlock)
            cfg.blocks[currentBlockID]?.terminator = .branch(headerBlock)
        }

        // Pop loop context
        loopStack.removeLast()

        switchToBlock(exitBlock)
    }

    private func processWhileStatement(_ whileStmt: WhileStmtSyntax) {
        let loopID = "loop_\(blockCounter)"
        let headerBlock = newBlock()
        let bodyBlock = newBlock()
        let exitBlock = newBlock()

        cfg.blocks[headerBlock]?.isLoopHeader = true
        cfg.blocks[headerBlock]?.loopID = loopID

        cfg.addEdge(from: currentBlockID, to: headerBlock)
        cfg.blocks[currentBlockID]?.terminator = .branch(headerBlock)

        switchToBlock(headerBlock)
        let conditionText = whileStmt.conditions.description
        addStatementToCurrentBlock(Syntax(whileStmt.conditions))
        cfg.blocks[headerBlock]?.terminator = .conditionalBranch(
            condition: conditionText,
            trueTarget: bodyBlock,
            falseTarget: exitBlock,
            )
        cfg.addEdge(from: headerBlock, to: bodyBlock)
        cfg.addEdge(from: headerBlock, to: exitBlock)

        loopStack.append((header: headerBlock, exit: exitBlock, id: loopID))

        switchToBlock(bodyBlock)
        processCodeBlock(whileStmt.body)
        if cfg.blocks[currentBlockID]?.terminator == nil {
            cfg.addEdge(from: currentBlockID, to: headerBlock)
            cfg.blocks[currentBlockID]?.terminator = .branch(headerBlock)
        }

        loopStack.removeLast()
        switchToBlock(exitBlock)
    }

    private func processRepeatWhileStatement(_ repeatStmt: RepeatStmtSyntax) {
        let loopID = "loop_\(blockCounter)"
        let bodyBlock = newBlock()
        let conditionBlock = newBlock()
        let exitBlock = newBlock()

        cfg.blocks[bodyBlock]?.isLoopHeader = true
        cfg.blocks[bodyBlock]?.loopID = loopID

        cfg.addEdge(from: currentBlockID, to: bodyBlock)
        cfg.blocks[currentBlockID]?.terminator = .branch(bodyBlock)

        loopStack.append((header: bodyBlock, exit: exitBlock, id: loopID))

        switchToBlock(bodyBlock)
        processCodeBlock(repeatStmt.body)
        if cfg.blocks[currentBlockID]?.terminator == nil {
            cfg.addEdge(from: currentBlockID, to: conditionBlock)
            cfg.blocks[currentBlockID]?.terminator = .branch(conditionBlock)
        }

        loopStack.removeLast()

        switchToBlock(conditionBlock)
        let conditionText = repeatStmt.condition.description
        addStatementToCurrentBlock(Syntax(repeatStmt.condition))
        cfg.blocks[conditionBlock]?.terminator = .conditionalBranch(
            condition: conditionText,
            trueTarget: bodyBlock,
            falseTarget: exitBlock,
            )
        cfg.addEdge(from: conditionBlock, to: bodyBlock)
        cfg.addEdge(from: conditionBlock, to: exitBlock)

        switchToBlock(exitBlock)
    }

    // swiftlint:disable:next function_body_length
    private func processSwitchStatement(_ switchStmt: SwitchExprSyntax) {
        let exitBlock = newBlock()
        switchStack.append(exitBlock)

        addStatementToCurrentBlock(Syntax(switchStmt.subject))

        var caseBlocks: [(pattern: String, target: BlockID)] = []
        var defaultBlock: BlockID?

        // Create blocks for each case
        for caseItem in switchStmt.cases {
            switch caseItem {
            case let .switchCase(switchCase):
                let caseBlock = newBlock()
                if let label = switchCase.label.as(SwitchCaseLabelSyntax.self) {
                    let pattern = label.caseItems.description
                    caseBlocks.append((pattern: pattern, target: caseBlock))
                } else if switchCase.label.is(SwitchDefaultLabelSyntax.self) {
                    defaultBlock = caseBlock
                }

            case .ifConfigDecl:
                // Ignore #if directives for now
                break
            }
        }

        // Set switch terminator
        cfg.blocks[currentBlockID]?.terminator = .switch(
            expression: switchStmt.subject.description,
            cases: caseBlocks,
            default: defaultBlock,
            )

        for (_, target) in caseBlocks {
            cfg.addEdge(from: currentBlockID, to: target)
        }
        if let defaultBlock {
            cfg.addEdge(from: currentBlockID, to: defaultBlock)
        }

        // Process each case
        for caseItem in switchStmt.cases {
            switch caseItem {
            case let .switchCase(switchCase):
                let caseBlock: BlockID
                if let label = switchCase.label.as(SwitchCaseLabelSyntax.self) {
                    let pattern = label.caseItems.description
                    caseBlock = caseBlocks.first { $0.pattern == pattern }?.target ?? newBlock()
                } else if switchCase.label.is(SwitchDefaultLabelSyntax.self) {
                    caseBlock = defaultBlock ?? newBlock()
                } else {
                    continue
                }

                switchToBlock(caseBlock)
                for statement in switchCase.statements {
                    processStatement(statement.item)
                }

                if cfg.blocks[currentBlockID]?.terminator == nil {
                    cfg.addEdge(from: currentBlockID, to: exitBlock)
                    cfg.blocks[currentBlockID]?.terminator = .branch(exitBlock)
                }

            case .ifConfigDecl:
                break
            }
        }

        switchStack.removeLast()
        switchToBlock(exitBlock)
    }

    private func processReturnStatement(_ returnStmt: ReturnStmtSyntax) {
        addStatementToCurrentBlock(Syntax(returnStmt))
        cfg.addEdge(from: currentBlockID, to: .exit)
        cfg.blocks[currentBlockID]?.terminator = .return(
            expression: returnStmt.expression?.description,
            )
    }

    private func processThrowStatement(_ throwStmt: ThrowStmtSyntax) {
        addStatementToCurrentBlock(Syntax(throwStmt))
        cfg.addEdge(from: currentBlockID, to: .exit)
        cfg.blocks[currentBlockID]?.terminator = .throw(
            expression: throwStmt.expression.description,
            )
    }

    private func processBreakStatement(_ breakStmt: BreakStmtSyntax) {
        addStatementToCurrentBlock(Syntax(breakStmt))

        // Find target based on label or innermost loop/switch
        let target: BlockID? = if let label = breakStmt.label {
            loopStack.first { $0.id == label.text }?.exit ?? switchStack.last
        } else if !switchStack.isEmpty {
            switchStack.last
        } else if let loop = loopStack.last {
            loop.exit
        } else {
            nil
        }

        if let target {
            cfg.addEdge(from: currentBlockID, to: target)
        }
        cfg.blocks[currentBlockID]?.terminator = .break(target: target)
    }

    private func processContinueStatement(_ continueStmt: ContinueStmtSyntax) {
        addStatementToCurrentBlock(Syntax(continueStmt))

        let target: BlockID? = if let label = continueStmt.label {
            loopStack.first { $0.id == label.text }?.header
        } else {
            loopStack.last?.header
        }

        if let target {
            cfg.addEdge(from: currentBlockID, to: target)
        }
        cfg.blocks[currentBlockID]?.terminator = .continue(target: target)
    }

    private func processFallthroughStatement(_ fallthroughStmt: FallThroughStmtSyntax) {
        addStatementToCurrentBlock(Syntax(fallthroughStmt))
        // Fallthrough target will be connected when processing next case
        cfg.blocks[currentBlockID]?.terminator = .fallthrough(newBlock())
    }

    private func processDoStatement(_ doStmt: DoStmtSyntax) {
        processCodeBlock(doStmt.body)

        // Process catch clauses
        for catchClause in doStmt.catchClauses {
            let catchBlock = newBlock()
            // Connect from do body to catch (for exception flow)
            pendingConnections.append((from: currentBlockID, to: catchBlock))

            switchToBlock(catchBlock)
            processCodeBlock(catchClause.body)
        }
    }

    private func processDeferStatement(_ deferStmt: DeferStmtSyntax) {
        // Defer blocks are executed at scope exit
        // For simplicity, we add the defer body to the current block
        // A more sophisticated analysis would track defer execution order
        addStatementToCurrentBlock(Syntax(deferStmt))
    }

    // MARK: - Statement Addition

    private func addStatementToCurrentBlock(_ syntax: Syntax) {
        let loc = converter.location(for: syntax.positionAfterSkippingLeadingTrivia)
        let location = SwiftStaticAnalysisCore.SourceLocation(
            file: file,
            line: loc.line,
            column: loc.column,
            offset: 0,
            )

        let extractor = UseDefExtractor()
        extractor.walk(syntax)

        let statement = CFGStatement(
            syntax: syntax,
            location: location,
            uses: extractor.uses,
            defs: extractor.defs,
            )

        cfg.blocks[currentBlockID]?.statements.append(statement)
    }

    // MARK: - USE/DEF Computation

    private func computeUseDef() {
        for id in cfg.blockOrder {
            guard var block = cfg.blocks[id] else { continue }

            var use = Set<String>()
            var def = Set<String>()

            // Process statements in order
            for statement in block.statements {
                // Use = variables used before being defined
                for usedVar in statement.uses where !def.contains(usedVar) {
                    use.insert(usedVar)
                }
                // Def = all variables defined
                def.formUnion(statement.defs)
            }

            block.use = use
            block.def = def
            cfg.blocks[id] = block
        }
    }
}

// MARK: - UseDefExtractor

/// Extracts variable uses and definitions from syntax.
private final class UseDefExtractor: SyntaxVisitor {
    // MARK: Lifecycle

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: Internal

    var uses = Set<String>()
    var defs = Set<String>()

    // Variable references (reads)
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        uses.insert(node.baseName.text)
        return .visitChildren
    }

    // Variable bindings (writes)
    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if let identifier = node.pattern.as(IdentifierPatternSyntax.self) {
            defs.insert(identifier.identifier.text)
        }
        return .visitChildren
    }

    // Assignment expressions
    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        // Check for assignment operators
        if let op = node.operator.as(BinaryOperatorExprSyntax.self),
           op.operator.text == "=" || op.operator.text.hasSuffix("=") {
            // Left side is being assigned
            if let declRef = node.leftOperand.as(DeclReferenceExprSyntax.self) {
                defs.insert(declRef.baseName.text)
                // Remove from uses if it was added
                uses.remove(declRef.baseName.text)
            }
        }
        return .visitChildren
    }

    // For loop pattern (defines iteration variable)
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        if let identifier = node.pattern.as(IdentifierPatternSyntax.self) {
            defs.insert(identifier.identifier.text)
        }
        return .visitChildren
    }

    // Guard/if let bindings
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if let identifier = node.pattern.as(IdentifierPatternSyntax.self) {
            defs.insert(identifier.identifier.text)
        }
        return .visitChildren
    }

    // Closure capture
    override func visit(_ node: ClosureCaptureSpecifierSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren // Don't descend into closures
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren // Don't descend into closures
    }
}

// MARK: - CFG Utilities

public extension ControlFlowGraph {
    /// Print the CFG for debugging.
    func debugPrint() -> String {
        var output = "CFG for \(functionName):\n"

        for id in blockOrder {
            guard let block = blocks[id] else { continue }
            output += "\n\(id.value):\n"
            output += "  predecessors: \(block.predecessors.map(\.value).joined(separator: ", "))\n"
            output += "  statements: \(block.statements.count)\n"
            for stmt in block.statements {
                let shortDesc = stmt.syntax.description.prefix(50).replacingOccurrences(of: "\n", with: " ")
                output += "    - \(shortDesc)...\n"
            }
            output += "  USE: \(block.use.sorted().joined(separator: ", "))\n"
            output += "  DEF: \(block.def.sorted().joined(separator: ", "))\n"
            if let terminator = block.terminator {
                output += "  terminator: \(terminator)\n"
            }
            output += "  successors: \(block.successors.map(\.value).joined(separator: ", "))\n"
        }

        return output
    }
}
