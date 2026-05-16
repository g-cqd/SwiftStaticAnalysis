//  FileDiscovery.swift
//  swa
//  MIT License
//
//  Thin facade over the canonical `SwiftFileFinder` in
//  `SwiftStaticAnalysisCore`. Kept so existing CLI call sites keep
//  their familiar `findSwiftFiles(in:excludePaths:)` shape; the
//  underlying enumeration, symlink confinement, default deny list,
//  and glob fast paths now live in one place in Core.

import Foundation
import SwiftStaticAnalysisCore

// MARK: - File Discovery

func findSwiftFiles(in paths: [String], excludePaths: [String]? = nil) throws -> [String] {
    let finder = SwiftFileFinder(options: .strict)
    return try finder.find(in: paths, excludePaths: excludePaths ?? [])
}
