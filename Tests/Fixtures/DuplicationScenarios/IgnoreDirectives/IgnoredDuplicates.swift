//
//  IgnoredDuplicates.swift
//  SwiftStaticAnalysis
//
//  Test fixture for ignore directive handling in duplication detection.
//  Contains intentionally duplicated code that should be ignored.
//

import Foundation

// MARK: - Generated Code (Should Be Ignored)

// swa:ignore-duplicates
func generatedHandler1() {
    // This function is intentionally duplicated (generated code)
    let config = ["key1": "value1", "key2": "value2"]
    for (key, value) in config {
        print("Processing \(key): \(value)")
        validateEntry(key: key, value: value)
    }
    finalizeProcessing()
}

// swa:ignore-duplicates
func generatedHandler2() {
    // This function is intentionally duplicated (generated code)
    let config = ["key1": "value1", "key2": "value2"]
    for (key, value) in config {
        print("Processing \(key): \(value)")
        validateEntry(key: key, value: value)
    }
    finalizeProcessing()
}

// MARK: - GeneratedModel1

// swa:ignore-duplicates:begin
struct GeneratedModel1: Codable {
    var id: String
    var name: String
    var createdAt: Date
    var updatedAt: Date

    func toJSON() -> [String: Any] {
        [
            "id": id,
            "name": name,
            "createdAt": createdAt.timeIntervalSince1970,
            "updatedAt": updatedAt.timeIntervalSince1970,
        ]
    }
}

// MARK: - GeneratedModel2

struct GeneratedModel2: Codable {
    var id: String
    var name: String
    var createdAt: Date
    var updatedAt: Date

    func toJSON() -> [String: Any] {
        [
            "id": id,
            "name": name,
            "createdAt": createdAt.timeIntervalSince1970,
            "updatedAt": updatedAt.timeIntervalSince1970,
        ]
    }
}

// swa:ignore-duplicates:end

// MARK: - Real Duplicates (Should Be Detected)

func realDuplicate1() {
    // This is a real duplicate that should be detected
    let numbers = [1, 2, 3, 4, 5]
    var sum = 0
    for num in numbers {
        sum += num * 2
        print("Current sum: \(sum)")
    }
    print("Final result: \(sum)")
}

func realDuplicate2() {
    // This is a real duplicate that should be detected
    let numbers = [1, 2, 3, 4, 5]
    var sum = 0
    for num in numbers {
        sum += num * 2
        print("Current sum: \(sum)")
    }
    print("Final result: \(sum)")
}

// MARK: - Helpers

private func validateEntry(key: String, value: String) {
    // Validation logic
}

private func finalizeProcessing() {
    // Finalization logic
}
