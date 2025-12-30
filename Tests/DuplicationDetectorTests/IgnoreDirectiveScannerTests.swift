//
//  IgnoreDirectiveScannerTests.swift
//  SwiftStaticAnalysis
//
//  Tests for IgnoreDirectiveScanner - scanning for swa:ignore-duplicates directives.
//

import Foundation
import Testing

@testable import DuplicationDetector

// MARK: - IgnoreDirectiveScannerTests

@Suite("Ignore Directive Scanner Tests")
struct IgnoreDirectiveScannerTests {
    // MARK: - Basic Directive Detection

    @Test("Detect single-line ignore directive")
    func detectSingleLineDirective() {
        let source = """
        // swa:ignore-duplicates
        func generatedCode() {
            let x = 1
        }
        """

        let scanner = IgnoreDirectiveScanner()
        let regions = scanner.scan(source: source, file: "test.swift")

        #expect(regions.count == 1)
        if let region = regions.first {
            #expect(region.file == "test.swift")
            #expect(region.startLine == 1)
            #expect(region.endLine == 4)
        }
    }

    @Test("Detect generic swa:ignore directive")
    func detectGenericIgnoreDirective() {
        let source = """
        // swa:ignore
        func ignoredFunction() {
            doSomething()
        }
        """

        let scanner = IgnoreDirectiveScanner()
        let regions = scanner.scan(source: source, file: "test.swift")

        #expect(regions.count == 1)
        if let region = regions.first {
            #expect(region.startLine == 1)
            #expect(region.endLine == 4)
        }
    }

    @Test("Detect range ignore directives")
    func detectRangeDirectives() {
        let source = """
        // swa:ignore-duplicates:begin
        struct Generated1 {
            var id: String
        }

        struct Generated2 {
            var id: String
        }
        // swa:ignore-duplicates:end
        """

        let scanner = IgnoreDirectiveScanner()
        let regions = scanner.scan(source: source, file: "test.swift")

        #expect(regions.count == 1)
        if let region = regions.first {
            #expect(region.startLine == 1)
            #expect(region.endLine == 9)
        }
    }

    @Test("Detect generic range ignore directives")
    func detectGenericRangeDirectives() {
        let source = """
        // swa:ignore:begin
        func a() {}
        func b() {}
        // swa:ignore:end
        """

        let scanner = IgnoreDirectiveScanner()
        let regions = scanner.scan(source: source, file: "test.swift")

        #expect(regions.count == 1)
        if let region = regions.first {
            #expect(region.startLine == 1)
            #expect(region.endLine == 4)
        }
    }

    // MARK: - Multiple Regions

    @Test("Detect multiple separate ignore regions")
    func detectMultipleRegions() {
        let source = """
        // swa:ignore-duplicates
        func a() { }

        func normal() { }

        // swa:ignore-duplicates
        func b() { }
        """

        let scanner = IgnoreDirectiveScanner()
        let regions = scanner.scan(source: source, file: "test.swift")

        #expect(regions.count == 2)
    }

    @Test("Detect mixed single and range directives")
    func detectMixedDirectives() {
        let source = """
        // swa:ignore-duplicates
        func single() { }

        // swa:ignore-duplicates:begin
        func rangeA() { }
        func rangeB() { }
        // swa:ignore-duplicates:end

        func normal() { }
        """

        let scanner = IgnoreDirectiveScanner()
        let regions = scanner.scan(source: source, file: "test.swift")

        #expect(regions.count == 2)
    }

    // MARK: - Block Comments

    @Test("Detect block comment directive")
    func detectBlockCommentDirective() {
        let source = """
        /* swa:ignore-duplicates */
        func ignored() { }
        """

        let scanner = IgnoreDirectiveScanner()
        let regions = scanner.scan(source: source, file: "test.swift")

        #expect(regions.count == 1)
    }

    // MARK: - Edge Cases

    @Test("Empty source returns no regions")
    func emptySourceNoRegions() {
        let scanner = IgnoreDirectiveScanner()
        let regions = scanner.scan(source: "", file: "test.swift")

        #expect(regions.isEmpty)
    }

    @Test("Source without directives returns no regions")
    func noDirectivesNoRegions() {
        let source = """
        func normalFunction() {
            let x = 1
            print(x)
        }
        """

        let scanner = IgnoreDirectiveScanner()
        let regions = scanner.scan(source: source, file: "test.swift")

        #expect(regions.isEmpty)
    }

    @Test("Unclosed range extends to end of file")
    func unclosedRangeExtendsToEnd() {
        let source = """
        // swa:ignore-duplicates:begin
        func a() { }
        func b() { }
        """

        let scanner = IgnoreDirectiveScanner()
        let regions = scanner.scan(source: source, file: "test.swift")

        #expect(regions.count == 1)
        if let region = regions.first {
            #expect(region.startLine == 1)
            #expect(region.endLine == 3)
        }
    }

    @Test("Single-line declaration without braces")
    func singleLineDeclaration() {
        let source = """
        // swa:ignore-duplicates
        var property: Int

        func normal() { }
        """

        let scanner = IgnoreDirectiveScanner()
        let regions = scanner.scan(source: source, file: "test.swift")

        #expect(regions.count == 1)
        if let region = regions.first {
            #expect(region.startLine == 1)
            // Should cover the property declaration (may extend to next declaration)
            #expect(region.endLine >= 2)
            #expect(region.endLine <= 4)
        }
    }
}

// MARK: - IgnoreRegionTests

