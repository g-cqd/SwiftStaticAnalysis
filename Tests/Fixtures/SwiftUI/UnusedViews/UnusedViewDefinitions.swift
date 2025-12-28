//
//  UnusedViewDefinitions.swift
//  SwiftStaticAnalysis - Test Fixtures
//
//  Views that are defined but never used anywhere.
//  These SHOULD be flagged as unused.
//

import SwiftUI

// MARK: - Completely Unused Views

/// This view is defined but never instantiated anywhere - SHOULD be flagged
struct OrphanedView: View {
    var body: some View {
        Text("I am never used")
    }
}

/// Another unused view with complex structure - SHOULD be flagged
struct UnusedComplexView: View {
    @State private var value: Int = 0

    var body: some View {
        VStack {
            Text("Complex but unused")
            ForEach(0..<10) { i in
                Text("Item \(i)")
            }
        }
    }
}

/// Unused view with custom initializer - SHOULD be flagged
struct UnusedConfigurableView: View {
    let title: String
    let subtitle: String

    init(title: String, subtitle: String = "Default") {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack {
            Text(title)
            Text(subtitle)
        }
    }
}

// MARK: - Used Views (for comparison)

/// This view IS used by MainContentView - should NOT be flagged
struct UsedHeaderView: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
    }
}

/// This view IS used by MainContentView - should NOT be flagged
struct UsedFooterView: View {
    var body: some View {
        Text("Footer")
            .font(.caption)
    }
}

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

// MARK: - Unused View Modifiers

/// Custom modifier that is never applied - SHOULD be flagged
struct UnusedModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(Color.gray)
    }
}

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

struct StyledView: View {
    var body: some View {
        Text("Styled")
            .roundedStyle()
    }
}

// MARK: - Unused Preview Providers

/// Preview that is never shown (no matching view) - edge case
struct OrphanedPreview_Previews: PreviewProvider {
    static var previews: some View {
        Text("Orphaned Preview")
    }
}
