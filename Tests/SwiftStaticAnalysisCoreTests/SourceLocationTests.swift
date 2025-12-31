//
//  SourceLocationTests.swift
//  SwiftStaticAnalysis
//
//  Regression tests for source location reporting.
//  Ensures declarations report the line of the actual keyword,
//  not preceding comments or trivia.
//

import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import SwiftStaticAnalysisCore

// MARK: - SourceLocationTests

@Suite("Source Location Regression Tests")
struct SourceLocationTests {
  // MARK: - Line Comment Tests

  @Test("Declaration location excludes preceding line comment")
  func declarationLocationExcludesLineComment() {
    let source = """
      // This is a comment
      let myVar: String = "value"
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let myVar = collector.declarations.first { $0.name == "myVar" }

    #expect(myVar != nil)
    #expect(myVar?.location.line == 2)
  }

  @Test("Function location excludes preceding line comment")
  func functionLocationExcludesLineComment() {
    let source = """
      // A helper function
      func doSomething() {}
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let doSomething = collector.declarations.first { $0.name == "doSomething" }

    #expect(doSomething != nil)
    #expect(doSomething?.location.line == 2)
  }

  @Test("Struct location excludes preceding line comment")
  func structLocationExcludesLineComment() {
    let source = """
      // A data model
      struct User {
          let name: String
      }
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let user = collector.declarations.first { $0.name == "User" }

    #expect(user != nil)
    #expect(user?.location.line == 2)
  }

  // MARK: - Doc Comment Tests

  @Test("Declaration location excludes preceding doc comment")
  func declarationLocationExcludesDocComment() {
    let source = """
      /// The user's age in years.
      let userAge: Int = 25
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let userAge = collector.declarations.first { $0.name == "userAge" }

    #expect(userAge != nil)
    #expect(userAge?.location.line == 2)
  }

  @Test("Function location excludes preceding doc comment")
  func functionLocationExcludesDocComment() {
    let source = """
      /// Calculates the sum of two integers.
      /// - Parameters:
      ///   - a: First integer.
      ///   - b: Second integer.
      /// - Returns: The sum.
      func add(_ a: Int, _ b: Int) -> Int {
          a + b
      }
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let add = collector.declarations.first { $0.name == "add" }

    #expect(add != nil)
    #expect(add?.location.line == 6)
  }

  @Test("Class location excludes preceding doc comment")
  func classLocationExcludesDocComment() {
    let source = """
      /// A network service for API calls.
      final class NetworkService {
          func fetch() {}
      }
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let networkService = collector.declarations.first { $0.name == "NetworkService" }

    #expect(networkService != nil)
    #expect(networkService?.location.line == 2)
  }

  // MARK: - Block Comment Tests

  @Test("Declaration location excludes preceding block comment")
  func declarationLocationExcludesBlockComment() {
    let source = """
      /* Configuration constant */
      let config = "default"
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let config = collector.declarations.first { $0.name == "config" }

    #expect(config != nil)
    #expect(config?.location.line == 2)
  }

  @Test("Function location excludes preceding block comment")
  func functionLocationExcludesBlockComment() {
    let source = """
      /* A utility function */
      func utility() -> Bool {
          true
      }
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let utility = collector.declarations.first { $0.name == "utility" }

    #expect(utility != nil)
    #expect(utility?.location.line == 2)
  }

  // MARK: - Multiline Comment Tests

  @Test("Declaration location excludes preceding multiline comment")
  func declarationLocationExcludesMultilineComment() {
    let source = """
      /*
       * This is a multiline comment
       * that spans several lines
       * describing the variable below.
       */
      var counter: Int = 0
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let counter = collector.declarations.first { $0.name == "counter" }

    #expect(counter != nil)
    #expect(counter?.location.line == 6)
  }

  @Test("Function location excludes preceding multiline doc comment")
  func functionLocationExcludesMultilineDocComment() {
    let source = """
      /**
       Performs an async operation.

       - Parameter completion: The completion handler.
       */
      func performAsync(completion: @escaping () -> Void) {
          completion()
      }
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let performAsync = collector.declarations.first { $0.name == "performAsync" }

    #expect(performAsync != nil)
    #expect(performAsync?.location.line == 6)
  }

