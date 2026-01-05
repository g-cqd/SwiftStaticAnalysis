//  Conformances.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - Displayable

protocol Displayable {
    func display()
}

// MARK: - Identifiable

protocol Identifiable {
    var id: String { get }
}

// MARK: - Comparable

protocol Comparable {
    func compare(to other: Self) -> Int
}

// MARK: - Processable

protocol Processable {
    associatedtype Output
    func process() -> Output
}

// MARK: - User

struct User: Displayable, Identifiable {
    let name: String

    /// This property appears unused but satisfies Identifiable protocol
    var id: String {
        "user-\(name)"
    }

    /// This method appears unused but satisfies Displayable protocol
    func display() {
        print("User: \(name)")
    }
}

// MARK: - Product

struct Product: Displayable, Identifiable {
    let title: String
    let price: Double

    /// Protocol witness - should NOT be flagged
    var id: String {
        "product-\(title)"
    }

    /// Protocol witness - should NOT be flagged
    func display() {
        print("Product: \(title) - $\(price)")
    }
}

// MARK: - Order

struct Order: Processable {
    let items: [String]

    /// Protocol witness with associated type - should NOT be flagged
    func process() -> [String] {
        items.map { "Processed: \($0)" }
    }
}

// MARK: - Generic Protocol Usage

func showAll(_ items: [any Displayable]) {
    for item in items {
        item.display()
    }
}

func getAllIds(_ items: [some Identifiable]) -> [String] {
    items.map(\.id)
}

// MARK: - Point

struct Point: Equatable, Hashable {
    let x: Int
    let y: Int

    /// Synthesized but could be manual - should NOT be flagged
    static func == (lhs: Point, rhs: Point) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y
    }

    /// Protocol witness - should NOT be flagged
    func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }
}

// MARK: - Config

struct Config: Codable {
    /// CodingKeys is a protocol requirement - should NOT be flagged
    enum CodingKeys: String, CodingKey {
        case name
        case value = "val"
    }

    let name: String
    let value: Int
}

// MARK: - DebugInfo

struct DebugInfo: CustomStringConvertible {
    let message: String

    /// Protocol witness - should NOT be flagged
    var description: String {
        "Debug: \(message)"
    }
}

// MARK: - UnusedStruct

/// This method is NOT a protocol witness
struct UnusedStruct {
    /// Not a protocol requirement - SHOULD BE FLAGGED
    private var unusedProperty: Int {
        42
    }

    /// Not a protocol requirement - SHOULD BE FLAGGED
    private func unusedMethod() {
        print("unused")
    }
}

// MARK: - NonConformingClass

/// This class doesn't conform to any protocol
class NonConformingClass {
    /// SHOULD BE FLAGGED
    private func helper() {
        print("helper")
    }
}

// MARK: - Defaultable

protocol Defaultable {
    func requiredMethod()
    func optionalMethod()
}

extension Defaultable {
    /// Default implementation - should NOT be flagged when used
    func optionalMethod() {
        print("default implementation")
    }
}

// MARK: - DefaultUser

struct DefaultUser: Defaultable {
    /// Required - should NOT be flagged
    func requiredMethod() {
        print("required")
    }

    // Note: optionalMethod uses default implementation
}

// MARK: - Main Entry for Testing

func runConformanceTests() {
    let users: [any Displayable] = [
        User(name: "Alice"),
        Product(title: "Widget", price: 9.99),
    ]
    showAll(users)

    let items = [User(name: "Bob"), User(name: "Charlie")]
    let ids = getAllIds(items)
    print(ids)

    let order = Order(items: ["A", "B", "C"])
    print(order.process())
}
