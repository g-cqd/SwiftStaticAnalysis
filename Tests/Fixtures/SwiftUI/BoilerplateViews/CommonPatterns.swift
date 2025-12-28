//
//  CommonPatterns.swift
//  SwiftStaticAnalysis - Test Fixtures
//
//  Common SwiftUI boilerplate patterns that appear across many views.
//  These should be detected as semantic clones.
//

import SwiftUI

// MARK: - Loading State Pattern (appears in many views)

struct AsyncUserView: View {
    @State private var data: User?
    @State private var isLoading = true
    @State private var error: Error?

    var body: some View {
        // This loading/error/content pattern is VERY common
        Group {
            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
            } else if let error = error {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error.localizedDescription)
                    Button("Retry") { Task { await load() } }
                }
            } else if let data = data {
                UserContent(user: data)
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            data = try await fetchUser()
        } catch {
            self.error = error
        }
    }
}

struct AsyncProductView: View {
    @State private var data: Product?
    @State private var isLoading = true
    @State private var error: Error?

    var body: some View {
        // Same loading/error/content pattern
        Group {
            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
            } else if let error = error {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error.localizedDescription)
                    Button("Retry") { Task { await load() } }
                }
            } else if let data = data {
                ProductContent(product: data)
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            data = try await fetchProduct()
        } catch {
            self.error = error
        }
    }
}

// MARK: - Form Field Pattern

struct UserFormView: View {
    @Binding var user: UserFormData

    var body: some View {
        Form {
            Section("Personal Information") {
                TextField("First Name", text: $user.firstName)
                    .textContentType(.givenName)
                    .autocapitalization(.words)

                TextField("Last Name", text: $user.lastName)
                    .textContentType(.familyName)
                    .autocapitalization(.words)

                TextField("Email", text: $user.email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
            }

            Section("Address") {
                TextField("Street", text: $user.street)
                    .textContentType(.streetAddressLine1)

                TextField("City", text: $user.city)
                    .textContentType(.addressCity)

                TextField("ZIP", text: $user.zip)
                    .textContentType(.postalCode)
                    .keyboardType(.numberPad)
            }
        }
    }
}

struct CompanyFormView: View {
    @Binding var company: CompanyFormData

    var body: some View {
        Form {
            Section("Company Information") {
                TextField("Company Name", text: $company.name)
                    .textContentType(.organizationName)
                    .autocapitalization(.words)

                TextField("Industry", text: $company.industry)
                    .autocapitalization(.words)

                TextField("Email", text: $company.email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
            }

            Section("Address") {
                TextField("Street", text: $company.street)
                    .textContentType(.streetAddressLine1)

                TextField("City", text: $company.city)
                    .textContentType(.addressCity)

                TextField("ZIP", text: $company.zip)
                    .textContentType(.postalCode)
                    .keyboardType(.numberPad)
            }
        }
    }
}

// MARK: - Card View Pattern

struct UserCardView: View {
    let user: User

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AsyncImage(url: user.avatarURL) { image in
                    image.resizable()
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 50, height: 50)
                .clipShape(Circle())

                VStack(alignment: .leading) {
                    Text(user.name)
                        .font(.headline)
                    Text(user.email)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

struct ProductCardView: View {
    let product: Product

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AsyncImage(url: product.imageURL) { image in
                    image.resizable()
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading) {
                    Text(product.name)
                        .font(.headline)
                    Text(product.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

// MARK: - Supporting Types

struct User {
    var name: String = ""
    var email: String = ""
    var avatarURL: URL?
}

struct Product {
    var name: String = ""
    var description: String = ""
    var imageURL: URL?
}

struct UserFormData {
    var firstName: String = ""
    var lastName: String = ""
    var email: String = ""
    var street: String = ""
    var city: String = ""
    var zip: String = ""
}

struct CompanyFormData {
    var name: String = ""
    var industry: String = ""
    var email: String = ""
    var street: String = ""
    var city: String = ""
    var zip: String = ""
}

struct UserContent: View {
    let user: User
    var body: some View { Text(user.name) }
}

struct ProductContent: View {
    let product: Product
    var body: some View { Text(product.name) }
}

func fetchUser() async throws -> User { User() }
func fetchProduct() async throws -> Product { Product() }
