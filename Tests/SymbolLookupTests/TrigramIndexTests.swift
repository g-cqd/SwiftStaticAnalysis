//  TrigramIndexTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore
@testable import SymbolLookup

@Suite("Trigram Index Tests")
struct TrigramIndexTests {
    private func occurrence(_ name: String, line: Int = 1) -> IndexedOccurrence {
        IndexedOccurrence(
            symbol: IndexedSymbol(usr: "s:\(name.count)\(name)", name: name, kind: .function, isSystem: false),
            file: "test.swift",
            line: line,
            column: 1,
            roles: [.definition],
        )
    }

    @Test("Trigrams of `fetchData` are `fet, etc, tch, chD, hDa, Dat, ata`")
    func trigramExtraction() {
        let trigrams = TrigramIndex.trigrams(of: "fetchData")
        #expect(trigrams == ["fet", "etc", "tch", "chD", "hDa", "Dat", "ata"])
    }

    @Test("Names shorter than 3 chars yield no trigrams")
    func shortNamesYieldNoTrigrams() {
        #expect(TrigramIndex.trigrams(of: "x").isEmpty)
        #expect(TrigramIndex.trigrams(of: "ab").isEmpty)
        #expect(TrigramIndex.trigrams(of: "abc") == ["abc"])
    }

    @Test("Candidate intersection narrows to the symbols containing every trigram")
    func candidateIntersection() {
        let index = TrigramIndex(definitions: [
            occurrence("fetchData"),  // contains "fet", "etc", ...
            occurrence("fetchUsers"),  // contains "fet", "etc", ...
            occurrence("loadData"),  // contains "Dat", "ata", but not "fet"
            occurrence("validate"),  // contains none of the above
        ])

        let candidates = index.candidates(requiredTrigrams: ["fet", "Dat"])
        // Only `fetchData` contains both "fet" and "Dat"
        #expect(candidates == Set([0]))
    }

    @Test("Required trigram missing from the index yields the empty set, not nil")
    func missingTrigramYieldsEmpty() {
        let index = TrigramIndex(definitions: [occurrence("fetchData")])
        let candidates = index.candidates(requiredTrigrams: ["zzz"])
        #expect(candidates == [])
        #expect(candidates != nil)
    }

    @Test("Empty trigram set yields nil (caller falls back to linear scan)")
    func emptyTrigramsYieldsNil() {
        let index = TrigramIndex(definitions: [occurrence("fetchData")])
        #expect(index.candidates(requiredTrigrams: []) == nil)
    }
}

@Suite("Regex Literal Extractor Tests")
struct RegexLiteralExtractorTests {
    @Test("Plain literal pattern produces a single substring")
    func plainLiteral() {
        let literals = RegexLiteralExtractor.literalSubstrings(in: "fetch")
        #expect(literals == ["fetch"])
    }

    @Test("Anchors and quantifiers split the literal stream")
    func anchorsAndQuantifiers() {
        // `^fetch.*Data$` → literals "fetch" and "Data" (the `.` and `$`
        // break the stream; the `^` is a metacharacter consumed as a
        // boundary).
        let literals = RegexLiteralExtractor.literalSubstrings(in: "^fetch.*Data$")
        #expect(literals.contains("fetch"))
        #expect(literals.contains("Data"))
    }

    @Test("Optional-quantified characters drop from the literal")
    func optionalQuantifierDrops() {
        // `colou?r` should yield "colo" only — the `u?` makes `u`
        // ungovern­ed, and we conservatively also drop it from the
        // preceding literal.
        let literals = RegexLiteralExtractor.literalSubstrings(in: "colou?r")
        // We accept either "colo" alone, or both "colo" and "r" (but
        // "r" is too short for the >=3 filter).
        #expect(literals.contains("colo"))
        // "u" was governed by `?`; should not appear as a literal.
        #expect(!literals.contains("colou"))
    }

    @Test("Character classes yield no extractable literal")
    func characterClassYieldsNone() {
        let literals = RegexLiteralExtractor.literalSubstrings(in: "[abc][def][ghi]")
        // Nothing outside the brackets, and bracket content isn't a
        // single-byte literal.
        #expect(literals.isEmpty)
    }

    @Test("Group content is excluded from extraction")
    func groupContentExcluded() {
        // `prefix(?:foo|bar)suffix` — top-level literals are `prefix`
        // and `suffix`; the alternation inside the group is dropped.
        let literals = RegexLiteralExtractor.literalSubstrings(in: "prefix(?:foo|bar)suffix")
        #expect(literals.contains("prefix"))
        #expect(literals.contains("suffix"))
    }

    @Test("Escaped metacharacters do not become literals")
    func escapedMetacharsDrop() {
        // `\d+` has no literal content. `foo\\.bar` — the `\\` escapes
        // the `.`, but the conservative parser drops the run.
        #expect(RegexLiteralExtractor.literalSubstrings(in: #"\d+"#).isEmpty)
    }

    @Test("Required trigrams: pattern with no extractable literals returns nil")
    func noLiteralsReturnsNil() {
        #expect(RegexLiteralExtractor.requiredTrigrams(in: ".*") == nil)
        #expect(RegexLiteralExtractor.requiredTrigrams(in: "[abc]+") == nil)
        #expect(RegexLiteralExtractor.requiredTrigrams(in: "ab") == nil)  // < 3 chars
    }

    @Test("Required trigrams: pattern with literal `fetch` yields its trigrams")
    func literalYieldsTrigrams() {
        let trigrams = RegexLiteralExtractor.requiredTrigrams(in: "^fetch$")
        #expect(trigrams == ["fet", "etc", "tch"])
    }
}
