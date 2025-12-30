//
//  ModuleB.swift
//  SwiftStaticAnalysis
//
//  Test fixture for multiple paths support - Module B.
//

import Foundation

// MARK: - ModuleBType

public struct ModuleBType {
    // MARK: Lifecycle

    public init(id: String, value: Int) {
        self.id = id
        self.value = value
    }

    // MARK: Public

    public var id: String
    public var value: Int
}

// This function has a duplicate in Module A
public func processDataModuleB() {
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
