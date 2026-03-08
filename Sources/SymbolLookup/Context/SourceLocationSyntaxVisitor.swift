//  SourceLocationSyntaxVisitor.swift
//  SwiftStaticAnalysis
//  MIT License

import SwiftSyntax

// MARK: - SourceLocationSyntaxVisitor

/// Shared source-location traversal support for location-based syntax visitors.
public class SourceLocationSyntaxVisitor: SyntaxVisitor {
    /// The target line number (1-indexed).
    let targetLine: Int

    /// The target column number (1-indexed).
    let targetColumn: Int

    /// The converter for source locations.
    var converter: SourceLocationConverter?

    public init(targetLine: Int, targetColumn: Int) {
        self.targetLine = targetLine
        self.targetColumn = targetColumn
        super.init(viewMode: .sourceAccurate)
    }

    public override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind {
        converter = SourceLocationConverter(fileName: "", tree: node)
        return .visitChildren
    }

    func startLocation(of node: Syntax) -> SwiftSyntax.SourceLocation? {
        guard let converter else { return nil }
        return node.startLocation(converter: converter)
    }

    func endLocation(of node: Syntax) -> SwiftSyntax.SourceLocation? {
        guard let converter else { return nil }
        return node.endLocation(converter: converter)
    }

    func containsTarget(_ node: Syntax) -> Bool {
        guard let startLoc = startLocation(of: node),
            let endLoc = endLocation(of: node)
        else {
            return false
        }

        let startsBeforeOrAt =
            startLoc.line < targetLine || (startLoc.line == targetLine && startLoc.column <= targetColumn)
        let endsAfterOrAt = endLoc.line > targetLine || (endLoc.line == targetLine && endLoc.column >= targetColumn)

        return startsBeforeOrAt && endsAfterOrAt
    }

    func isPastTarget(_ node: Syntax) -> Bool {
        guard let startLoc = startLocation(of: node) else { return false }
        return startLoc.line > targetLine
    }

    func isCloserToTargetColumn(candidate: Syntax, than existing: Syntax) -> Bool {
        guard let candidateLocation = startLocation(of: candidate),
            let existingLocation = startLocation(of: existing)
        else {
            return false
        }

        return abs(candidateLocation.column - targetColumn) < abs(existingLocation.column - targetColumn)
    }
}
