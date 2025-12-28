//
//  Conformances.swift
//  SwiftStaticAnalysis - Test Fixtures
//
//  This file tests protocol witness handling.
//  Methods that satisfy protocol requirements should NOT be flagged as unused.
//

import Foundation

// MARK: - Protocol Definitions

protocol Displayable {
    func display()
}

protocol Identifiable {
    var id: String { get }
}

protocol Comparable {
    func compare(to other: Self) -> Int
}

protocol Processable {
    associatedtype Output
    func process() -> Output
}

// MARK: - Protocol Conformances (Methods Should NOT Be Flagged)

struct User: Displayable, Identifiable {
    let name: String

    /// This method appears unused but satisfies Displayable protocol
    func display() {
        print("User: \(name)")
    }

    /// This property appears unused but satisfies Identifiable protocol
    var id: String {
        "user-\(name)"
    }
}

struct Product: Displayable, Identifiable {
    let title: String
    let price: Double

    /// Protocol witness - should NOT be flagged
    func display() {
        print("Product: \(title) - $\(price)")
    }

    /// Protocol witness - should NOT be flagged
    var id: String {
        "product-\(title)"
    }
}

struct Order: Processable {
    let items: [String]

    /// Protocol witness with associated type - should NOT be flagged
    func process() -> [String] {
        items.map { "Processed: \($0)" }
    }
}

// MARK: - Generic Protocol Usage

func showAll(_ items: [any Displayable]) {
    items.forEach { $0.display() }
}

func getAllIds<T: Identifiable>(_ items: [T]) -> [String] {
    items.map(\.id)
}

// MARK: - Equatable/Hashable Conformance

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

// MARK: - Codable Conformance

struct Config: Codable {
    let name: String
    let value: Int

    /// CodingKeys is a protocol requirement - should NOT be flagged
    enum CodingKeys: String, CodingKey {
        case name
        case value = "val"
    }
}

// MARK: - CustomStringConvertible

struct DebugInfo: CustomStringConvertible {
    let message: String

    /// Protocol witness - should NOT be flagged
    var description: String {
        "Debug: \(message)"
    }
}

// MARK: - Actually Unused Code (SHOULD Be Flagged)

/// This method is NOT a protocol witness
struct UnusedStruct {
    /// Not a protocol requirement - SHOULD BE FLAGGED
    private func unusedMethod() {
        print("unused")
    }

    /// Not a protocol requirement - SHOULD BE FLAGGED
    private var unusedProperty: Int {
        42
    }
}

/// This class doesn't conform to any protocol
class NonConformingClass {
    /// SHOULD BE FLAGGED
    private func helper() {
        print("helper")
    }
}

// MARK: - Protocol with Default Implementation

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
        Product(title: "Widget", price: 9.99)
    ]
    showAll(users)

    let items = [User(name: "Bob"), User(name: "Charlie")]
    let ids = getAllIds(items)
    print(ids)

    let order = Order(items: ["A", "B", "C"])
    print(order.process())
}
