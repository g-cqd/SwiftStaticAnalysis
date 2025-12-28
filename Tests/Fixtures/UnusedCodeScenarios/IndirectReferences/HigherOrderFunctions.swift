//
//  HigherOrderFunctions.swift
//  SwiftStaticAnalysis - Test Fixtures
//
//  This file tests indirect references through higher-order functions.
//  Some functions appear unused but are passed as closures.
//

import Foundation

// MARK: - Functions Passed as Closures (Should NOT be flagged)

/// This function appears unused but is passed to array
private func foo() { print("foo") }

/// This function appears unused but is passed as a callback
private func handleSuccess() { print("Success!") }

/// This function appears unused but is stored in a dictionary
private func processA() { print("Processing A") }
private func processB() { print("Processing B") }

/// This function IS actually unused
private func bar() { print("bar") }  // SHOULD BE FLAGGED

/// This function IS actually unused
private func unusedHelper() { print("unused") }  // SHOULD BE FLAGGED

// MARK: - Indirect Usage Patterns

/// Functions array - foo() is referenced here
let functions: [() -> Void] = [foo]

/// Dictionary of handlers
let processors: [String: () -> Void] = [
    "A": processA,
    "B": processB
]

/// Callback storage
class CallbackManager {
    var onSuccess: (() -> Void)?

    init() {
        // handleSuccess is used here indirectly
        onSuccess = handleSuccess
    }

    func execute() {
        onSuccess?()
    }
}

// MARK: - Higher-Order Function Calls

func executeAll() {
    functions.forEach { $0() }
    processors.values.forEach { $0() }
}

// MARK: - Partially Referenced Closures

/// This function is used as a selector
private func transform(_ value: Int) -> Int {
    value * 2
}

/// This function is NOT used
private func unusedTransform(_ value: Int) -> Int {  // SHOULD BE FLAGGED
    value * 3
}

let numbers = [1, 2, 3, 4, 5]
let doubled = numbers.map(transform)  // transform is used here

// MARK: - Optional Closure References

private func optionalHandler() { print("optional") }

var optionalCallback: (() -> Void)? = nil

func setupOptionalCallback() {
    optionalCallback = optionalHandler  // optionalHandler is used
}

// MARK: - Type Alias References

typealias Handler = () -> Void

private func aliasedHandler() { print("aliased") }

let handlerRef: Handler = aliasedHandler  // Used through type alias

// MARK: - Completely Unused Section

/// These are definitely unused
private func neverCalled1() { print("never1") }  // SHOULD BE FLAGGED
private func neverCalled2() { print("never2") }  // SHOULD BE FLAGGED
private func neverCalled3() { print("never3") }  // SHOULD BE FLAGGED

private var unusedVariable = 42  // SHOULD BE FLAGGED
private let unusedConstant = "unused"  // SHOULD BE FLAGGED

private class UnusedClass {  // SHOULD BE FLAGGED
    func unusedMethod() {}
}
