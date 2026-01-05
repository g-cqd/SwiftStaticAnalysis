//  Declaration+CustomStringConvertible.swift
//  SwiftStaticAnalysis
//  MIT License

extension Declaration: CustomStringConvertible {
    public var description: String {
        "\(kind.rawValue) \(name) at \(location)"
    }
}