  // MARK: - Attribute Tests

  @Test("Declaration location starts at attribute, not preceding comment")
  func declarationLocationStartsAtAttribute() {
    let source = """
      // Deprecated API
      @available(*, deprecated, message: "Use newMethod instead")
      func oldMethod() {}
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let oldMethod = collector.declarations.first { $0.name == "oldMethod" }

    #expect(oldMethod != nil)
    // Attribute is part of the declaration, so location should be at the attribute
    #expect(oldMethod?.location.line == 2)
  }

  @Test("MainActor function location excludes preceding comment")
  func mainActorFunctionLocationExcludesComment() {
    let source = """
      // UI update function
      @MainActor
      func updateUI() {}
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let updateUI = collector.declarations.first { $0.name == "updateUI" }

    #expect(updateUI != nil)
    #expect(updateUI?.location.line == 2)
  }

  @Test("Property wrapper location excludes preceding comment")
  func propertyWrapperLocationExcludesComment() {
    let source = """
      struct MyView {
          // The published state
          @Published var count: Int = 0
      }
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let count = collector.declarations.first { $0.name == "count" }

    #expect(count != nil)
    #expect(count?.location.line == 3)
  }

  // MARK: - Mixed Trivia Tests

  @Test("Declaration location excludes mixed comments and blank lines")
  func declarationLocationExcludesMixedTrivia() {
    let source = """
      // MARK: - Properties

      /// The user's identifier.
      // Internal implementation note
      let userId: String = "123"
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let userId = collector.declarations.first { $0.name == "userId" }

    #expect(userId != nil)
    #expect(userId?.location.line == 5)
  }

  @Test("Function with multiple attributes excludes preceding comments")
  func functionWithMultipleAttributesExcludesComments() {
    let source = """
      // Old API
      /// Fetches data from network.
      @available(iOS 15, *)
      @MainActor
      @discardableResult
      func fetchData() async throws -> Data {
          Data()
      }
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let fetchData = collector.declarations.first { $0.name == "fetchData" }

    #expect(fetchData != nil)
    // Location should start at the first attribute after comments
    #expect(fetchData?.location.line == 3)
  }

  // MARK: - Nested Type Tests

  @Test("Nested struct member location excludes preceding comment")
  func nestedStructMemberLocationExcludesComment() {
    let source = """
      struct Outer {
          // Inner configuration
          struct Inner {
              // The value
              let value: Int
          }
      }
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let inner = collector.declarations.first { $0.name == "Inner" }
    let value = collector.declarations.first { $0.name == "value" }

    #expect(inner != nil)
    #expect(inner?.location.line == 3)

    #expect(value != nil)
    #expect(value?.location.line == 5)
  }

  @Test("Enum case location excludes preceding comment")
  func enumCaseLocationExcludesComment() {
    let source = """
      enum Status {
          // Success state
          case success
          // Failure state
          case failure
      }
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let success = collector.declarations.first { $0.name == "success" }
    let failure = collector.declarations.first { $0.name == "failure" }

    #expect(success != nil)
    #expect(success?.location.line == 3)

    #expect(failure != nil)
    #expect(failure?.location.line == 5)
  }

  @Test("Protocol member location excludes preceding comment")
  func protocolMemberLocationExcludesComment() {
    let source = """
      protocol DataService {
          /// The service identifier.
          var identifier: String { get }

          // Fetches all items
          func fetchAll() async throws
      }
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let identifier = collector.declarations.first { $0.name == "identifier" }
    let fetchAll = collector.declarations.first { $0.name == "fetchAll" }

    #expect(identifier != nil)
    #expect(identifier?.location.line == 3)

    #expect(fetchAll != nil)
    #expect(fetchAll?.location.line == 6)
  }

  // MARK: - Edge Cases

  @Test("Declaration without preceding comment has correct location")
  func declarationWithoutPrecedingCommentHasCorrectLocation() {
    let source = """
      let directDeclaration = 42
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let directDeclaration = collector.declarations.first { $0.name == "directDeclaration" }

    #expect(directDeclaration != nil)
    #expect(directDeclaration?.location.line == 1)
  }

  @Test("Declaration on same line as comment has correct location")
  func declarationOnSameLineAsCommentHasCorrectLocation() {
    let source = """
      let inlineValue = 10 // This is an inline comment
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let inlineValue = collector.declarations.first { $0.name == "inlineValue" }

    #expect(inlineValue != nil)
    #expect(inlineValue?.location.line == 1)
  }

