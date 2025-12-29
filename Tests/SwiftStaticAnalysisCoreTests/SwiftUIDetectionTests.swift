//
//  SwiftUIDetectionTests.swift
//  SwiftStaticAnalysis
//
//  Tests for SwiftUI property wrapper and View detection.
//

import Foundation
@testable import SwiftStaticAnalysisCore
import Testing

// MARK: - PropertyWrapperDetectionTests

@Suite("SwiftUI Property Wrapper Detection")
struct PropertyWrapperDetectionTests {
    @Test("Detect @State wrapper")
    func detectStateWrapper() {
        let wrapper = PropertyWrapperInfo.parse(from: "@State")
        #expect(wrapper != nil)
        #expect(wrapper?.kind == .state)
        #expect(wrapper?.kind.isSwiftUI == true)
        #expect(wrapper?.kind.impliesUsage == true)
    }

    @Test("Detect @Binding wrapper")
    func detectBindingWrapper() {
        let wrapper = PropertyWrapperInfo.parse(from: "@Binding")
        #expect(wrapper != nil)
        #expect(wrapper?.kind == .binding)
        #expect(wrapper?.kind.isSwiftUI == true)
    }

    @Test("Detect @Environment wrapper with argument")
    func detectEnvironmentWrapper() {
        let wrapper = PropertyWrapperInfo.parse(from: "@Environment(\\.colorScheme)")
        #expect(wrapper != nil)
        #expect(wrapper?.kind == .environment)
        #expect(wrapper?.arguments == "\\.colorScheme")
    }

    @Test("Detect @StateObject wrapper")
    func detectStateObjectWrapper() {
        let wrapper = PropertyWrapperInfo.parse(from: "@StateObject")
        #expect(wrapper != nil)
        #expect(wrapper?.kind == .stateObject)
        #expect(wrapper?.kind.impliesUsage == true)
    }

    @Test("Detect @ObservedObject wrapper")
    func detectObservedObjectWrapper() {
        let wrapper = PropertyWrapperInfo.parse(from: "@ObservedObject")
        #expect(wrapper != nil)
        #expect(wrapper?.kind == .observedObject)
    }

    @Test("Detect @Published wrapper")
    func detectPublishedWrapper() {
        let wrapper = PropertyWrapperInfo.parse(from: "@Published")
        #expect(wrapper != nil)
        #expect(wrapper?.kind == .published)
        #expect(wrapper?.kind.impliesUsage == true)
    }

    @Test("Detect @AppStorage wrapper")
    func detectAppStorageWrapper() {
        let wrapper = PropertyWrapperInfo.parse(from: "@AppStorage(\"key\")")
        #expect(wrapper != nil)
        #expect(wrapper?.kind == .appStorage)
        #expect(wrapper?.arguments == "\"key\"")
    }

    @Test("Detect @FocusState wrapper")
    func detectFocusStateWrapper() {
        let wrapper = PropertyWrapperInfo.parse(from: "@FocusState")
        #expect(wrapper != nil)
        #expect(wrapper?.kind == .focusState)
    }

    @Test("Detect @GestureState wrapper")
    func detectGestureStateWrapper() {
        let wrapper = PropertyWrapperInfo.parse(from: "@GestureState")
        #expect(wrapper != nil)
        #expect(wrapper?.kind == .gestureState)
    }

    @Test("Detect @Namespace wrapper")
    func detectNamespaceWrapper() {
        let wrapper = PropertyWrapperInfo.parse(from: "@Namespace")
        #expect(wrapper != nil)
        #expect(wrapper?.kind == .namespace)
    }

    @Test("Unknown wrapper returns unknown kind")
    func detectUnknownWrapper() {
        let wrapper = PropertyWrapperInfo.parse(from: "@CustomWrapper")
        #expect(wrapper != nil)
        #expect(wrapper?.kind == .unknown)
        #expect(wrapper?.kind.isSwiftUI == false)
    }
}

// MARK: - SwiftUIConformanceTests

@Suite("SwiftUI Conformance Detection")
struct SwiftUIConformanceTests {
    @Test("View conformance detected")
    func viewConformanceDetected() {
        let conformance = SwiftUIConformance(rawValue: "View")
        #expect(conformance == .view)
        #expect(conformance?.hasImplicitBody == true)
        #expect(conformance?.isEntryPoint == false)
    }

    @Test("App conformance is entry point")
    func appConformanceIsEntryPoint() {
        let conformance = SwiftUIConformance(rawValue: "App")
        #expect(conformance == .app)
        #expect(conformance?.isEntryPoint == true)
        #expect(conformance?.hasImplicitBody == true)
    }

    @Test("PreviewProvider is entry point")
    func previewProviderIsEntryPoint() {
        let conformance = SwiftUIConformance(rawValue: "PreviewProvider")
        #expect(conformance == .previewProvider)
        #expect(conformance?.isEntryPoint == true)
    }

    @Test("ViewModifier has implicit body")
    func viewModifierHasImplicitBody() {
        let conformance = SwiftUIConformance(rawValue: "ViewModifier")
        #expect(conformance == .viewModifier)
        #expect(conformance?.hasImplicitBody == true)
    }

    @Test("SwiftUITypeInfo tracks multiple conformances")
    func swiftUITypeInfoTracksConformances() {
        let info = SwiftUITypeInfo(conformances: [.view, .previewProvider])
        #expect(info.isView == true)
        #expect(info.isPreview == true)
        #expect(info.isApp == false)
        #expect(info.hasImplicitBody == true)
    }
}

