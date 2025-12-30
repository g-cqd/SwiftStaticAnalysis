//
//  ActuallyUsedCode.swift
//  SwiftStaticAnalysis - Test Fixtures
//
//  Code that might appear unused but actually IS used.
//  These should NOT be flagged as unused.
//

import Combine
import SwiftUI

// MARK: - ViewModelProtocol

protocol ViewModelProtocol: ObservableObject {
    var title: String { get }
    func load() async
}

// MARK: - ConcreteViewModel

/// The 'title' and 'load()' are used via protocol - should NOT be flagged
class ConcreteViewModel: ViewModelProtocol {
    @Published var title: String = "Loaded"

    func load() async {
        // Protocol witness - this IS used
        title = "Loaded"
    }
}

// MARK: - ProtocolConsumerView

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

// MARK: - KeyPathUser

struct KeyPathUser {
    var name: String = ""
    var age: Int = 0
    var email: String = ""
}

// MARK: - KeyPathView

struct KeyPathView: View {
    // MARK: Internal

    var body: some View {
        // These properties are accessed via key paths - should NOT be flagged
        VStack {
            TextField("Name", text: $user[keyPath: \.name])
            TextField("Email", text: $user[keyPath: \.email])
        }
    }

    // MARK: Private

    @State private var user = KeyPathUser()
}

// MARK: - APIResponse

/// All properties are used for encoding/decoding - should NOT be flagged
struct APIResponse: Codable {
    let id: Int
    let name: String
    let createdAt: Date
    let metadata: [String: String]
}

// MARK: - DataService

class DataService: ObservableObject {
    // MARK: Internal

    // This publisher IS subscribed to - should NOT be flagged
    let dataPublisher = PassthroughSubject<String, Never>()

    func startListening() {
        dataPublisher
            .sink { value in
                print(value)
            }
            .store(in: &cancellables)
    }

    // MARK: Private

    // This cancellable stores subscription - should NOT be flagged
    private var cancellables = Set<AnyCancellable>()
}

// MARK: - ThemeColorKey

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

// MARK: - ScrollOffsetPreferenceKey

/// Custom preference key - the defaultValue and reduce ARE used - should NOT be flagged
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - ScrollTrackingView

struct ScrollTrackingView: View {
    // MARK: Internal

    var body: some View {
        ScrollView {
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: ScrollOffsetPreferenceKey.self,
                        value: geo.frame(in: .global).minY)
            }
        }
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
            offset = value
        }
    }

    // MARK: Private

    @State private var offset: CGFloat = 0
}

// MARK: - ArrayBuilder

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

// MARK: - ExpensiveResource

class ExpensiveResource {
    /// This property IS accessed lazily - should NOT be flagged
    lazy var computedValue: Int = (0..<1000).reduce(0, +)
}

// MARK: - PreviewedView

/// This view IS used in preview macro - should NOT be flagged
struct PreviewedView: View {
    var body: some View {
        Text("I am previewed")
    }
}

#Preview {
    PreviewedView()
}

// MARK: - AutoInitView

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

// MARK: - ParentView

struct ParentView: View {
    var body: some View {
        // Uses memberwise initializer
        AutoInitView(title: "Hello", subtitle: "World")
    }
}
