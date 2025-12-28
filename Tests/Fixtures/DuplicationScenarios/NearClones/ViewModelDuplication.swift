//
//  ViewModelDuplication.swift
//  SwiftStaticAnalysis - Test Fixtures
//
//  This file contains intentional near-clone duplication (Type-2).
//  ViewModels have identical structure but different variable names.
//

import Foundation

// MARK: - Mock API

struct API {
    static let shared = API()

    func fetchUsers() async throws -> [String] {
        return ["User1", "User2"]
    }

    func fetchProducts() async throws -> [String] {
        return ["Product1", "Product2"]
    }

    func fetchOrders() async throws -> [String] {
        return ["Order1", "Order2"]
    }

    func fetchCategories() async throws -> [String] {
        return ["Category1", "Category2"]
    }
}

// MARK: - Near-Clone ViewModels (Type-2 Clones - Renamed Variables)

/// UserViewModel - NEAR CLONE 1
class UserViewModel {
    private var userData: [String] = []
    private var userIsLoading = false
    private var userError: Error?

    var items: [String] { userData }
    var isLoading: Bool { userIsLoading }
    var error: Error? { userError }

    func loadUsers() async {
        userIsLoading = true
        userError = nil
        do {
            userData = try await API.shared.fetchUsers()
        } catch {
            userError = error
            print("User fetch failed: \(error)")
        }
        userIsLoading = false
    }

    func clearUsers() {
        userData = []
        userError = nil
    }
}

/// ProductViewModel - NEAR CLONE 2
class ProductViewModel {
    private var productData: [String] = []
    private var productIsLoading = false
    private var productError: Error?

    var items: [String] { productData }
    var isLoading: Bool { productIsLoading }
    var error: Error? { productError }

    func loadProducts() async {
        productIsLoading = true
        productError = nil
        do {
            productData = try await API.shared.fetchProducts()
        } catch {
            productError = error
            print("Product fetch failed: \(error)")
        }
        productIsLoading = false
    }

    func clearProducts() {
        productData = []
        productError = nil
    }
}

/// OrderViewModel - NEAR CLONE 3
class OrderViewModel {
    private var orderData: [String] = []
    private var orderIsLoading = false
    private var orderError: Error?

    var items: [String] { orderData }
    var isLoading: Bool { orderIsLoading }
    var error: Error? { orderError }

    func loadOrders() async {
        orderIsLoading = true
        orderError = nil
        do {
            orderData = try await API.shared.fetchOrders()
        } catch {
            orderError = error
            print("Order fetch failed: \(error)")
        }
        orderIsLoading = false
    }

    func clearOrders() {
        orderData = []
        orderError = nil
    }
}

/// CategoryViewModel - NEAR CLONE 4
class CategoryViewModel {
    private var categoryData: [String] = []
    private var categoryIsLoading = false
    private var categoryError: Error?

    var items: [String] { categoryData }
    var isLoading: Bool { categoryIsLoading }
    var error: Error? { categoryError }

    func loadCategories() async {
        categoryIsLoading = true
        categoryError = nil
        do {
            categoryData = try await API.shared.fetchCategories()
        } catch {
            categoryError = error
            print("Category fetch failed: \(error)")
        }
        categoryIsLoading = false
    }

    func clearCategories() {
        categoryData = []
        categoryError = nil
    }
}

// MARK: - Unique Code (No Clones)

/// This ViewModel has different structure and should not be detected
class SettingsViewModel {
    private var settings: [String: Any] = [:]
    private var isDirty = false

    func loadSettings() {
        settings = UserDefaults.standard.dictionaryRepresentation()
        isDirty = false
    }

    func saveSettings() {
        for (key, value) in settings {
            UserDefaults.standard.set(value, forKey: key)
        }
        isDirty = false
    }

    func updateSetting(_ key: String, value: Any) {
        settings[key] = value
        isDirty = true
    }
}
