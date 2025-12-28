//
//  ActuallyUsedCode.swift
//  SwiftStaticAnalysis - Test Fixtures
//
//  Code that might appear unused but actually IS used.
//  These should NOT be flagged as unused.
//

import SwiftUI
import Combine

// MARK: - Protocol Witnesses

protocol ViewModelProtocol: ObservableObject {
    var title: String { get }
    func load() async
}

/// The 'title' and 'load()' are used via protocol - should NOT be flagged
class ConcreteViewModel: ViewModelProtocol {
    @Published var title: String = "Loaded"

    func load() async {
        // Protocol witness - this IS used
        title = "Loaded"
    }
}

struct ProtocolConsumerView<VM: ViewModelProtocol>: View {
    @StateObject var viewModel: VM

    var body: some View {
        VStack {
            Text(viewModel.title)  // Uses protocol property
        }
        .task {
            await viewModel.load()  // Uses protocol method
        }
    }
}

// MARK: - Implicit Usage via Key Paths

struct KeyPathUser {
    var name: String = ""
    var age: Int = 0
    var email: String = ""
}

struct KeyPathView: View {
    @State private var user = KeyPathUser()

    var body: some View {
        // These properties are accessed via key paths - should NOT be flagged
        VStack {
            TextField("Name", text: $user[keyPath: \.name])
            TextField("Email", text: $user[keyPath: \.email])
        }
    }
}

// MARK: - Codable Conformance

/// All properties are used for encoding/decoding - should NOT be flagged
struct APIResponse: Codable {
    let id: Int
    let name: String
    let createdAt: Date
    let metadata: [String: String]
}

// MARK: - Combine Publishers

class DataService: ObservableObject {
    // This publisher IS subscribed to - should NOT be flagged
    let dataPublisher = PassthroughSubject<String, Never>()

    // This cancellable stores subscription - should NOT be flagged
    private var cancellables = Set<AnyCancellable>()

    func startListening() {
        dataPublisher
            .sink { value in
                print(value)
            }
            .store(in: &cancellables)
    }
}

// MARK: - Environment Keys

/// Custom environment key - the defaultValue IS used - should NOT be flagged
private struct ThemeColorKey: EnvironmentKey {
    static let defaultValue: Color = .blue
}

extension EnvironmentValues {
    var themeColor: Color {
        get { self[ThemeColorKey.self] }
        set { self[ThemeColorKey.self] = newValue }
    }
}

// MARK: - Preference Keys

/// Custom preference key - the defaultValue and reduce ARE used - should NOT be flagged
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ScrollTrackingView: View {
    @State private var offset: CGFloat = 0

    var body: some View {
        ScrollView {
            GeometryReader { geo in
                Color.clear
                    .preference(key: ScrollOffsetPreferenceKey.self,
                              value: geo.frame(in: .global).minY)
            }
        }
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
            offset = value
        }
    }
}

// MARK: - Result Builders

/// This result builder IS used - should NOT be flagged
@resultBuilder
struct ArrayBuilder<Element> {
    static func buildBlock(_ components: Element...) -> [Element] {
        components
    }

    static func buildOptional(_ component: [Element]?) -> [Element] {
        component ?? []
    }
}

func makeArray<T>(@ArrayBuilder<T> content: () -> [T]) -> [T] {
    content()
}

// MARK: - Lazy Initialization

class ExpensiveResource {
    /// This property IS accessed lazily - should NOT be flagged
    lazy var computedValue: Int = {
        return (0..<1000).reduce(0, +)
    }()
}

// MARK: - Used in #Preview

/// This view IS used in preview macro - should NOT be flagged
struct PreviewedView: View {
    var body: some View {
        Text("I am previewed")
    }
}

#Preview {
    PreviewedView()
}

// MARK: - Implicitly Used Initializers

struct AutoInitView: View {
    // These properties require memberwise init - should NOT be flagged
    let title: String
    let subtitle: String
    var isEnabled: Bool = true

    var body: some View {
        VStack {
            Text(title)
            Text(subtitle)
        }
    }
}

struct ParentView: View {
    var body: some View {
        // Uses memberwise initializer
        AutoInitView(title: "Hello", subtitle: "World")
    }
}
