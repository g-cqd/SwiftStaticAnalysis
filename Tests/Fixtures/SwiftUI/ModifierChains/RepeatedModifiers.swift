//
//  RepeatedModifiers.swift
//  SwiftStaticAnalysis - Test Fixtures
//
//  Repeated modifier chains that should be detected as duplicates.
//

import SwiftUI

// MARK: - ActionButtonsView

struct ActionButtonsView: View {
    var body: some View {
        VStack(spacing: 16) {
            // These button modifier chains are duplicated
            Button("Save") {}
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.blue)
                .cornerRadius(8)
                .shadow(color: .blue.opacity(0.3), radius: 4, x: 0, y: 2)

            Button("Submit") {}
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.blue)
                .cornerRadius(8)
                .shadow(color: .blue.opacity(0.3), radius: 4, x: 0, y: 2)

            Button("Confirm") {}
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.blue)
                .cornerRadius(8)
                .shadow(color: .blue.opacity(0.3), radius: 4, x: 0, y: 2)

            Button("Cancel") {}
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.red)
                .cornerRadius(8)
                .shadow(color: .red.opacity(0.3), radius: 4, x: 0, y: 2)
        }
    }
}

// MARK: - CardGridView

struct CardGridView: View {
    var body: some View {
        VStack(spacing: 16) {
            // These card modifier chains are duplicated
            VStack {
                Text("Card 1")
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)

            VStack {
                Text("Card 2")
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)

            VStack {
                Text("Card 3")
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
        }
    }
}

// MARK: - StyledTextView

struct StyledTextView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // These text modifier chains are duplicated
            Text("Heading 1")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Text("Heading 2")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Text("Subtitle 1")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineSpacing(4)
                .multilineTextAlignment(.leading)

            Text("Subtitle 2")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
        }
    }
}

// MARK: - ImageGalleryView

struct ImageGalleryView: View {
    let imageURLs: [URL] = []

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                // These image modifier chains are duplicated
                AsyncImage(url: imageURLs.first) { image in
                    image.resizable()
                } placeholder: {
                    ProgressView()
                }
                .aspectRatio(contentMode: .fill)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1),
                )

                AsyncImage(url: imageURLs.dropFirst().first) { image in
                    image.resizable()
                } placeholder: {
                    ProgressView()
                }
                .aspectRatio(contentMode: .fill)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1),
                )

                AsyncImage(url: imageURLs.dropFirst(2).first) { image in
                    image.resizable()
                } placeholder: {
                    ProgressView()
                }
                .aspectRatio(contentMode: .fill)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1),
                )
            }
        }
    }
}

// MARK: - FormFieldsView

struct FormFieldsView: View {
    // MARK: Internal

    var body: some View {
        VStack(spacing: 16) {
            // These text field modifier chains are duplicated
            TextField("Field 1", text: $field1)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1),
                )

            TextField("Field 2", text: $field2)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1),
                )

            TextField("Field 3", text: $field3)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1),
                )
        }
    }

    // MARK: Private

    @State private var field1 = ""
    @State private var field2 = ""
    @State private var field3 = ""
}
