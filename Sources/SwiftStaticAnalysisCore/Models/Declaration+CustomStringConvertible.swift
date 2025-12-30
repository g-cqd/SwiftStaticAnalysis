//
//  Declaration+CustomStringConvertible.swift
//  SwiftStaticAnalysis
//

// MARK: - Declaration + CustomStringConvertible

extension Declaration: CustomStringConvertible {
    public var description: String {
        "\(kind.rawValue) \(name) at \(location)"
    }
}
