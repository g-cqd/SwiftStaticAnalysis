//
//  Reference+CustomStringConvertible.swift
//  SwiftStaticAnalysis
//

// MARK: - Reference + CustomStringConvertible

extension Reference: CustomStringConvertible {
    public var description: String {
        if let qualifier {
            return "\(qualifier).\(identifier) (\(context)) at \(location)"
        }
        return "\(identifier) (\(context)) at \(location)"
    }
}
