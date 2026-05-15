//  TrigramIndex.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftStaticAnalysisCore

// MARK: - TrigramIndex

/// Inverted index keyed on 3-character substrings (trigrams) of symbol
/// names. For a regex query whose pattern contains literal runs of at
/// least 3 characters, we extract the required trigrams from the
/// literal segments and intersect their posting lists to narrow the
/// candidate set before applying the full regex. The result is the
/// same as a linear scan but with the regex match step touching only
/// the candidates, not the full definition corpus.
///
/// This mirrors the trigram-inverted-index pattern clangd's
/// `global-index` uses for fuzzy symbol search: complexity drops from
/// O(n) (linear scan over all definitions) to roughly
/// O(k log m + r × match_cost) where k = trigrams extracted, m = posting
/// list size, r = candidates surviving intersection.
///
/// Build cost: O(Σ len(name)) over the indexed set, executed once and
/// cached per resolver instance.
///
/// ## Thread safety
///
/// The class is `Sendable` because all stored state is set in
/// `init(definitions:)` and never mutated thereafter. Concurrent
/// readers across queries are safe.
final class TrigramIndex: Sendable {
    /// Build a trigram index over the provided definition occurrences.
    /// Each occurrence's symbol name is decomposed into 3-character
    /// case-sensitive trigrams; ties posting to the occurrence's index
    /// in the source array.
    init(definitions: [IndexedOccurrence]) {
        var index: [String: [Int]] = [:]
        index.reserveCapacity(max(16, definitions.count / 4))
        for (position, occurrence) in definitions.enumerated() {
            let name = occurrence.symbol.name
            // Skip ultra-short names — they contribute no trigrams.
            // Callers that want to find short names should use exact
            // name lookup, not regex.
            guard name.count >= 3 else { continue }
            for trigram in TrigramIndex.trigrams(of: name) {
                index[trigram, default: []].append(position)
            }
        }
        self.postings = index
        self.definitionCount = definitions.count
    }

    /// Number of definitions the index was built over. Useful for
    /// callers comparing candidate-set size against the corpus.
    let definitionCount: Int

    /// Returns the set of definition positions matching every trigram
    /// in `requiredTrigrams`. Empty set means no candidates; `nil`
    /// means the trigrams were not all present in the index and the
    /// caller should fall back to a linear scan (the intersection is
    /// undefined when a posting list is missing).
    ///
    /// The intersection is computed against the smallest posting list
    /// first so the working set shrinks as quickly as possible.
    func candidates(requiredTrigrams: some Sequence<String>) -> Set<Int>? {
        let trigrams = Array(requiredTrigrams)
        guard !trigrams.isEmpty else { return nil }

        // Look up all posting lists; bail if any trigram is missing.
        var lists: [[Int]] = []
        lists.reserveCapacity(trigrams.count)
        for trigram in trigrams {
            guard let list = postings[trigram] else {
                // A required trigram that doesn't appear in the index
                // means no definition can match — the intersection is
                // empty. Return an empty set, not nil; nil signals
                // "fall back to linear scan", which would be wrong
                // here.
                return []
            }
            lists.append(list)
        }

        // Intersect smallest-first. Each posting list is already
        // sorted by definition position (we append in order during
        // build), so we could use a merge-style intersection — for
        // the typical query (few trigrams, modest posting lists),
        // the simpler `Set` intersection is fast enough and clearer.
        lists.sort { $0.count < $1.count }
        var working = Set(lists[0])
        for list in lists.dropFirst() {
            working.formIntersection(list)
            if working.isEmpty { return working }
        }
        return working
    }

    /// Decompose a name into its case-sensitive trigrams.
    static func trigrams(of name: String) -> [String] {
        guard name.count >= 3 else { return [] }
        let scalars = Array(name.unicodeScalars)
        var result: [String] = []
        result.reserveCapacity(scalars.count - 2)
        var window = String.UnicodeScalarView()
        window.reserveCapacity(3)
        for index in 0...(scalars.count - 3) {
            window.removeAll(keepingCapacity: true)
            window.append(scalars[index])
            window.append(scalars[index + 1])
            window.append(scalars[index + 2])
            result.append(String(window))
        }
        return result
    }

    private let postings: [String: [Int]]
}
