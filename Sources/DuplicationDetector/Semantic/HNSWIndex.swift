//  HNSWIndex.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - HNSWConfiguration

/// Tunable parameters for `HNSWIndex`.
///
/// Defaults follow Malkov & Yashunin (2016): `M = 16`, `efConstruction = 200`,
/// `efSearch = 50`. The `mL` factor follows the paper's recommendation of
/// `1 / ln(M)` for exponentially-decreasing layer entry probability.
public struct HNSWConfiguration: Sendable, Hashable {
    // MARK: Lifecycle

    public init(
        m: Int = 16,
        efConstruction: Int = 200,
        efSearch: Int = 50,
        seed: UInt64 = 0xDEAD_BEEF_BAAD_F00D
    ) {
        precondition(m > 0, "M must be > 0")
        precondition(efConstruction > 0, "efConstruction must be > 0")
        precondition(efSearch > 0, "efSearch must be > 0")
        self.m = m
        self.mMax0 = m * 2
        self.efConstruction = max(efConstruction, m)
        self.efSearch = max(efSearch, 1)
        self.mL = 1.0 / log(Double(m))
        self.seed = seed
    }

    // MARK: Public

    public static let `default` = HNSWConfiguration()

    /// Maximum neighbors per node at layers > 0.
    public let m: Int

    /// Maximum neighbors at layer 0 (typically 2 * M).
    public let mMax0: Int

    /// Beam-search width during insertion.
    public let efConstruction: Int

    /// Beam-search width during query (can be overridden per call).
    public let efSearch: Int

    /// Layer-assignment normalization factor (1 / ln(M)).
    public let mL: Double

    /// PRNG seed for deterministic layer assignment.
    public let seed: UInt64
}

// MARK: - SeededPRNG

/// Deterministic PRNG (splitmix64) used for HNSW layer assignment.
struct SeededPRNG: RandomNumberGenerator, Sendable {
    var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xDEAD_BEEF_BAAD_F00D : seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - HNSWSearchResult

/// Result entry returned from `HNSWIndex.search`.
public struct HNSWSearchResult<Identifier: Hashable & Sendable>: Sendable {
    /// Identifier supplied at insert time.
    public let id: Identifier
    /// Cosine similarity in [-1, 1]. For normalized non-negative vectors this lies in [0, 1].
    public let similarity: Float
}

// MARK: - HNSWVectorMath

/// Vector helpers used internally; exposed `internal` for tests.
enum HNSWVectorMath {
    @inlinable
    static func normalize(_ v: inout [Float]) {
        var sumSq: Float = 0
        for value in v { sumSq += value * value }
        guard sumSq > 0 else { return }
        let inv = 1.0 / sqrt(sumSq)
        for i in 0..<v.count { v[i] *= inv }
    }

    @inlinable
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "dimension mismatch")
        var acc: Float = 0
        for i in 0..<a.count { acc += a[i] * b[i] }
        return acc
    }

    /// Cosine distance for already-normalized vectors: `1 - dot(a, b)`.
    @inlinable
    static func cosineDistanceNormalized(_ a: [Float], _ b: [Float]) -> Float {
        return 1.0 - dot(a, b)
    }
}

// MARK: - HNSWIndex

/// Hand-rolled Hierarchical Navigable Small World index over `[Float]` vectors.
///
/// HNSW (Malkov & Yashunin, 2016) builds a multi-layer graph where each layer
/// is a navigable small-world graph and higher layers act as a long-range
/// router. Insertions assign each point a level `floor(-ln(uniform) * mL)` so
/// each layer has exponentially fewer points than the one below.
///
/// Query proceeds top-down: greedy descent to the entry point at the query
/// node's level, then beam search with width `ef` at layer 0 to assemble the
/// top-k nearest neighbors.
///
/// Cosine distance is used with vectors L2-normalized at insert time. Inputs
/// do NOT need to be pre-normalized — `insert(id:vector:)` normalizes a copy.
///
/// Operations are not thread-safe; construct on a single actor or guard
/// externally. Once built and treated as immutable, `search(query:k:)` is safe
/// to call concurrently because the underlying storage is value-type.
public struct HNSWIndex<Identifier: Hashable & Sendable>: Sendable {
    // MARK: Lifecycle

    public init(dimension: Int, configuration: HNSWConfiguration = .default) {
        precondition(dimension > 0, "dimension must be > 0")
        self.dimension = dimension
        self.configuration = configuration
        self.prng = SeededPRNG(seed: configuration.seed)
    }

