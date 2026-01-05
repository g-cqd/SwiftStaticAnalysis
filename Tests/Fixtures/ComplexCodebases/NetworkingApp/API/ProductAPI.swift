//  ProductAPI.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - Product API

public struct ProductAPI {
    // MARK: Lifecycle

    public init(baseURL: String = "https://api.example.com", session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Public

    // MARK: - CRUD Operations (Duplicated Pattern - CLONE)

    /// Fetch all products
    public func fetchAll() async throws -> [Product] {
        let url = URL(string: "\(baseURL)/products")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Product].self, from: data)
    }

    /// Fetch product by ID
    public func fetch(id: Int) async throws -> Product {
        let url = URL(string: "\(baseURL)/products/\(id)")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Product.self, from: data)
    }

    /// Create product
    public func create(_ product: Product) async throws -> Product {
        var request = URLRequest(url: URL(string: "\(baseURL)/products")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(product)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Product.self, from: data)
    }

    /// Update product
    public func update(_ product: Product) async throws -> Product {
        var request = URLRequest(url: URL(string: "\(baseURL)/products/\(product.id)")!)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(product)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Product.self, from: data)
    }

    /// Delete product
    public func delete(id: Int) async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)/products/\(id)")!)
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
