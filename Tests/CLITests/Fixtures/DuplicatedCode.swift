//
//  DuplicatedCode.swift
//  CLI Test Fixture
//
//  A Swift file with intentional code duplication for testing clone detection.
//

import Foundation

// MARK: - Duplicated Functions

/// First instance of duplicated validation logic.
func validateUserInputFirst(input: String) -> Bool {
    guard !input.isEmpty else {
        return false
    }

    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

    guard trimmed.count >= 3 else {
        return false
    }

    guard trimmed.count <= 100 else {
        return false
    }

    let allowedCharacters = CharacterSet.alphanumerics.union(.whitespaces)
    guard trimmed.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
        return false
    }

    return true
}

/// Second instance of duplicated validation logic (exact clone).
func validateUserInputSecond(input: String) -> Bool {
    guard !input.isEmpty else {
        return false
    }

    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

    guard trimmed.count >= 3 else {
        return false
    }

    guard trimmed.count <= 100 else {
        return false
    }

    let allowedCharacters = CharacterSet.alphanumerics.union(.whitespaces)
    guard trimmed.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
        return false
    }

    return true
}

// MARK: - Duplicated Classes

/// First data processor with duplicated transformation logic.
final class DataProcessorAlpha {
    private var items: [String] = []

    func addItem(_ item: String) {
        items.append(item)
    }

    func processAll() -> [String] {
        var results: [String] = []

        for item in items {
            let processed = item.lowercased()
            let trimmed = processed.trimmingCharacters(in: .whitespaces)
            let formatted = "[\(trimmed)]"
            results.append(formatted)
        }

        return results.sorted()
    }

    func clearAll() {
        items.removeAll()
    }
}

/// Second data processor with duplicated transformation logic (exact clone).
final class DataProcessorBeta {
    private var items: [String] = []

    func addItem(_ item: String) {
        items.append(item)
    }

    func processAll() -> [String] {
        var results: [String] = []

        for item in items {
            let processed = item.lowercased()
            let trimmed = processed.trimmingCharacters(in: .whitespaces)
            let formatted = "[\(trimmed)]"
            results.append(formatted)
        }

        return results.sorted()
    }

    func clearAll() {
        items.removeAll()
    }
}

// MARK: - Duplicated Computed Properties

struct ConfigurationA {
    let baseURL: String
    let apiKey: String
    let timeout: TimeInterval

    var fullEndpoint: String {
        let sanitizedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let version = "v1"
        let path = "api"
        return "\(sanitizedBase)/\(version)/\(path)?key=\(apiKey)"
    }

    var isValid: Bool {
        !baseURL.isEmpty && !apiKey.isEmpty && timeout > 0
    }
}

struct ConfigurationB {
    let baseURL: String
    let apiKey: String
    let timeout: TimeInterval

    var fullEndpoint: String {
        let sanitizedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let version = "v1"
        let path = "api"
        return "\(sanitizedBase)/\(version)/\(path)?key=\(apiKey)"
    }

    var isValid: Bool {
        !baseURL.isEmpty && !apiKey.isEmpty && timeout > 0
    }
}

// MARK: - Duplicated Error Handling

enum NetworkErrorFirst: Error {
    case connectionFailed
    case timeout
    case invalidResponse
    case unauthorized

    var localizedDescription: String {
        switch self {
        case .connectionFailed:
            return "Unable to connect to the server. Please check your internet connection."
        case .timeout:
            return "The request timed out. Please try again later."
        case .invalidResponse:
            return "Received an invalid response from the server."
        case .unauthorized:
            return "You are not authorized to perform this action."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .connectionFailed, .timeout:
            return true
        case .invalidResponse, .unauthorized:
            return false
        }
    }
}

enum NetworkErrorSecond: Error {
    case connectionFailed
    case timeout
    case invalidResponse
    case unauthorized

    var localizedDescription: String {
        switch self {
        case .connectionFailed:
            return "Unable to connect to the server. Please check your internet connection."
        case .timeout:
            return "The request timed out. Please try again later."
        case .invalidResponse:
            return "Received an invalid response from the server."
        case .unauthorized:
            return "You are not authorized to perform this action."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .connectionFailed, .timeout:
            return true
        case .invalidResponse, .unauthorized:
            return false
        }
    }
}
