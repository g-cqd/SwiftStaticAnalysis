//  OrderAPI.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - Order API

public struct OrderAPI {
    // MARK: Lifecycle

    public init(baseURL: String = "https://api.example.com", session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Public

    // MARK: - CRUD Operations (Duplicated Pattern - CLONE)

    /// Fetch all orders
    public func fetchAll() async throws -> [Order] {
        let url = URL(string: "\(baseURL)/orders")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Order].self, from: data)
    }

    /// Fetch order by ID
    public func fetch(id: Int) async throws -> Order {
        let url = URL(string: "\(baseURL)/orders/\(id)")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Order.self, from: data)
    }

    /// Create order
    public func create(_ order: Order) async throws -> Order {
        var request = URLRequest(url: URL(string: "\(baseURL)/orders")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(order)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Order.self, from: data)
    }

    /// Update order
    public func update(_ order: Order) async throws -> Order {
        var request = URLRequest(url: URL(string: "\(baseURL)/orders/\(order.id)")!)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(order)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Order.self, from: data)
    }

    /// Delete order
    public func delete(id: Int) async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)/orders/\(id)")!)
        request.httpMethod = "DELETE"

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(httpResponse.statusCode)
        }
    }

    // MARK: Private

    private let baseURL: String
    private let session: URLSession
}
