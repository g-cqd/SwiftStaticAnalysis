//  AnalysisError+LocalizedError.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - AnalysisError + LocalizedError

extension AnalysisError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            "File not found: \(path)"

        case .parseError(let file, let message):
            "Parse error in \(file): \(message)"

        case .invalidPath(let path):
            "Invalid path: \(path)"

        case .ioError(let message):
            "I/O error: \(message)"
        }
    }
}
