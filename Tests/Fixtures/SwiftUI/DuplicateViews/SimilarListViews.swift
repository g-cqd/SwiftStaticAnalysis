//  SimilarListViews.swift
//  SwiftStaticAnalysis
//  MIT License

import SwiftUI

// MARK: - UserListView

// These views have IDENTICAL structure and should be detected as exact clones

struct UserListView: View {
    // MARK: Internal

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

    // MARK: Private

    @State private var items: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    private func loadData() {
        isLoading = true
        // Simulate API call
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            items = ["User 1", "User 2", "User 3"]
            isLoading = false
        }
    }
}

// MARK: - ProductListView

struct ProductListView: View {
    // MARK: Internal

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

    // MARK: Private

    @State private var items: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    private func loadData() {
        isLoading = true
        // Simulate API call
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            items = ["Product 1", "Product 2", "Product 3"]
            isLoading = false
        }
    }
}

// MARK: - OrderListView

struct OrderListView: View {
    // MARK: Internal

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

    // MARK: Private

    @State private var items: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    private func loadData() {
        isLoading = true
        // Simulate API call
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            items = ["Order 1", "Order 2", "Order 3"]
            isLoading = false
        }
    }
}

// MARK: - CustomerDetailView

// These views have the same structure but different variable names

struct CustomerDetailView: View {
    // MARK: Internal

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

    // MARK: Private

    @State private var customer: CustomerModel?
    @State private var loading: Bool = false
    @State private var error: String?

    private func fetchCustomer() async {
        loading = true
        // API call
        loading = false
    }
}

// MARK: - VendorDetailView

struct VendorDetailView: View {
    // MARK: Internal

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

    // MARK: Private

    @State private var vendor: VendorModel?
    @State private var isLoading: Bool = false
    @State private var errorMsg: String?

    private func fetchVendor() async {
        isLoading = true
        // API call
        isLoading = false
    }
}

// MARK: - EmployeeDetailView

struct EmployeeDetailView: View {
    // MARK: Internal

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

    // MARK: Private

    @State private var employee: EmployeeModel?
    @State private var loadingState: Bool = false
    @State private var errorText: String?

    private func fetchEmployee() async {
        loadingState = true
        // API call
        loadingState = false
    }
}

// MARK: - CustomerModel

struct CustomerModel {}

// MARK: - VendorModel

struct VendorModel {}

// MARK: - EmployeeModel

struct EmployeeModel {}

// MARK: - ErrorView

struct ErrorView: View {
    let message: String

    var body: some View { Text(message) }
}

// MARK: - CustomerInfoSection

struct CustomerInfoSection: View {
    let customer: CustomerModel

    var body: some View { Text("Customer") }
}

// MARK: - VendorInfoSection

struct VendorInfoSection: View {
    let vendor: VendorModel

    var body: some View { Text("Vendor") }
}

// MARK: - EmployeeInfoSection

struct EmployeeInfoSection: View {
    let employee: EmployeeModel

    var body: some View { Text("Employee") }
}
