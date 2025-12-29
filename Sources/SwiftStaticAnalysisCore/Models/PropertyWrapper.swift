//
//  PropertyWrapper.swift
//  SwiftStaticAnalysis
//
//  Property wrapper detection for SwiftUI and other frameworks.
//

import Foundation

// MARK: - PropertyWrapperKind

/// Known property wrapper types.
/// Exhaustive coverage of common property wrappers for framework detection. // swa:ignore-unused-cases
public enum PropertyWrapperKind: String, Sendable, Codable, CaseIterable {
    // MARK: - SwiftUI State Management

    case state = "State"
    case binding = "Binding"
    case environment = "Environment"
    case environmentObject = "EnvironmentObject"
    case stateObject = "StateObject"
    case observedObject = "ObservedObject"

    // MARK: - SwiftUI Persistence

    case appStorage = "AppStorage"
    case sceneStorage = "SceneStorage"

    // MARK: - SwiftUI Focus

    case focusState = "FocusState"
    case focusedValue = "FocusedValue"
    case focusedBinding = "FocusedBinding"

    // MARK: - SwiftUI Gestures

    case gestureState = "GestureState"

    // MARK: - SwiftUI Animation

    case namespace = "Namespace"

    // MARK: - SwiftData

    case query = "Query"
    case attribute = "Attribute"
    case relationship = "Relationship"

    // MARK: - Core Data

    case fetchRequest = "FetchRequest"
    case sectionedFetchRequest = "SectionedFetchRequest"

    // MARK: - Combine

    case published = "Published"

    // MARK: - Concurrency

    case mainActor = "MainActor"

    // MARK: - Other Common Wrappers

    case unknown = "Unknown"

    // MARK: Lifecycle

    /// Initialize from an attribute name string.
    public init(attributeName: String) {
        // Strip leading @ if present
        let name = attributeName.hasPrefix("@")
            ? String(attributeName.dropFirst())
            : attributeName

        // Handle generic wrappers like State<Int> -> State
        let baseName = name.components(separatedBy: "<").first ?? name

        self = PropertyWrapperKind(rawValue: baseName) ?? .unknown
    }

    // MARK: Public

    /// Whether this property wrapper is SwiftUI-specific.
    public var isSwiftUI: Bool {
        switch self {
        case .appStorage,
             .binding,
             .environment,
             .environmentObject,
             .focusedBinding,
             .focusedValue,
             .focusState,
             .gestureState,
             .namespace,
             .observedObject,
             .sceneStorage,
             .state,
             .stateObject:
            true

        default:
            false
        }
    }

    /// Whether properties with this wrapper are implicitly used.
    ///
    /// SwiftUI property wrappers create synthesized accessors that may not
    /// be detected as direct references. Properties with these wrappers
    /// should generally not be flagged as unused.
    public var impliesUsage: Bool {
        switch self {
        case .appStorage,
             .binding,
             .environment,
             .environmentObject,
             .focusState,
             .gestureState,
             .namespace,
             .observedObject,
             .published,
             .sceneStorage,
             .state,
             .stateObject:
            true

        default:
            false
        }
    }
}

// MARK: - PropertyWrapperInfo

/// Information about a property wrapper applied to a declaration.
public struct PropertyWrapperInfo: Sendable, Codable, Hashable {
    // MARK: Lifecycle

    public init(kind: PropertyWrapperKind, attributeText: String, arguments: String? = nil) {
        self.kind = kind
        self.attributeText = attributeText
        self.arguments = arguments
    }

    // MARK: Public

    /// The kind of property wrapper.
    public let kind: PropertyWrapperKind

    /// The full attribute text (e.g., "@State", "@Environment(\\.colorScheme)").
    public let attributeText: String

    /// Arguments to the wrapper (if any).
    public let arguments: String?

    /// Parse a property wrapper from attribute text.
    public static func parse(from attributeText: String) -> PropertyWrapperInfo? {
        // Extract the wrapper name
        var text = attributeText
        if text.hasPrefix("@") {
            text = String(text.dropFirst())
        }

        // Extract arguments if present
        var arguments: String?
        if let parenStart = text.firstIndex(of: "("),
           let parenEnd = text.lastIndex(of: ")") {
            arguments = String(text[text.index(after: parenStart) ..< parenEnd])
            text = String(text[..<parenStart])
        }

        // Handle generic parameters
        if let angleStart = text.firstIndex(of: "<") {
            text = String(text[..<angleStart])
        }

        let kind = PropertyWrapperKind(rawValue: text) ?? .unknown
        return PropertyWrapperInfo(kind: kind, attributeText: attributeText, arguments: arguments)
    }
}

// MARK: - SwiftUIConformance

/// SwiftUI protocol conformances that affect analysis.
/// Exhaustive coverage for SwiftUI framework detection. // swa:ignore-unused-cases
public enum SwiftUIConformance: String, Sendable, Codable, CaseIterable {
    /// Conforms to SwiftUI.View
    case view = "View"

    /// Conforms to SwiftUI.ViewModifier
    case viewModifier = "ViewModifier"

    /// Conforms to SwiftUI.PreviewProvider
    case previewProvider = "PreviewProvider"

    /// Conforms to SwiftUI.App
    case app = "App"

    /// Conforms to SwiftUI.Scene
    case scene = "Scene"

    /// Conforms to SwiftUI.Commands
    case commands = "Commands"

    /// Conforms to SwiftUI.ToolbarContent
    case toolbarContent = "ToolbarContent"

    /// Conforms to SwiftUI.CustomizableToolbarContent
    case customizableToolbarContent = "CustomizableToolbarContent"

    /// Conforms to SwiftUI.TableRowContent
    case tableRowContent = "TableRowContent"

    /// Conforms to SwiftUI.TableColumnContent
    case tableColumnContent = "TableColumnContent"

    /// Conforms to SwiftUI.DynamicProperty
    case dynamicProperty = "DynamicProperty"

    // MARK: Public

    /// Whether this conformance makes the type an entry point.
    public var isEntryPoint: Bool {
        switch self {
        case .app,
             .previewProvider:
            true

        default:
            false
        }
    }

    /// Whether the `body` property is implicitly used.
    public var hasImplicitBody: Bool {
        switch self {
        case .app,
             .commands,
             .customizableToolbarContent,
             .scene,
             .tableColumnContent,
             .tableRowContent,
             .toolbarContent,
             .view,
             .viewModifier:
            true

        default:
            false
        }
    }
}

// MARK: - SwiftUITypeInfo

/// Additional information for SwiftUI types.
public struct SwiftUITypeInfo: Sendable, Codable, Hashable {
    // MARK: Lifecycle

    public init(conformances: Set<SwiftUIConformance>) {
        self.conformances = conformances
    }

    // MARK: Public

    /// Empty info for non-SwiftUI types.
    public static let none = SwiftUITypeInfo(conformances: [])

    /// SwiftUI protocol conformances.
    public let conformances: Set<SwiftUIConformance>

    /// Whether this is a View type.
    public var isView: Bool {
        conformances.contains(.view)
    }

    /// Whether this is an App entry point.
    public var isApp: Bool {
        conformances.contains(.app)
    }

    /// Whether this is a preview provider.
    public var isPreview: Bool {
        conformances.contains(.previewProvider)
    }

    /// Whether this type's body is implicitly used.
    public var hasImplicitBody: Bool {
        conformances.contains { $0.hasImplicitBody }
    }
}
