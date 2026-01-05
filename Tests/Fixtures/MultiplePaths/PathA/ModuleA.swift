//  ModuleA.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - ModuleAType

public struct ModuleAType {
    // MARK: Lifecycle

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    // MARK: Public

    public var id: String
    public var name: String
}

// This function has a duplicate in Module B
public func processDataModuleA() {
    let items = [1, 2, 3, 4, 5]
    for item in items {
        print("Processing item: \(item)")
        validateItem(item)
    }
    completeProcessing()
}

private func validateItem(_ item: Int) {
    // Validation
}

private func completeProcessing() {
    // Completion
}