    // MARK: Public

    public let dimension: Int
    public let configuration: HNSWConfiguration

    public var count: Int { points.count }

    public mutating func insert(id: Identifier, vector: [Float]) {
        precondition(vector.count == dimension, "vector dimension mismatch")

        var normalized = vector
        HNSWVectorMath.normalize(&normalized)

        let level = assignLevel()
        let nodeIndex = points.count
        points.append(Point(id: id, vector: normalized, level: level))
        ensureLayerCapacity(upTo: level)

        guard let currentEntry = entryPoint else {
            entryPoint = nodeIndex
            return
        }

        var entry = currentEntry
        let topLevel = points[entry].level

        if topLevel > level {
            for layer in stride(from: topLevel, to: level, by: -1) {
                entry = greedyClosest(to: normalized, entry: entry, layer: layer)
            }
        }

        let startLayer = min(topLevel, level)
        for layer in stride(from: startLayer, through: 0, by: -1) {
            let mMax = (layer == 0) ? configuration.mMax0 : configuration.m
            let candidates = searchLayer(
                query: normalized,
                entry: entry,
                ef: configuration.efConstruction,
                layer: layer
            )

            let neighbors = selectNeighborsHeuristic(
                candidates: candidates,
                m: configuration.m
            )

            for neighbor in neighbors {
                connect(nodeIndex, neighbor, atLayer: layer, mMax: mMax)
                connect(neighbor, nodeIndex, atLayer: layer, mMax: mMax)
            }

            if let first = neighbors.first { entry = first }
        }

        if level > topLevel {
            entryPoint = nodeIndex
        }
    }

    public func search(
        query: [Float],
        k: Int,
        ef: Int? = nil
    ) -> [HNSWSearchResult<Identifier>] {
        precondition(query.count == dimension, "query dimension mismatch")
        guard k > 0, let entry = entryPoint, !points.isEmpty else { return [] }

        var normalized = query
        HNSWVectorMath.normalize(&normalized)

        var current = entry
        let topLevel = points[entry].level

        if topLevel > 0 {
            for layer in stride(from: topLevel, to: 0, by: -1) {
                current = greedyClosest(to: normalized, entry: current, layer: layer)
            }
        }

        let efActual = max(ef ?? configuration.efSearch, k)
        let candidates = searchLayer(
            query: normalized,
            entry: current,
            ef: efActual,
            layer: 0
        )

        let sorted = candidates.sorted { $0.distance < $1.distance }
        let limit = min(k, sorted.count)
        var results: [HNSWSearchResult<Identifier>] = []
        results.reserveCapacity(limit)
        for i in 0..<limit {
            let entry = sorted[i]
            let similarity = 1.0 - entry.distance
            results.append(
                HNSWSearchResult(id: points[entry.index].id, similarity: similarity)
            )
        }
        return results
    }

    // MARK: Internal

    struct Point: Sendable {
        let id: Identifier
        let vector: [Float]
        let level: Int
    }

    struct CandidateNode: Sendable {
        let index: Int
        let distance: Float
    }

    var points: [Point] = []
    var layers: [[Int: [Int]]] = []
    var entryPoint: Int?
    var prng: SeededPRNG

    // MARK: Private

    private mutating func assignLevel() -> Int {
        let raw = prng.next()
        let u = (Double(raw) / Double(UInt64.max)).clamped(min: 1e-12, max: 1.0)
        let level = Int(floor(-log(u) * configuration.mL))
        return max(0, level)
    }

    private mutating func ensureLayerCapacity(upTo layer: Int) {
        while layers.count <= layer {
            layers.append([:])
        }
    }

    private func greedyClosest(to query: [Float], entry: Int, layer: Int) -> Int {
        var current = entry
        var currentDistance = HNSWVectorMath.cosineDistanceNormalized(query, points[current].vector)
        var improved = true

        while improved {
            improved = false
            let neighbors = layers[layer][current] ?? []
            for neighbor in neighbors {
                let d = HNSWVectorMath.cosineDistanceNormalized(query, points[neighbor].vector)
                if d < currentDistance {
                    currentDistance = d
                    current = neighbor
                    improved = true
                }
            }
        }

        return current
    }