  @Test("Multiple declarations with comments have correct locations")
  func multipleDeclarationsWithCommentsHaveCorrectLocations() {
    let source = """
      // First constant
      let first = 1
      // Second constant
      let second = 2
      // Third constant
      let third = 3
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let first = collector.declarations.first { $0.name == "first" }
    let second = collector.declarations.first { $0.name == "second" }
    let third = collector.declarations.first { $0.name == "third" }

    #expect(first?.location.line == 2)
    #expect(second?.location.line == 4)
    #expect(third?.location.line == 6)
  }

  @Test("Actor declaration location excludes preceding comment")
  func actorLocationExcludesComment() {
    let source = """
      /// A thread-safe counter.
      actor Counter {
          var count = 0
      }
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let counter = collector.declarations.first { $0.name == "Counter" }

    #expect(counter != nil)
    #expect(counter?.location.line == 2)
  }

  @Test("Extension declaration location excludes preceding comment")
  func extensionLocationExcludesComment() {
    let source = """
      // String utilities
      extension String {
          var isEmpty2: Bool { count == 0 }
      }
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let stringExtension = collector.declarations.first { $0.kind == .extension }

    #expect(stringExtension != nil)
    #expect(stringExtension?.location.line == 2)
  }

  @Test("Typealias declaration location excludes preceding comment")
  func typealiasLocationExcludesComment() {
    let source = """
      // A completion handler type
      typealias CompletionHandler = (Result<Data, Error>) -> Void
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let completionHandler = collector.declarations.first { $0.name == "CompletionHandler" }

    #expect(completionHandler != nil)
    #expect(completionHandler?.location.line == 2)
  }

  @Test("Initializer declaration location excludes preceding comment")
  func initializerLocationExcludesComment() {
    let source = """
      struct Point {
          let x: Int
          let y: Int

          // Creates a point at origin
          init() {
              self.x = 0
              self.y = 0
          }
      }
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let initializer = collector.declarations.first { $0.kind == .initializer }

    #expect(initializer != nil)
    #expect(initializer?.location.line == 6)
  }

  // MARK: - Column Location Tests

  @Test("Declaration column starts at keyword, not whitespace")
  func declarationColumnStartsAtKeyword() {
    let source = """
          let indentedVar = 1
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let indentedVar = collector.declarations.first { $0.name == "indentedVar" }

    #expect(indentedVar != nil)
    #expect(indentedVar?.location.column == 5)  // After 4 spaces
  }

  @Test("Nested declaration has correct column")
  func nestedDeclarationHasCorrectColumn() {
    let source = """
      struct Container {
          // A property
          let property: Int = 0
      }
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let property = collector.declarations.first { $0.name == "property" }

    #expect(property != nil)
    #expect(property?.location.line == 3)
    #expect(property?.location.column == 5)  // After 4 spaces of indentation
  }

  // MARK: - User Reported Scenario

  @Test("Enum after property with MARK comment has correct location")
  func enumAfterPropertyWithMARKComment() {
    // This exact scenario was reported by a user where CodingKeys was
    // reported on luckyNumber's line instead of the enum line
    let source = """
      struct MyModel: Codable {
          public let luckyNumber: UInt8

          // MARK: - CodingKeys

          enum CodingKeys: String, CodingKey {
              case luckyNumber
          }
      }
      """

    let tree = Parser.parse(source: source)
    let collector = DeclarationCollector(file: "test.swift", tree: tree)
    collector.walk(tree)

    let luckyNumber = collector.declarations.first { $0.name == "luckyNumber" }
    let codingKeys = collector.declarations.first { $0.name == "CodingKeys" }

    #expect(luckyNumber != nil)
    #expect(luckyNumber?.location.line == 2)

    #expect(codingKeys != nil)
    // CodingKeys should be on line 6 (enum keyword), not line 2 (luckyNumber)
    #expect(codingKeys?.location.line == 6)
  }
}
