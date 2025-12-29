//
//  Declaration.swift
//  SwiftStaticAnalysis
//

import Foundation

// MARK: - DeclarationKind

/// The kind of declaration.
///
/// This enum is intentionally exhaustive to cover all Swift declaration types.
/// Some cases may not be directly used within this codebase but exist for
/// API consumers and future extensibility. // swa:ignore-unused-cases
public enum DeclarationKind: String, Sendable, Codable, CaseIterable {
    case function
    case method
    case initializer
    case deinitializer
    case variable
    case constant
    case parameter
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case `extension`
    case `typealias`
    case `associatedtype`
    case `import`
    case `subscript`
    case `operator`
    case enumCase
}

// MARK: - AccessLevel

/// Swift access level modifiers.
/// Intentionally exhaustive for API completeness. // swa:ignore-unused-cases
public enum AccessLevel: String, Sendable, Codable, Comparable {
    case `private`
    case `fileprivate`
    case `internal`
    case package
    case `public`
    case open

    // MARK: Public

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    // MARK: Private

    private var rank: Int {
        switch self {
        case .private: 0
        case .fileprivate: 1
        case .internal: 2
        case .package: 3
        case .public: 4
        case .open: 5
        }
    }
}

// MARK: - DeclarationModifiers

/// Modifiers that can be applied to declarations.
public struct DeclarationModifiers: OptionSet, Sendable, Codable, Hashable {
    // MARK: Lifecycle

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    // MARK: Public

    public static let `static` = Self(rawValue: 1 << 0)
    public static let `class` = Self(rawValue: 1 << 1)
    public static let final = Self(rawValue: 1 << 2)
    public static let override = Self(rawValue: 1 << 3)
    public static let mutating = Self(rawValue: 1 << 4)
    public static let nonmutating = Self(rawValue: 1 << 5)
    public static let lazy = Self(rawValue: 1 << 6)
    public static let weak = Self(rawValue: 1 << 7)
    public static let unowned = Self(rawValue: 1 << 8)
    public static let optional = Self(rawValue: 1 << 9)
    public static let required = Self(rawValue: 1 << 10)
    public static let convenience = Self(rawValue: 1 << 11)
    public static let async = Self(rawValue: 1 << 12)
    public static let `throws` = Self(rawValue: 1 << 13)
    public static let `rethrows` = Self(rawValue: 1 << 14)
    public static let nonisolated = Self(rawValue: 1 << 15)
    public static let consuming = Self(rawValue: 1 << 16)
    public static let borrowing = Self(rawValue: 1 << 17)

    public let rawValue: UInt32
}

// MARK: - Declaration

/// Represents a declaration in Swift source code.
public struct Declaration: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(
        name: String,
        kind: DeclarationKind,
        accessLevel: AccessLevel = .internal,
        modifiers: DeclarationModifiers = [],
        location: SourceLocation,
        range: SourceRange,
        scope: ScopeID,
        typeAnnotation: String? = nil,
        genericParameters: [String] = [],
        documentation: String? = nil,
        propertyWrappers: [PropertyWrapperInfo] = [],
        swiftUIInfo: SwiftUITypeInfo? = nil,
        conformances: [String] = [],
        attributes: [String] = [],
        ignoreDirectives: Set<String> = [],
    ) {
        self.name = name
        self.kind = kind
        self.accessLevel = accessLevel
        self.modifiers = modifiers
        self.location = location
        self.range = range
        self.scope = scope
        self.typeAnnotation = typeAnnotation
        self.genericParameters = genericParameters
        self.documentation = documentation
        self.propertyWrappers = propertyWrappers
        self.swiftUIInfo = swiftUIInfo
        self.conformances = conformances
        self.attributes = attributes
        self.ignoreDirectives = ignoreDirectives
    }

    // MARK: Public

    /// The declared name.
    public let name: String

    /// Kind of declaration.
    public let kind: DeclarationKind

    /// Access level.
    public let accessLevel: AccessLevel

    /// Applied modifiers.
    public let modifiers: DeclarationModifiers

    /// Location in source.
    public let location: SourceLocation

    /// Range of the entire declaration.
    public let range: SourceRange

    /// Scope containing this declaration.
    public let scope: ScopeID

    /// Type annotation (if present).
    public let typeAnnotation: String?

    /// Generic parameters (if any).
    public let genericParameters: [String]

    /// Documentation comment (if any).
    public let documentation: String?

    /// Property wrappers applied to this declaration (for variables/constants).
    public let propertyWrappers: [PropertyWrapperInfo]

    /// SwiftUI type information (for struct/class declarations).
    public let swiftUIInfo: SwiftUITypeInfo?

    /// Protocol conformances declared on this type.
    public let conformances: [String]

    /// Attributes applied to this declaration (e.g., @main, @objc, @IBAction).
    public let attributes: [String]

    /// Ignore directive categories from comments (e.g., "unused", "unused_cases", "all").
    public let ignoreDirectives: Set<String>
}