    private func searchLayer(
        query: [Float],
        entry: Int,
        ef: Int,
        layer: Int
    ) -> [CandidateNode] {
        let entryDist = HNSWVectorMath.cosineDistanceNormalized(query, points[entry].vector)
        var visited: Set<Int> = [entry]

        var frontier = MinPriorityQueue<Float, Int>()
        frontier.push(priority: entryDist, value: entry)

        var results = BoundedMaxHeap(capacity: ef)
        results.push(distance: entryDist, index: entry)

        while let (frontierDistance, current) = frontier.pop() {
            if let worstBest = results.worstDistance, frontierDistance > worstBest {
                break
            }

            let neighbors = layers[layer][current] ?? []
            for neighbor in neighbors where !visited.contains(neighbor) {
                visited.insert(neighbor)
                let d = HNSWVectorMath.cosineDistanceNormalized(query, points[neighbor].vector)
                if results.count < ef || d < (results.worstDistance ?? .greatestFiniteMagnitude) {
                    frontier.push(priority: d, value: neighbor)
                    results.push(distance: d, index: neighbor)
                }
            }
        }

        return results.entries.map { CandidateNode(index: $0.index, distance: $0.distance) }
    }

    private func selectNeighborsHeuristic(
        candidates: [CandidateNode],
        m: Int
    ) -> [Int] {
        candidates.sorted { $0.distance < $1.distance }.prefix(m).map(\.index)
    }

    private mutating func connect(_ from: Int, _ to: Int, atLayer layer: Int, mMax: Int) {
        guard from != to else { return }
        var current = layers[layer][from] ?? []
        if !current.contains(to) {
            current.append(to)
        }

        if current.count > mMax {
            let fromVec = points[from].vector
            let ranked = current.map { neighbor -> (Int, Float) in
                let d = HNSWVectorMath.cosineDistanceNormalized(fromVec, points[neighbor].vector)
                return (neighbor, d)
            }.sorted { $0.1 < $1.1 }
            current = ranked.prefix(mMax).map(\.0)
        }

        layers[layer][from] = current
    }
}

// MARK: - Double clamp

extension Double {
    fileprivate func clamped(min lo: Double, max hi: Double) -> Double {
        Swift.max(lo, Swift.min(self, hi))
    }
}

// MARK: - MinPriorityQueue

/// Tiny generic binary-heap priority queue (min-on-priority). Internal-only.
struct MinPriorityQueue<Priority: Comparable, Value>: Sendable
where Priority: Sendable, Value: Sendable {
    private var storage: [(Priority, Value)] = []

    var count: Int { storage.count }

    mutating func push(priority: Priority, value: Value) {
        storage.append((priority, value))
        siftUp(from: storage.count - 1)
    }

    mutating func pop() -> (Priority, Value)? {
        guard !storage.isEmpty else { return nil }
        storage.swapAt(0, storage.count - 1)
        let last = storage.removeLast()
        if !storage.isEmpty { siftDown(from: 0) }
        return last
    }

    private mutating func siftUp(from index: Int) {
        var i = index
        while i > 0 {
            let parent = (i - 1) / 2
            if storage[i].0 < storage[parent].0 {
                storage.swapAt(i, parent)
                i = parent
            } else {
                break
            }
        }
    }

    private mutating func siftDown(from index: Int) {
        var i = index
        let n = storage.count
        while true {
            let left = 2 * i + 1
            let right = 2 * i + 2
            var smallest = i
            if left < n, storage[left].0 < storage[smallest].0 { smallest = left }
            if right < n, storage[right].0 < storage[smallest].0 { smallest = right }
            if smallest == i { break }
            storage.swapAt(i, smallest)
            i = smallest
        }
    }
}

// MARK: - BoundedMaxHeap

/// Bounded max-heap of `(distance, index)` capped at `capacity`. Used to track
/// the `ef` best candidates during beam search. O(capacity) push when full;
/// capacity is small (ef ~50-200) so practically constant.
struct BoundedMaxHeap: Sendable {
    struct Entry: Sendable {
        let distance: Float
        let index: Int
    }

    private(set) var entries: [Entry] = []
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "capacity must be > 0")
        self.capacity = capacity
        self.entries.reserveCapacity(capacity)
    }

    var count: Int { entries.count }
    var worstDistance: Float? { entries.max(by: { $0.distance < $1.distance })?.distance }

    mutating func push(distance: Float, index: Int) {
        if entries.count < capacity {
            entries.append(Entry(distance: distance, index: index))
            return
        }

        var worstIndex = 0
        var worst = entries[0].distance
        for (i, entry) in entries.enumerated() where entry.distance > worst {
            worst = entry.distance
            worstIndex = i
        }

        if distance < worst {
            entries[worstIndex] = Entry(distance: distance, index: index)
        }
    }
}
