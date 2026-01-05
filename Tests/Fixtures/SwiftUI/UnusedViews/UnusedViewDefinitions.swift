//  UnusedViewDefinitions.swift
//  SwiftStaticAnalysis
//  MIT License

import SwiftUI

// MARK: - OrphanedView

/// This view is defined but never instantiated anywhere - SHOULD be flagged
struct OrphanedView: View {
    var body: some View {
        Text("I am never used")
    }
}

// MARK: - UnusedComplexView

/// Another unused view with complex structure - SHOULD be flagged
struct UnusedComplexView: View {
    // MARK: Internal

    var body: some View {
        VStack {
            Text("Complex but unused")
            ForEach(0..<10) { i in
                Text("Item \(i)")
            }
        }
    }

    // MARK: Private

    @State private var value: Int = 0
}

// MARK: - UnusedConfigurableView

/// Unused view with custom initializer - SHOULD be flagged
struct UnusedConfigurableView: View {
    // MARK: Lifecycle

    init(title: String, subtitle: String = "Default") {
        self.title = title
        self.subtitle = subtitle
    }

    // MARK: Internal

    let title: String
    let subtitle: String

    var body: some View {
        VStack {
            Text(title)
            Text(subtitle)
        }
    }
}

// MARK: - UsedHeaderView

/// This view IS used by MainContentView - should NOT be flagged
struct UsedHeaderView: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
    }
}

// MARK: - UsedFooterView

/// This view IS used by MainContentView - should NOT be flagged
struct UsedFooterView: View {
    var body: some View {
        Text("Footer")
            .font(.caption)
    }
}

// MARK: - MainContentView

/// Main view that uses other views
struct MainContentView: View {
    var body: some View {
        VStack {
            UsedHeaderView(title: "Welcome")
            Spacer()
            UsedFooterView()
        }
    }
}

// MARK: - UnusedModifier

/// Custom modifier that is never applied - SHOULD be flagged
struct UnusedModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(Color.gray)
    }
}

// MARK: - UsedModifier

/// Custom modifier that IS used - should NOT be flagged
struct UsedModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .cornerRadius(cornerRadius)
    }
}

extension View {
    /// Extension method for unused modifier - SHOULD be flagged
    func unusedStyle() -> some View {
        modifier(UnusedModifier())
    }

    /// Extension method that IS used - should NOT be flagged
    func roundedStyle(radius: CGFloat = 8) -> some View {
        modifier(UsedModifier(cornerRadius: radius))
    }
}

// MARK: - StyledView

struct StyledView: View {
    var body: some View {
        Text("Styled")
            .roundedStyle()
    }
}

// MARK: - OrphanedPreview_Previews

/// Preview that is never shown (no matching view) - edge case
struct OrphanedPreview_Previews: PreviewProvider {
    static var previews: some View {
        Text("Orphaned Preview")
    }
}