// MARK: - Declaration SwiftUI Extensions

public extension Declaration {
    /// Whether this declaration has SwiftUI property wrappers.
    var hasSwiftUIPropertyWrapper: Bool {
        propertyWrappers.contains { $0.kind.isSwiftUI }
    }

    /// Whether this declaration's property wrappers imply usage.
    var hasImplicitUsageWrapper: Bool {
        propertyWrappers.contains { $0.kind.impliesUsage }
    }

    /// Whether this is a SwiftUI View type.
    var isSwiftUIView: Bool {
        swiftUIInfo?.isView ?? false
    }

    /// Whether this is a SwiftUI App entry point.
    var isSwiftUIApp: Bool {
        swiftUIInfo?.isApp ?? false
    }

    /// Whether this is a SwiftUI preview.
    var isSwiftUIPreview: Bool {
        swiftUIInfo?.isPreview ?? false
    }

    /// Whether this declaration's body property is implicitly used.
    var hasImplicitBody: Bool {
        swiftUIInfo?.hasImplicitBody ?? false
    }

    /// The primary property wrapper kind (if any).
    var primaryPropertyWrapper: PropertyWrapperKind? {
        propertyWrappers.first?.kind
    }

    /// Whether this declaration has an ignore directive for the given category.
    ///
    /// - Parameter category: The category to check (e.g., "unused", "unused_cases").
    ///                       If nil, checks for "all" directive.
    /// - Returns: True if this declaration should be ignored for the category.
    func hasIgnoreDirective(for category: String? = nil) -> Bool {
        if ignoreDirectives.contains("all") {
            return true
        }
        if let category {
            return ignoreDirectives.contains(category.lowercased().replacingOccurrences(of: "-", with: "_"))
        }
        return false
    }

    /// Whether this declaration should be ignored for unused code detection.
    var shouldIgnoreUnused: Bool {
        hasIgnoreDirective(for: "unused") ||
            hasIgnoreDirective(for: "unused_code") ||
            (kind == .enumCase && hasIgnoreDirective(for: "unused_cases"))
    }
}

// MARK: - DeclarationIndex

/// Index of declarations for fast lookup.
public struct DeclarationIndex: Sendable {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    /// All declarations.
    public private(set) var declarations: [Declaration] = []

    /// Declarations indexed by name.
    public private(set) var byName: [String: [Declaration]] = [:]

    /// Declarations indexed by kind.
    public private(set) var byKind: [DeclarationKind: [Declaration]] = [:]

    /// Declarations indexed by file.
    public private(set) var byFile: [String: [Declaration]] = [:]

    /// Declarations indexed by scope.
    public private(set) var byScope: [ScopeID: [Declaration]] = [:]

    /// Add a declaration to the index.
    public mutating func add(_ declaration: Declaration) {
        declarations.append(declaration)
        byName[declaration.name, default: []].append(declaration)
        byKind[declaration.kind, default: []].append(declaration)
        byFile[declaration.location.file, default: []].append(declaration)
        byScope[declaration.scope, default: []].append(declaration)
    }

    /// Find declarations matching a name.
    public func find(name: String) -> [Declaration] {
        byName[name] ?? []
    }

    /// Find declarations of a specific kind.
    public func find(kind: DeclarationKind) -> [Declaration] {
        byKind[kind] ?? []
    }

    /// Find declarations in a specific file.
    public func find(inFile file: String) -> [Declaration] {
        byFile[file] ?? []
    }

    /// Find declarations in a specific scope.
    public func find(inScope scope: ScopeID) -> [Declaration] {
        byScope[scope] ?? []
    }
}

// MARK: - Declaration + CustomStringConvertible

extension Declaration: CustomStringConvertible {
    public var description: String {
        "\(kind.rawValue) \(name) at \(location)"
    }
}
