//  UserAPI.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - User API

public struct UserAPI {
    // MARK: Lifecycle

    public init(baseURL: String = "https://api.example.com", session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Public

    // MARK: - CRUD Operations (Duplicated Pattern - CLONE)

    /// Fetch all users
    public func fetchAll() async throws -> [User] {
        let url = URL(string: "\(baseURL)/users")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([User].self, from: data)
    }

    /// Fetch user by ID
    public func fetch(id: Int) async throws -> User {
        let url = URL(string: "\(baseURL)/users/\(id)")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(User.self, from: data)
    }

    /// Create user
    public func create(_ user: User) async throws -> User {
        var request = URLRequest(url: URL(string: "\(baseURL)/users")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(user)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(User.self, from: data)
    }

    /// Update user
    public func update(_ user: User) async throws -> User {
        var request = URLRequest(url: URL(string: "\(baseURL)/users/\(user.id)")!)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(user)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(User.self, from: data)
    }

    /// Delete user
    public func delete(id: Int) async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)/users/\(id)")!)
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
