//
//  ViewModelDuplication.swift
//  SwiftStaticAnalysis - Test Fixtures
//
//  This file contains intentional near-clone duplication (Type-2).
//  ViewModels have identical structure but different variable names.
//

import Foundation

// MARK: - API

struct API {
    static let shared = API()

    func fetchUsers() async throws -> [String] {
        ["User1", "User2"]
    }

    func fetchProducts() async throws -> [String] {
        ["Product1", "Product2"]
    }

    func fetchOrders() async throws -> [String] {
        ["Order1", "Order2"]
    }

    func fetchCategories() async throws -> [String] {
        ["Category1", "Category2"]
    }
}

// MARK: - UserViewModel

/// UserViewModel - NEAR CLONE 1
class UserViewModel {
    // MARK: Internal

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

    // MARK: Private

    private var userData: [String] = []
    private var userIsLoading = false
    private var userError: Error?
}

// MARK: - ProductViewModel

/// ProductViewModel - NEAR CLONE 2
class ProductViewModel {
    // MARK: Internal

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

    // MARK: Private

    private var productData: [String] = []
    private var productIsLoading = false
    private var productError: Error?
}

// MARK: - OrderViewModel

/// OrderViewModel - NEAR CLONE 3
class OrderViewModel {
    // MARK: Internal

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

    // MARK: Private

    private var orderData: [String] = []
    private var orderIsLoading = false
    private var orderError: Error?
}

// MARK: - CategoryViewModel

/// CategoryViewModel - NEAR CLONE 4
class CategoryViewModel {
    // MARK: Internal

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

    // MARK: Private

    private var categoryData: [String] = []
    private var categoryIsLoading = false
    private var categoryError: Error?
}

// MARK: - SettingsViewModel

/// This ViewModel has different structure and should not be detected
class SettingsViewModel {
    // MARK: Internal

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

    // MARK: Private

    private var settings: [String: Any] = [:]
    private var isDirty = false
}
