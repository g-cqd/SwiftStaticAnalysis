//
//  Models.swift
//  NetworkingApp - Test Fixtures
//
//  Shared models for the networking app.
//

import Foundation

// MARK: - User

public struct User: Codable, Identifiable {
    // MARK: Lifecycle

    public init(id: Int, name: String, email: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.email = email
        self.createdAt = createdAt
    }

    // MARK: Public

    public let id: Int
    public let name: String
    public let email: String
    public let createdAt: Date
}

// MARK: - Product

public struct Product: Codable, Identifiable {
    // MARK: Lifecycle

    public init(id: Int, title: String, description: String, price: Double, categoryId: Int) {
        self.id = id
        self.title = title
        self.description = description
        self.price = price
        self.categoryId = categoryId
    }

    // MARK: Public

    public let id: Int
    public let title: String
    public let description: String
    public let price: Double
    public let categoryId: Int
}

// MARK: - Order

public struct Order: Codable, Identifiable {
    // MARK: Lifecycle

    public init(id: Int, userId: Int, productIds: [Int], total: Double, status: OrderStatus, createdAt: Date = Date()) {
        self.id = id
        self.userId = userId
        self.productIds = productIds
        self.total = total
        self.status = status
        self.createdAt = createdAt
    }

    // MARK: Public

    public let id: Int
    public let userId: Int
    public let productIds: [Int]
    public let total: Double
    public let status: OrderStatus
    public let createdAt: Date
}

// MARK: - OrderStatus

public enum OrderStatus: String, Codable {
    case pending
    case processing
    case shipped
    case delivered
    case cancelled
}

// MARK: - APIResponse

public struct APIResponse<T: Codable>: Codable {
    // MARK: Lifecycle

    public init(data: T, success: Bool = true, message: String? = nil) {
        self.data = data
        self.success = success
        self.message = message
    }

    // MARK: Public

    public let data: T
    public let success: Bool
    public let message: String?
}

// MARK: - PaginatedResponse

public struct PaginatedResponse<T: Codable>: Codable {
    // MARK: Lifecycle

    public init(data: [T], page: Int, totalPages: Int, totalItems: Int) {
        self.data = data
        self.page = page
        self.totalPages = totalPages
        self.totalItems = totalItems
    }

    // MARK: Public

    public let data: [T]
    public let page: Int
    public let totalPages: Int
    public let totalItems: Int
}

// MARK: - NetworkError

public enum NetworkError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case decodingFailed
    case serverError(Int)
    case noData
    case unauthorized
    case notFound
}
