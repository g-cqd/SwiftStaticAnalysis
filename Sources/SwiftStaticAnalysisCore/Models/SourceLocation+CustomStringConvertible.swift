//  SourceLocation+CustomStringConvertible.swift
//  SwiftStaticAnalysis
//  MIT License

extension SourceLocation: CustomStringConvertible {
    public var description: String {
        "\(file):\(line):\(column)"
    }
}

// MARK: - SourceRange + CustomStringConvertible

extension SourceRange: CustomStringConvertible {
    public var description: String {
        if start.line == end.line {
            "\(start.file):\(start.line):\(start.column)-\(end.column)"
        } else {
            "\(start.file):\(start.line)-\(end.line)"
        }
    }
}
