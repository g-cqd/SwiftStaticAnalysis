//
//  SimilarListViews.swift
//  SwiftStaticAnalysis - Test Fixtures
//
//  Views with nearly identical structure that should be detected as clones.
//

import SwiftUI

// MARK: - Type-1 Clones (Exact)
// These views have IDENTICAL structure and should be detected as exact clones

struct UserListView: View {
    @State private var items: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Loading...")
                } else if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                } else {
                    List(items, id: \.self) { item in
                        Text(item)
                    }
                }
            }
            .navigationTitle("Users")
        }
        .onAppear {
            loadData()
        }
    }

    private func loadData() {
        isLoading = true
        // Simulate API call
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            items = ["User 1", "User 2", "User 3"]
            isLoading = false
        }
    }
}

struct ProductListView: View {
    @State private var items: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Loading...")
                } else if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                } else {
                    List(items, id: \.self) { item in
                        Text(item)
                    }
                }
            }
            .navigationTitle("Products")
        }
        .onAppear {
            loadData()
        }
    }

    private func loadData() {
        isLoading = true
        // Simulate API call
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            items = ["Product 1", "Product 2", "Product 3"]
            isLoading = false
        }
    }
}

struct OrderListView: View {
    @State private var items: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Loading...")
                } else if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                } else {
                    List(items, id: \.self) { item in
                        Text(item)
                    }
                }
            }
            .navigationTitle("Orders")
        }
        .onAppear {
            loadData()
        }
    }

    private func loadData() {
        isLoading = true
        // Simulate API call
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            items = ["Order 1", "Order 2", "Order 3"]
            isLoading = false
        }
    }
}

// MARK: - Type-2 Clones (Near - Renamed Identifiers)
// These views have the same structure but different variable names

struct CustomerDetailView: View {
    @State private var customer: CustomerModel?
    @State private var loading: Bool = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            if loading {
                ProgressView()
            } else if let err = error {
                ErrorView(message: err)
            } else if let data = customer {
                CustomerInfoSection(customer: data)
            }
        }
        .task {
            await fetchCustomer()
        }
    }

    private func fetchCustomer() async {
        loading = true
        // API call
        loading = false
    }
}

struct VendorDetailView: View {
    @State private var vendor: VendorModel?
    @State private var isLoading: Bool = false
    @State private var errorMsg: String?

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView()
            } else if let err = errorMsg {
                ErrorView(message: err)
            } else if let data = vendor {
                VendorInfoSection(vendor: data)
            }
        }
        .task {
            await fetchVendor()
        }
    }

    private func fetchVendor() async {
        isLoading = true
        // API call
        isLoading = false
    }
}

struct EmployeeDetailView: View {
    @State private var employee: EmployeeModel?
    @State private var loadingState: Bool = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            if loadingState {
                ProgressView()
            } else if let err = errorText {
                ErrorView(message: err)
            } else if let data = employee {
                EmployeeInfoSection(employee: data)
            }
        }
        .task {
            await fetchEmployee()
        }
    }

    private func fetchEmployee() async {
        loadingState = true
        // API call
        loadingState = false
    }
}

// MARK: - Supporting Types (stubs for compilation)

struct CustomerModel {}
struct VendorModel {}
struct EmployeeModel {}

struct ErrorView: View {
    let message: String
    var body: some View { Text(message) }
}

struct CustomerInfoSection: View {
    let customer: CustomerModel
    var body: some View { Text("Customer") }
}

struct VendorInfoSection: View {
    let vendor: VendorModel
    var body: some View { Text("Vendor") }
}

struct EmployeeInfoSection: View {
    let employee: EmployeeModel
    var body: some View { Text("Employee") }
}
