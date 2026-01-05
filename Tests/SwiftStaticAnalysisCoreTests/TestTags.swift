//  TestTags.swift
//  SwiftStaticAnalysis
//  MIT License

import Testing

// MARK: - Test Tags

extension Tag {
    /// Tests that verify algorithm correctness.
    @Tag static var algorithm: Self

    /// Tests that verify boundary conditions and edge cases.
    @Tag static var boundary: Self

    /// Tests that involve concurrency or parallel execution.
    @Tag static var concurrency: Self

    /// Tests that cover error handling paths.
    @Tag static var error: Self

    /// Integration tests that span multiple components.
    @Tag static var integration: Self

    /// Tests that verify memory safety and cleanup.
    @Tag static var memory: Self

    /// Performance benchmarks and tests.
    @Tag static var performance: Self

    /// Tests that may take longer to run (>1s).
    @Tag static var slow: Self

    /// Unit tests for isolated components.
    @Tag static var unit: Self
}

// MARK: - Feature-Specific Tags

extension Tag {
    /// Tests for clone/duplication detection features.
    @Tag static var cloneDetection: Self

    /// Tests for reachability analysis features.
    @Tag static var reachability: Self

    /// Tests for symbol lookup features.
    @Tag static var symbolLookup: Self

    /// Tests for unused code detection features.
    @Tag static var unusedCode: Self

    /// Tests for configuration handling.
    @Tag static var configuration: Self

    /// Tests for parsing and syntax analysis.
    @Tag static var parsing: Self
}
