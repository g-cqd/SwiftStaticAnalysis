//
//  NetworkingDuplication.swift
//  SwiftStaticAnalysis - Test Fixtures
//
//  This file contains intentional code duplication for testing exact clone detection.
//  The two fetch functions are nearly identical, differing only in URL and type.
//

import Foundation

// MARK: - User

struct User: Codable {
    let id: Int
    let name: String
    let email: String
}

// MARK: - Product

struct Product: Codable {
    let id: Int
    let title: String
    let price: Double
}

// MARK: - Order

struct Order: Codable {
    let id: Int
    let userId: Int
    let products: [Int]
    let total: Double
}

// MARK: - NetworkError

enum NetworkError: Error {
    case invalidResponse
    case invalidURL
    case decodingFailed
    case serverError(Int)
}

// MARK: - Duplicated Fetch Functions (Type-1 Clones)

/// Fetches users from the API - CLONE 1
func fetchUsers() async throws -> [User] {
    let url = URL(string: "https://api.example.com/users")!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let httpResponse = response as? HTTPURLResponse,
          (200 ... 299).contains(httpResponse.statusCode)
    else {
        throw NetworkError.invalidResponse
    }
    return try JSONDecoder().decode([User].self, from: data)
}

/// Fetches products from the API - CLONE 2
func fetchProducts() async throws -> [Product] {
    let url = URL(string: "https://api.example.com/products")!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let httpResponse = response as? HTTPURLResponse,
          (200 ... 299).contains(httpResponse.statusCode)
    else {
        throw NetworkError.invalidResponse
    }
    return try JSONDecoder().decode([Product].self, from: data)
}

/// Fetches orders from the API - CLONE 3
func fetchOrders() async throws -> [Order] {
    let url = URL(string: "https://api.example.com/orders")!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let httpResponse = response as? HTTPURLResponse,
          (200 ... 299).contains(httpResponse.statusCode)
    else {
        throw NetworkError.invalidResponse
    }
    return try JSONDecoder().decode([Order].self, from: data)
}

// MARK: - Duplicated Validation Functions (Type-1 Clones)

/// Validates user data - CLONE A
func validateUser(_ user: User) -> Bool {
    guard !user.name.isEmpty else {
        return false
    }
    guard user.email.contains("@") else {
        return false
    }
    guard user.id > 0 else {
        return false
    }
    return true
}

/// Validates product data - CLONE B
func validateProduct(_ product: Product) -> Bool {
    guard !product.title.isEmpty else {
        return false
    }
    guard product.price > 0 else {
        return false
    }
    guard product.id > 0 else {
        return false
    }
    return true
}

// MARK: - Unique Code (No Clones)

/// This function is unique and should not be detected as a clone
func processData<T: Codable>(_ data: Data, as type: T.Type) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
}
