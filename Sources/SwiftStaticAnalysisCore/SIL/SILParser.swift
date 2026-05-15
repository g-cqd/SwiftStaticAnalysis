//  SILParser.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - SILFunction

/// A function definition parsed from SIL text.
public struct SILFunction: Sendable, Hashable {
    /// Mangled function name (e.g. `$s4main3add1a1bS2i_SitF`).
    public let mangledName: String
    /// Block-name → block mapping. The first block in source order
    /// is the entry point; `blockOrder[0]` gives its name.
    public let blocks: [String: SILBasicBlock]
    /// Block names in source order. Useful for CFG traversal and
    /// reverse postorder construction.
    public let blockOrder: [String]
}

// MARK: - SILBasicBlock

/// A single basic block within a SIL function. We capture the
/// block's name, the names of its arguments (e.g. `%0`, `%1`), the
/// raw instruction lines, and the set of successor block names
/// derived from the terminator.
public struct SILBasicBlock: Sendable, Hashable {
    public let name: String
    public let arguments: [String]
    public let instructions: [String]
    public let successors: [String]
}

// MARK: - SILParser

/// Spike-level parser for `swiftc -emit-sil` textual output. Parses
/// function boundaries and per-function basic-block control-flow
/// graphs. Data-flow extraction (SSA def-use chains beyond the
/// SIL-emitted `// users:` comments) is deliberately out of scope
/// here — that's the next layer in the 0.4.0 PDG pipeline.
///
/// The parser is line-oriented and handles the canonical SIL output
/// shape:
///
/// ```
/// sil <attrs> @<name> : $<type> {
/// // ... comments / arg metadata
/// bb0(%0 : $T):
///   <instr>
///   <terminator>
///
/// bbN(...):                         // Preds: bbM bbK
///   ...
/// } // end sil function '<name>'
/// ```
///
/// Recognised terminators: `return`, `br`, `cond_br`, `switch_value`,
/// `switch_enum`, `throw`, `unwind`, `unreachable`, `try_apply`,
/// `dynamic_method_br`. Any other terminator yields a block with no
/// outgoing edges (a CFG sink); the caller can treat that as either
/// a true exit or a parser gap to file as future work.
public enum SILParser {
    /// Parse SIL text into a list of function CFGs. Functions
    /// without bodies (decl-only declarations at the top of the
    /// file) are skipped.
    public static func parse(_ sil: String) -> [SILFunction] {
        var functions: [SILFunction] = []
        let lines = sil.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let mangledName = matchSilFunctionStart(line) {
                let (function, consumed) = parseFunctionBody(
                    mangledName: mangledName, lines: lines, startIndex: index + 1,
                )
                if let function {
                    functions.append(function)
                }
                index = consumed
            } else {
                index += 1
            }
        }
        return functions
    }

    /// Match `sil [attrs] @<mangled> : $...$ {` and return the
    /// mangled name. Returns nil if the line is not a SIL function
    /// header.
    private static func matchSilFunctionStart(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("sil "), trimmed.hasSuffix("{") else { return nil }
        guard let atRange = trimmed.range(of: "@") else { return nil }
        let afterAt = trimmed[atRange.upperBound...]
        let nameEnd =
            afterAt.firstIndex(where: { $0 == " " || $0 == ":" }) ?? afterAt.endIndex
        return String(afterAt[..<nameEnd])
    }

    /// Parse the body lines following `bb0(...):` and return the
    /// SILFunction plus the index past the closing `}`. Returns
    /// `(nil, consumed)` if the body is empty or malformed.
    private static func parseFunctionBody(
        mangledName: String,
        lines: [String],
        startIndex: Int,
    ) -> (SILFunction?, Int) {
        var blocks: [String: SILBasicBlock] = [:]
        var blockOrder: [String] = []
        var index = startIndex
        var currentBlockName: String?
        var currentArgs: [String] = []
        var currentInstrs: [String] = []
        var currentSuccessors: [String] = []

        func flushBlock() {
            guard let name = currentBlockName else { return }
            if currentSuccessors.isEmpty,
                let last = currentInstrs.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            {
                currentSuccessors = successorsForTerminator(last)
            }
            let block = SILBasicBlock(
                name: name,
                arguments: currentArgs,
                instructions: currentInstrs,
                successors: currentSuccessors,
            )
            blocks[name] = block
            blockOrder.append(name)
            currentBlockName = nil
            currentArgs = []
            currentInstrs = []
            currentSuccessors = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("} // end sil function") {
                flushBlock()
                return (
                    blocks.isEmpty
                        ? nil
                        : SILFunction(
                            mangledName: mangledName,
                            blocks: blocks,
                            blockOrder: blockOrder,
                        ),
                    index + 1
                )
            }
            if let parsedHeader = matchBlockHeader(trimmed) {
                flushBlock()
                currentBlockName = parsedHeader.name
                currentArgs = parsedHeader.arguments
            } else if currentBlockName != nil, !trimmed.isEmpty {
                currentInstrs.append(trimmed)
            }
            index += 1
        }
        return (nil, index)
    }

    /// Match `bb<N>[(<args>)]:` and extract the block name + arg
    /// names. Ignores the trailing `// Preds: ...` comment.
    private static func matchBlockHeader(_ line: String) -> (name: String, arguments: [String])? {
        guard line.hasPrefix("bb") else { return nil }
        // Find the block-header colon — the one at paren depth 0 that
        // isn't part of an argument type annotation. Walking the line
        // tracks paren / bracket depth so the inner `:` in
        // `bb0(%0 : $Int):` doesn't fool the parser.
        var depth = 0
        var headerColonIndex: String.Index?
        for index in line.indices {
            let ch = line[index]
            if ch == "(" || ch == "[" { depth += 1 }
            else if ch == ")" || ch == "]" { depth -= 1 }
            else if ch == ":", depth == 0 {
                headerColonIndex = index
                break
            }
        }
        guard let headerColonIndex else { return nil }
        let before = line[..<headerColonIndex]
        let nameAndArgs = String(before)
        if let parenStart = nameAndArgs.firstIndex(of: "(") {
            let name = String(nameAndArgs[..<parenStart])
            var depth = 0
            var endIndex: String.Index?
            for index in nameAndArgs.indices[parenStart...] {
                let ch = nameAndArgs[index]
                if ch == "(" { depth += 1 }
                if ch == ")" {
                    depth -= 1
                    if depth == 0 {
                        endIndex = index
                        break
                    }
                }
            }
            guard let endIndex else { return nil }
            let argList = nameAndArgs[
                nameAndArgs.index(after: parenStart)..<endIndex
            ]
            let arguments = argList.split(separator: ",").map { arg -> String in
                let trimmed = arg.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                return parts.first.map(String.init) ?? trimmed
            }
            return (name: name, arguments: arguments)
        }
        return (name: nameAndArgs, arguments: [])
    }

    /// Compute outgoing block-name successors from a terminator
    /// instruction. The instruction is the raw SIL text without
    /// leading whitespace.
    private static func successorsForTerminator(_ instr: String) -> [String] {
        if instr.hasPrefix("br ") {
            return [extractBlockName(after: "br ", in: instr)].compactMap { $0 }
        }
        if instr.hasPrefix("cond_br ") {
            let components = instr.dropFirst("cond_br ".count).split(separator: ",")
            guard components.count >= 3 else { return [] }
            let true_ = String(components[1]).trimmingCharacters(in: .whitespaces)
            let false_ = String(components[2]).trimmingCharacters(in: .whitespaces)
            return [stripBlockArgs(true_), stripBlockArgs(false_)]
        }
        if instr.hasPrefix("try_apply ") {
            var blocks: [String] = []
            if let normalRange = instr.range(of: "normal ") {
                let after = instr[normalRange.upperBound...]
                let name = after.split(separator: ",")[0].trimmingCharacters(in: .whitespaces)
                blocks.append(stripBlockArgs(name))
            }
            if let errorRange = instr.range(of: "error ") {
                let after = instr[errorRange.upperBound...]
                let name = after.split(separator: ",")[0].trimmingCharacters(in: .whitespaces)
                blocks.append(stripBlockArgs(name))
            }
            return blocks
        }
        if instr.hasPrefix("switch_value ") || instr.hasPrefix("switch_enum ")
            || instr.hasPrefix("switch_enum_addr ")
        {
            var successors: [String] = []
            var search = instr.startIndex..<instr.endIndex
            while let range = instr.range(of: " bb", range: search) {
                let after = instr[range.lowerBound...].dropFirst()
                let token = after.prefix(while: { $0.isLetter || $0.isNumber })
                successors.append(String(token))
                search = range.upperBound..<instr.endIndex
            }
            return successors
        }
        if instr.hasPrefix("dynamic_method_br ") {
            let parts = instr.split(separator: ",")
            guard parts.count >= 4 else { return [] }
            return [
                stripBlockArgs(String(parts[2]).trimmingCharacters(in: .whitespaces)),
                stripBlockArgs(String(parts[3]).trimmingCharacters(in: .whitespaces)),
            ]
        }
        return []
    }

    /// Pull `bbN` out of a token that may have args, comments, or
    /// trailing punctuation.
    private static func stripBlockArgs(_ token: String) -> String {
        var result = token
        if let parenIndex = result.firstIndex(of: "(") {
            result = String(result[..<parenIndex])
        }
        if let commentRange = result.range(of: "//") {
            result = String(result[..<commentRange.lowerBound])
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func extractBlockName(after prefix: String, in instr: String) -> String? {
        let after = instr.dropFirst(prefix.count)
        let candidate = String(after.split(separator: ",")[0])
        return stripBlockArgs(candidate)
    }
}

// MARK: - SILExtractor

/// Invokes `swiftc -emit-sil` on a Swift source file and returns the
/// parsed SIL function CFGs. Subprocess management uses the
/// project's `ProcessExecutor` so DYLD env injection vectors are
/// closed at the boundary.
///
/// Spike-level: takes one Swift file at a time, no compile-time
/// flag pass-through. A 0.4.0 production form would accept a build
/// description (compile flags, search paths, package context) and
/// drive SIL extraction per-module rather than per-file.
public enum SILExtractor {
    /// Extract SIL from a single Swift source file via `swiftc
    /// -emit-sil`. Returns parsed function CFGs, or an empty array
    /// if compilation produced no SIL (e.g. the file failed to
    /// type-check). The diagnostic text from `swiftc` is captured
    /// in `extractionFailed.stderr` on error.
    public static func extract(
        from sourceFile: String,
        swiftcPath: String = "/usr/bin/swiftc",
        extraArguments: [String] = []
    ) throws -> [SILFunction] {
        var arguments = ["-emit-sil", sourceFile]
        arguments.append(contentsOf: extraArguments)
        let result = try ProcessExecutor.run(
            executable: URL(fileURLWithPath: swiftcPath),
            arguments: arguments,
        )
        guard result.succeeded else {
            throw SILExtractionError.compilationFailed(
                stderr: result.stderr,
                exitCode: result.exitCode,
            )
        }
        return SILParser.parse(result.stdout)
    }
}

// MARK: - SILExtractionError

public enum SILExtractionError: Error, Sendable, CustomStringConvertible {
    case compilationFailed(stderr: String, exitCode: Int32)

    public var description: String {
        switch self {
        case .compilationFailed(let stderr, let code):
            return "swiftc -emit-sil failed (exit \(code)): \(stderr)"
        }
    }
}