@Suite("Ignore Region Tests")
struct IgnoreRegionTests {
    @Test("Region overlaps with contained range")
    func regionOverlapsContained() {
        let region = IgnoreRegion(file: "test.swift", startLine: 5, endLine: 10)

        #expect(region.overlaps(startLine: 6, endLine: 8) == true)
    }

    @Test("Region overlaps with containing range")
    func regionOverlapsContaining() {
        let region = IgnoreRegion(file: "test.swift", startLine: 5, endLine: 10)

        #expect(region.overlaps(startLine: 3, endLine: 12) == true)
    }

    @Test("Region overlaps at start boundary")
    func regionOverlapsStartBoundary() {
        let region = IgnoreRegion(file: "test.swift", startLine: 5, endLine: 10)

        #expect(region.overlaps(startLine: 3, endLine: 7) == true)
    }

    @Test("Region overlaps at end boundary")
    func regionOverlapsEndBoundary() {
        let region = IgnoreRegion(file: "test.swift", startLine: 5, endLine: 10)

        #expect(region.overlaps(startLine: 8, endLine: 15) == true)
    }

    @Test("Region does not overlap with range before")
    func regionNoOverlapBefore() {
        let region = IgnoreRegion(file: "test.swift", startLine: 5, endLine: 10)

        #expect(region.overlaps(startLine: 1, endLine: 4) == false)
    }

    @Test("Region does not overlap with range after")
    func regionNoOverlapAfter() {
        let region = IgnoreRegion(file: "test.swift", startLine: 5, endLine: 10)

        #expect(region.overlaps(startLine: 11, endLine: 15) == false)
    }

    @Test("Region overlaps at exact boundaries")
    func regionOverlapsExactBoundaries() {
        let region = IgnoreRegion(file: "test.swift", startLine: 5, endLine: 10)

        #expect(region.overlaps(startLine: 5, endLine: 10) == true)
        #expect(region.overlaps(startLine: 10, endLine: 15) == true)
        #expect(region.overlaps(startLine: 1, endLine: 5) == true)
    }
}

// MARK: - CloneGroupFilteringTests

@Suite("Clone Group Filtering Tests")
struct CloneGroupFilteringTests {
    @Test("Filter out clones in ignored regions")
    func filterIgnoredClones() {
        let clone1 = Clone(
            file: "test.swift",
            startLine: 5,
            endLine: 10,
            tokenCount: 20,
            codeSnippet: "func a() { }",
        )

        let clone2 = Clone(
            file: "test.swift",
            startLine: 15,
            endLine: 20,
            tokenCount: 20,
            codeSnippet: "func b() { }",
        )

        let clone3 = Clone(
            file: "other.swift",
            startLine: 5,
            endLine: 10,
            tokenCount: 20,
            codeSnippet: "func c() { }",
        )

        let group = CloneGroup(
            type: .exact,
            clones: [clone1, clone2, clone3],
            similarity: 1.0,
            fingerprint: "abc123",
        )

        let ignoreRegions: [String: [IgnoreRegion]] = [
            "test.swift": [IgnoreRegion(file: "test.swift", startLine: 3, endLine: 12)],
        ]

        let filtered = [group].filteringIgnored(ignoreRegions)

        #expect(filtered.count == 1)
        if let filteredGroup = filtered.first {
            #expect(filteredGroup.clones.count == 2)
            // clone1 should be filtered out (lines 5-10 overlaps 3-12)
            // clone2 and clone3 should remain
            let remainingFiles = filteredGroup.clones.map(\.file)
            #expect(remainingFiles.contains("other.swift"))
        }
    }

    @Test("Remove group if fewer than 2 clones remain")
    func removeGroupWithInsufficientClones() {
        let clone1 = Clone(
            file: "test.swift",
            startLine: 5,
            endLine: 10,
            tokenCount: 20,
            codeSnippet: "func a() { }",
        )

        let clone2 = Clone(
            file: "test.swift",
            startLine: 15,
            endLine: 20,
            tokenCount: 20,
            codeSnippet: "func b() { }",
        )

        let group = CloneGroup(
            type: .exact,
            clones: [clone1, clone2],
            similarity: 1.0,
            fingerprint: "abc123",
        )

        // Both clones are in ignored regions
        let ignoreRegions: [String: [IgnoreRegion]] = [
            "test.swift": [
                IgnoreRegion(file: "test.swift", startLine: 3, endLine: 12),
                IgnoreRegion(file: "test.swift", startLine: 14, endLine: 22),
            ],
        ]

        let filtered = [group].filteringIgnored(ignoreRegions)

        #expect(filtered.isEmpty)
    }

    @Test("Keep group if no clones are in ignored regions")
    func keepGroupWithNoIgnoredClones() {
        let clone1 = Clone(
            file: "test.swift",
            startLine: 5,
            endLine: 10,
            tokenCount: 20,
            codeSnippet: "func a() { }",
        )

        let clone2 = Clone(
            file: "other.swift",
            startLine: 5,
            endLine: 10,
            tokenCount: 20,
            codeSnippet: "func b() { }",
        )

        let group = CloneGroup(
            type: .exact,
            clones: [clone1, clone2],
            similarity: 1.0,
            fingerprint: "abc123",
        )

        let ignoreRegions: [String: [IgnoreRegion]] = [:]

        let filtered = [group].filteringIgnored(ignoreRegions)

        #expect(filtered.count == 1)
        #expect(filtered.first?.clones.count == 2)
    }
}
