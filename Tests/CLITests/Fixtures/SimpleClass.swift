//  SimpleClass.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - SimpleClass

final class SimpleClass {
    // MARK: - Properties

    private let id: String
    private var name: String
    private var unusedProperty: Int = 0

    // MARK: - Initialization

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    // MARK: - Methods

    func getName() -> String {
        return name
    }

    func setName(_ newName: String) {
        name = newName
    }

    func getId() -> String {
        return id
    }

    private func unusedMethod() {
        print("This method is never called")
    }
}

// MARK: - Helper Functions

func createSimpleClass(id: String, name: String) -> SimpleClass {
    return SimpleClass(id: id, name: name)
}

func unusedHelperFunction() {
    print("This function is never called")
}

// MARK: - Protocol

protocol SimpleProtocol {
    func doSomething()
}

// MARK: - Extension

extension SimpleClass: SimpleProtocol {
    func doSomething() {
        print("Doing something with \(name)")
    }
}

// MARK: - Enum

enum SimpleEnum {
    case optionA
    case optionB
    case optionC
}

// MARK: - Struct

struct SimpleStruct {
    let value: Int
    var mutableValue: String

    func getValue() -> Int {
        return value
    }
}
