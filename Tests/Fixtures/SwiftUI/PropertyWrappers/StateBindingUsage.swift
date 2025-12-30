//
//  StateBindingUsage.swift
//  SwiftStaticAnalysis - Test Fixtures
//
//  Tests for SwiftUI property wrapper detection.
//  These properties should NOT be flagged as unused.
//

import SwiftUI

// MARK: - CounterView

struct CounterView: View {
    // MARK: Internal

    var body: some View {
        VStack {
            Text("Count: \(count)")
            Toggle("Enabled", isOn: $isEnabled)
            TextField("Name", text: $userName)
            Button("Increment") {
                count += 1
            }
        }
    }

    // MARK: Private

    // These @State properties are used via $ binding - should NOT be flagged
    @State private var count: Int = 0
    @State private var isEnabled: Bool = true
    @State private var userName: String = ""

    // This @State is genuinely unused - SHOULD be flagged
    @State private var unusedState: Double = 0.0
}

// MARK: - ChildView

struct ChildView: View {
    // @Binding is always used by parent - should NOT be flagged
    @Binding var value: String
    @Binding var isActive: Bool

    var body: some View {
        VStack {
            Text(value)
            if isActive {
                Text("Active")
            }
        }
    }
}

// MARK: - ThemedView

struct ThemedView: View {
    // MARK: Internal

    var body: some View {
        VStack {
            Text("Theme: \(colorScheme == .dark ? "Dark" : "Light")")
            Button("Close") {
                dismiss()
            }
        }
    }

    // MARK: Private

    // @Environment values are injected - should NOT be flagged
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    // Unused environment - SHOULD be flagged
    @Environment(\.locale) private var unusedLocale
}

// MARK: - UserSettings

class UserSettings: ObservableObject {
    @Published var username: String = ""
    @Published var isLoggedIn: Bool = false

    // Unused published property - SHOULD be flagged
    @Published var unusedSetting: Int = 0
}

// MARK: - SettingsView

struct SettingsView: View {
    // @StateObject/@ObservedObject - should NOT be flagged
    @StateObject private var settings = UserSettings()
    @ObservedObject var externalSettings: UserSettings

    var body: some View {
        VStack {
            Text("User: \(settings.username)")
            Text("Logged in: \(settings.isLoggedIn)")
            Text("External: \(externalSettings.username)")
        }
    }
}

// MARK: - PreferencesView

struct PreferencesView: View {
    // MARK: Internal

    var body: some View {
        VStack {
            Toggle("Dark Mode", isOn: $darkMode)
            Slider(value: $fontSize, in: 10...24)
        }
    }

    // MARK: Private

    // @AppStorage persists to UserDefaults - should NOT be flagged
    @AppStorage("darkMode") private var darkMode: Bool = false
    @AppStorage("fontSize") private var fontSize: Double = 14.0

    // Unused app storage - SHOULD be flagged
    @AppStorage("unusedPref") private var unusedPref: String = ""
}

// MARK: - LoginForm

struct LoginForm: View {
    // MARK: Internal

    enum Field {
        case email
        case password
    }

    var body: some View {
        VStack {
            TextField("Email", text: $email)
                .focused($focusedField, equals: .email)
            SecureField("Password", text: $password)
                .focused($focusedField, equals: .password)
            Button("Submit") {
                focusedField = nil
            }
        }
    }

    // MARK: Private

    @State private var email: String = ""
    @State private var password: String = ""

    // @FocusState for keyboard focus - should NOT be flagged
    @FocusState private var focusedField: Field?

    // Unused focus state - SHOULD be flagged
    @FocusState private var unusedFocus: Bool
}

// MARK: - DraggableView

struct DraggableView: View {
    // MARK: Internal

    var body: some View {
        Circle()
            .offset(dragOffset)
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    },
            )
    }

    // MARK: Private

    // @GestureState for gesture tracking - should NOT be flagged
    @GestureState private var dragOffset: CGSize = .zero

    // Unused gesture state - SHOULD be flagged
    @GestureState private var unusedGesture: Bool = false
}

// MARK: - AnimatedTransition

struct AnimatedTransition: View {
    // MARK: Internal

    var body: some View {
        VStack {
            if isExpanded {
                Circle()
                    .matchedGeometryEffect(id: "shape", in: animation)
            } else {
                Rectangle()
                    .matchedGeometryEffect(id: "shape", in: animation)
            }
        }
        .onTapGesture {
            withAnimation {
                isExpanded.toggle()
            }
        }
    }

    // MARK: Private

    // @Namespace for matched geometry - should NOT be flagged
    @Namespace private var animation

    @State private var isExpanded = false
}