// MARK: - DeclarationSwiftUIExtensionTests

@Suite("Declaration SwiftUI Extensions")
struct DeclarationSwiftUIExtensionTests {
    @Test("Declaration with State wrapper has implicit usage")
    func declarationWithStateHasImplicitUsage() {
        let stateWrapper = PropertyWrapperInfo(kind: .state, attributeText: "@State")
        let declaration = Declaration(
            name: "count",
            kind: .variable,
            location: SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0),
            range: SourceRange(
                start: SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0),
                end: SourceLocation(file: "test.swift", line: 1, column: 10, offset: 10),
            ),
            scope: .global,
            propertyWrappers: [stateWrapper],
        )

        #expect(declaration.hasSwiftUIPropertyWrapper == true)
        #expect(declaration.hasImplicitUsageWrapper == true)
        #expect(declaration.primaryPropertyWrapper == .state)
    }

    @Test("Declaration with View conformance is SwiftUI View")
    func declarationWithViewConformanceIsSwiftUIView() {
        let swiftUIInfo = SwiftUITypeInfo(conformances: [.view])
        let declaration = Declaration(
            name: "ContentView",
            kind: .struct,
            location: SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0),
            range: SourceRange(
                start: SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0),
                end: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100),
            ),
            scope: .global,
            swiftUIInfo: swiftUIInfo,
            conformances: ["View"],
        )

        #expect(declaration.isSwiftUIView == true)
        #expect(declaration.isSwiftUIApp == false)
        #expect(declaration.hasImplicitBody == true)
    }

    @Test("Declaration with App conformance is SwiftUI App")
    func declarationWithAppConformanceIsSwiftUIApp() {
        let swiftUIInfo = SwiftUITypeInfo(conformances: [.app])
        let declaration = Declaration(
            name: "MyApp",
            kind: .struct,
            location: SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0),
            range: SourceRange(
                start: SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0),
                end: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100),
            ),
            scope: .global,
            swiftUIInfo: swiftUIInfo,
            conformances: ["App"],
        )

        #expect(declaration.isSwiftUIView == false)
        #expect(declaration.isSwiftUIApp == true)
    }
}

// MARK: - SwiftUISourceParsingTests

@Suite("SwiftUI Source Parsing")
struct SwiftUISourceParsingTests {
    @Test("Parse SwiftUI View with @State properties")
    func parseSwiftUIViewWithStateProperties() async throws {
        let source = """
        import SwiftUI

        struct CounterView: View {
            @State private var count: Int = 0
            @State private var name: String = ""

            var body: some View {
                Text("Count: \\(count)")
            }
        }
        """

        let parser = SwiftFileParser()
        let tree = try await parser.parse(source: source)

        let collector = DeclarationCollector(file: "test.swift", tree: tree)
        collector.walk(tree)

        let declarations = collector.declarations

        // Find the struct
        let structDecl = declarations.first { $0.name == "CounterView" && $0.kind == .struct }
        #expect(structDecl != nil)
        #expect(structDecl?.isSwiftUIView == true)
        #expect(structDecl?.conformances.contains("View") == true)

        // Find @State properties
        let stateProps = declarations.filter(\.hasSwiftUIPropertyWrapper)
        #expect(stateProps.count == 2)

        // All @State properties should have implicit usage
        for prop in stateProps {
            #expect(prop.hasImplicitUsageWrapper == true)
        }
    }

    @Test("Parse SwiftUI App entry point")
    func parseSwiftUIAppEntryPoint() async throws {
        let source = """
        import SwiftUI

        @main
        struct MyApp: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }
        """

        let parser = SwiftFileParser()
        let tree = try await parser.parse(source: source)

        let collector = DeclarationCollector(file: "test.swift", tree: tree)
        collector.walk(tree)

        let appDecl = collector.declarations.first { $0.name == "MyApp" }
        #expect(appDecl != nil)
        #expect(appDecl?.isSwiftUIApp == true)
    }

    @Test("Parse View with multiple property wrappers")
    func parseViewWithMultiplePropertyWrappers() async throws {
        let source = """
        import SwiftUI

        struct SettingsView: View {
            @State private var isEnabled: Bool = false
            @Binding var value: String
            @Environment(\\.colorScheme) private var colorScheme
            @StateObject private var viewModel = ViewModel()

            var body: some View {
                Text("Settings")
            }
        }

        class ViewModel: ObservableObject {
            @Published var data: [String] = []
        }
        """

        let parser = SwiftFileParser()
        let tree = try await parser.parse(source: source)

        let collector = DeclarationCollector(file: "test.swift", tree: tree)
        collector.walk(tree)

        // Check property wrappers
        let isEnabled = collector.declarations.first { $0.name == "isEnabled" }
        #expect(isEnabled?.primaryPropertyWrapper == .state)

        let value = collector.declarations.first { $0.name == "value" }
        #expect(value?.primaryPropertyWrapper == .binding)

        let colorScheme = collector.declarations.first { $0.name == "colorScheme" }
        #expect(colorScheme?.primaryPropertyWrapper == .environment)

        let viewModel = collector.declarations.first { $0.name == "viewModel" }
        #expect(viewModel?.primaryPropertyWrapper == .stateObject)

        let data = collector.declarations.first { $0.name == "data" }
        #expect(data?.primaryPropertyWrapper == .published)
    }
}
