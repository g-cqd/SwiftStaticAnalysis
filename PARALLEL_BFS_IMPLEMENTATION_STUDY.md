# Parallel BFS Implementation Study

## Executive Summary

This document analyzes state-of-the-art parallel Breadth-First Search (BFS) algorithms from scientific literature and evaluates their applicability to the SwiftStaticAnalysis codebase for reachability-based unused code detection.

**Key Finding**: For typical codebase sizes (hundreds to low thousands of nodes), the overhead of parallel BFS likely exceeds benefits. However, for very large codebases (10K+ nodes), a hybrid direction-optimizing approach could provide 2-4x speedup.

---

## Table of Contents

1. [Current Implementation Analysis](#current-implementation-analysis)
2. [Scientific Literature Review](#scientific-literature-review)
3. [Parallel BFS Algorithms](#parallel-bfs-algorithms)
4. [Applicability Analysis](#applicability-analysis)
5. [Swift Concurrency Considerations](#swift-concurrency-considerations)
6. [Recommendations](#recommendations)
7. [References](#references)

---

## Current Implementation Analysis

### Codebase Structure

The SwiftStaticAnalysis project has two BFS implementations:

#### 1. `ReachabilityGraph` (Actor-based)

**Location**: `Sources/UnusedCodeDetector/Reachability/ReachabilityGraph.swift:295-324`

```swift
public func computeReachable() -> Set<String> {
    var reachable = Set<String>()
    var queue = Array(roots)
    var visited = Set<String>()

    while !queue.isEmpty {
        let current = queue.removeFirst()
        if visited.contains(current) { continue }
        visited.insert(current)
        reachable.insert(current)

        if let outgoing = edges[current] {
            for edge in outgoing where !visited.contains(edge.to) {
                queue.append(edge.to)
            }
        }
    }
    return reachable
}
```

**Characteristics**:
- Standard sequential BFS with O(V+E) complexity
- Uses Swift `actor` for thread safety
- Queue implemented as `Array` with `removeFirst()` (O(n) dequeue)
- Visited set uses `Set<String>` for O(1) lookups

#### 2. `IndexBasedDependencyGraph` (Lock-based)

**Location**: `Sources/UnusedCodeDetector/IndexStore/IndexBasedDependencyGraph.swift:220-251`

- Nearly identical algorithm
- Uses `NSLock` instead of actor (due to non-Sendable `IndexStoreDB` dependency)
- Same O(V+E) complexity

### Current Performance Bottlenecks

1. **Queue Operations**: `Array.removeFirst()` is O(n), causing O(V²) worst-case for queue operations alone
2. **String-based Node IDs**: Hash computation overhead for every lookup
3. **Sequential Traversal**: No parallelism in frontier expansion

---

## Scientific Literature Review

### Foundational Work

#### Level-Synchronous Parallel BFS

The classic parallel BFS approach processes vertices level-by-level with synchronization barriers between levels.

**Complexity**: O((V+E)/P + D) where:
- P = number of processors
- D = graph diameter (longest shortest path)

**Key Insight**: The diameter D creates an inherent sequential dependency chain - level k cannot be processed until level k-1 is complete.

> "A barrier synchronization is needed after every layer in order to completely discover all neighbor vertices in the frontier."
> — [Level-Synchronous Parallel BFS Algorithms](https://www.semanticscholar.org/paper/Level-Synchronous-Parallel-Breadth-First-Search-For-Berrendorf-Makulla/cde0420a117f8643d066cdcd60c95d5ca39a1082)

#### Work-Efficient PBFS (Leiserson & Schardl, 2010)

Charles Leiserson and Tao Schardl introduced a work-efficient parallel BFS using a novel "bag" data structure.

**Key Innovation**: The bag multiset replaces the FIFO queue, enabling:
- O(1) amortized insertion
- Efficient parallel splitting for work distribution
- Cache-friendly memory access patterns

**Bag Structure**:
- Array of "pennants" (complete binary trees with extra root)
- Pennant at index i has 2^i nodes
- Merge operation is O(1) - like binary addition

**Complexity**: O((V+E)/P + D·lg³(V/D)) expected time on P processors

> "For a variety of benchmark input graphs whose diameters are significantly smaller than the number of vertices — a condition met by many real-world graphs — PBFS demonstrates good speedup."
> — [Leiserson & Schardl, SPAA 2010](https://dl.acm.org/doi/10.1145/1810479.1810534)

### Direction-Optimizing BFS (Beamer et al., 2012)

The most significant advancement in BFS optimization, introduced by Scott Beamer, Krste Asanović, and David Patterson.

#### Core Insight

Traditional "top-down" BFS examines all edges from frontier vertices. For large frontiers, most edge checks fail because targets are already visited.

**Bottom-up approach**: Instead of frontier vertices checking neighbors, unvisited vertices check if ANY neighbor is in the frontier. A vertex needs only ONE parent, not to be claimed by all potential parents.

#### When Each Approach Wins

| Approach | Best When | Why |
|----------|-----------|-----|
| Top-Down | Small frontier (<10% of vertices) | Few edges to check |
| Bottom-Up | Large frontier (>10% of vertices) | Most vertices have frontier neighbor |

#### Hybrid Algorithm

```
frontier = {source}
while frontier not empty:
    if should_switch_to_bottom_up(frontier):
        next = bottom_up_step(frontier)
    else:
        next = top_down_step(frontier)
    frontier = next
```

#### Switching Heuristics (α and β parameters)

**Top-Down to Bottom-Up** (α threshold):
- Switch when: `edges_to_check > α × remaining_edges`
- Recommended: α = 14

**Bottom-Up to Top-Down** (β threshold):
- Switch when: `frontier_size < vertices / β`
- Recommended: β = 24

> "Once α is sufficiently large (>12), BFS performance for many graphs is relatively insensitive to its value."
> — [Beamer et al., SC 2012](http://www.scottbeamer.net/pubs/beamer-sc2012.pdf)

### Recent Advances (2024-2025)

#### ABi-BFS (Asynchronous Bidirectional BFS)

Presented at IEEE 2024, introduces:
- Asynchronous node-expanding to reduce synchronization overhead
- Optimized frontier node selection in bottom-up step
- Achieves highest scalability among PBFS algorithms on shared-memory systems

#### Performance-Driven Optimization (March 2025)

[ArXiv 2503.00430](https://arxiv.org/abs/2503.00430) presents:
- Hybrid traversal strategies
- Bitmap-based visited set (cache-efficient)
- Non-atomic distance updates
- **Results**: 3-10x speedup on low-diameter graphs

#### Supercomputer Scale

The K-Computer achieved 38,621.4 GTEPS (Giga Traversed Edges Per Second) on trillion-vertex graphs using distributed parallel BFS.

---

## Parallel BFS Algorithms

### Algorithm 1: Level-Synchronous PBFS

```
parallel_bfs_level_sync(G, source):
    level[source] = 0
    frontier = {source}

    while frontier not empty:
        next_frontier = parallel_for v in frontier:
            parallel_for neighbor in G.neighbors(v):
                if level[neighbor] == UNVISITED:
                    level[neighbor] = level[v] + 1
                    add neighbor to next_frontier  // needs synchronization

        barrier()  // wait for all threads
        frontier = next_frontier
```

**Pros**: Simple, deterministic level assignment
**Cons**: Barrier overhead, load imbalance

### Algorithm 2: Bag-Based PBFS (Leiserson-Schardl)

```
pbfs_with_bags(G, source):
    in_bag = new Bag()
    in_bag.insert(source)
    visited[source] = true

    while not in_bag.empty():
        out_bag = new Bag()

        parallel_for v in in_bag.split():  // divide work
            for neighbor in G.neighbors(v):
                if not visited[neighbor]:
                    visited[neighbor] = true  // reducer handles races
                    out_bag.insert(neighbor)

        in_bag = out_bag
```

**Key**: Bag splits enable load-balanced work distribution

### Algorithm 3: Direction-Optimizing BFS

```
direction_optimizing_bfs(G, source):
    frontier = Bitmap(|V|)
    next = Bitmap(|V|)
    frontier.set(source)

    while frontier.any():
        if edges_from_frontier > α * remaining_edges:
            // Bottom-up: unvisited check frontier
            parallel_for v in unvisited_vertices:
                for neighbor in G.neighbors(v):
                    if frontier.test(neighbor):
                        parent[v] = neighbor
                        next.set(v)
                        break  // found one parent, done
        else:
            // Top-down: frontier expands outward
            parallel_for v in frontier:
                for neighbor in G.neighbors(v):
                    if not visited[neighbor]:
                        parent[neighbor] = v
                        next.set(neighbor)

        visited |= next
        frontier = next
        next.clear()
```

### Algorithm 4: Asynchronous PBFS

```
async_pbfs(G, source):
    queue = ConcurrentQueue()
    queue.push(source)
    visited[source] = true

    parallel_workers:
        while not terminated:
            if v = queue.try_pop():
                for neighbor in G.neighbors(v):
                    if CAS(visited[neighbor], false, true):
                        queue.push(neighbor)
            else:
                work_steal() or sleep()
```

**Pros**: No barriers, continuous work
**Cons**: Non-deterministic traversal order, complex termination detection

---

## Applicability Analysis

### Graph Characteristics in Code Analysis

| Metric | Typical Codebase | Large Codebase | Real-World Graphs |
|--------|------------------|----------------|-------------------|
| Vertices (V) | 100 - 1,000 | 1,000 - 50,000 | 10⁶ - 10¹² |
| Edges (E) | 500 - 10,000 | 10,000 - 500,000 | 10⁷ - 10¹⁴ |
| Diameter (D) | 5 - 15 | 10 - 30 | 5 - 20 |
| Avg Degree | 3 - 10 | 5 - 15 | 10 - 100 |

### Cost-Benefit Analysis

#### Parallelization Overhead

1. **Thread Creation**: ~1-10μs per thread
2. **Synchronization**: ~100ns per barrier (shared memory)
3. **Memory Allocation**: Concurrent data structures add overhead
4. **Cache Coherency**: False sharing can dominate small workloads

#### Expected Speedup

For graph G with V vertices, E edges, diameter D, on P processors:

**Level-Synchronous**: Speedup ≈ min(P, (V+E)/(D × overhead))

**Direction-Optimizing**: Speedup ≈ 2-4x for low-diameter graphs

| Codebase Size | Sequential BFS | Parallel Benefit | Recommendation |
|---------------|----------------|------------------|----------------|
| < 500 nodes | < 1ms | Negligible | Keep sequential |
| 500-5,000 nodes | 1-10ms | Marginal (1.5-2x) | Consider if hot path |
| 5,000-50,000 nodes | 10-100ms | Significant (2-4x) | Worth implementing |
| > 50,000 nodes | > 100ms | High (4-8x) | Strongly recommended |

### SwiftStaticAnalysis Specific Considerations

1. **Actor Isolation**: `ReachabilityGraph` is an actor - internal parallelism would require careful design to avoid actor reentrancy issues

2. **Edge Computation Already Parallel**: The expensive operation (edge building in `DependencyExtractor`) is already parallelized. BFS is typically < 5% of total analysis time.

3. **Cache Behavior**: Current string-based node IDs have poor cache locality. Switching to integer IDs would benefit both sequential and parallel versions.

4. **Determinism Requirements**: Unused code detection should be deterministic. Asynchronous PBFS variants may produce different traversal orders.

---

## Swift Concurrency Considerations

### Available Primitives

| Primitive | Use Case | Overhead |
|-----------|----------|----------|
| `TaskGroup` | Parallel frontier processing | Medium |
| `actor` | Safe shared state | High (serialization) |
| `Atomic` (via C) | Lock-free visited set | Low |
| `AsyncStream` | Producer-consumer patterns | Medium |

### Implementation Sketch: Level-Synchronous in Swift

```swift
public func computeReachableParallel() async -> Set<String> {
    var visited = Set<String>(roots)
    var frontier = Array(roots)

    while !frontier.isEmpty {
        // Process current frontier in parallel
        let nextFrontier = await withTaskGroup(of: [String].self) { group in
            // Chunk frontier for better load balancing
            let chunkSize = max(frontier.count / ProcessInfo.processInfo.activeProcessorCount, 1)

            for chunk in frontier.chunked(into: chunkSize) {
                group.addTask {
                    var localNext: [String] = []
                    for node in chunk {
                        if let outgoing = self.edges[node] {
                            for edge in outgoing {
                                // Note: visited check has race condition
                                // Would need atomic or lock
                                localNext.append(edge.to)
                            }
                        }
                    }
                    return localNext
                }
            }

            var allNext: [String] = []
            for await partial in group {
                allNext.append(contentsOf: partial)
            }
            return allNext
        }

        // Sequential deduplication and visited update
        frontier = nextFrontier.filter { visited.insert($0).inserted }
    }

    return visited
}
```

### Challenges

1. **Visited Set Synchronization**: The `visited` set must be thread-safe. Options:
   - Actor-isolated (serializes access, negating parallelism)
   - `OSAllocatedUnfairLock` (low overhead but requires careful usage)
   - Lock-free bitmap with atomics (complex to implement in Swift)

2. **Result Collection**: `TaskGroup` results must be collected sequentially

3. **Actor Reentrancy**: If `computeReachableParallel` is an actor method, calling it recursively or from tasks requires `nonisolated` design

---

## Recommendations

### Short-Term (No Changes)

The current sequential BFS is appropriate for most use cases:
- Simple, correct, deterministic
- BFS is < 5% of total analysis time
- Edge computation parallelization provides main speedup

### Medium-Term (Optimizations)

If profiling shows BFS as bottleneck:

1. **Replace String IDs with Integers**
   ```swift
   // Current: O(n) string hashing per lookup
   nodes: [String: DeclarationNode]

   // Proposed: O(1) array indexing
   nodes: [DeclarationNode]  // index = node ID
   ```

2. **Use Deque Instead of Array**
   ```swift
   // Current: O(n) removeFirst
   var queue = Array(roots)
   queue.removeFirst()

   // Proposed: O(1) amortized
   import Collections
   var queue = Deque(roots)
   queue.popFirst()
   ```

3. **Bitmap Visited Set** for large graphs
   ```swift
   // Current: Set<String> with hashing overhead
   // Proposed: Bitmap with O(1) bit operations
   var visited = Bitmap(size: nodeCount)
   ```

### Long-Term (Parallel Implementation)

For codebases > 10,000 nodes, consider:

1. **Direction-Optimizing BFS**
   - Implement top-down and bottom-up phases
   - Use bitmap for frontier representation
   - Tune α/β for code dependency graphs

2. **Level-Synchronous with Work Stealing**
   - Use `TaskGroup` for frontier expansion
   - Implement lock-free visited bitmap
   - Chunk work for load balancing

3. **Incremental BFS**
   - Cache reachability results
   - Invalidate only affected subgraphs on code changes
   - May provide better speedup than parallelization

---

## References

### Primary Sources

1. Leiserson, C. E., & Schardl, T. B. (2010). [A work-efficient parallel breadth-first search algorithm](https://dl.acm.org/doi/10.1145/1810479.1810534). SPAA '10.

2. Beamer, S., Asanović, K., & Patterson, D. (2012). [Direction-Optimizing Breadth-First Search](http://www.scottbeamer.net/pubs/beamer-sc2012.pdf). SC '12.

3. Buluç, A., & Madduri, K. (2011). [Parallel Breadth-First Search on Distributed Memory Systems](https://people.eecs.berkeley.edu/~aydin/sc11_bfs.pdf). SC '11.

4. [ABi-BFS: Asynchronous Bidirectional BFS](https://ieeexplore.ieee.org/document/10476037/). IEEE 2024.

5. [Performance-Driven Optimization of Parallel BFS](https://arxiv.org/abs/2503.00430). ArXiv 2025.

### Implementation References

6. [GAP Benchmark Suite - BFS Implementation](https://github.com/sbeamer/gapbs/blob/master/src/bfs.cc) (C++ reference implementation)

7. [Parallel BFS OpenMP/CUDA](https://github.com/berkerdemirel/Parallel-Breadth-First-Search-OpenMP-and-CUDA)

8. [Wikipedia: Parallel Breadth-First Search](https://en.wikipedia.org/wiki/Parallel_breadth-first_search)

### Swift Concurrency

9. [Swift Concurrency Documentation](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)

10. [Using Swift's concurrency system to run multiple tasks in parallel](https://www.swiftbysundell.com/articles/swift-concurrency-multiple-tasks-in-parallel/)

---

## Appendix: Complexity Summary

| Algorithm | Work | Span | Space |
|-----------|------|------|-------|
| Sequential BFS | O(V+E) | O(V+E) | O(V) |
| Level-Sync PBFS | O(V+E) | O(D·lg V) | O(V) |
| Bag PBFS | O(V+E) | O(D·lg³(V/D)) | O(V) |
| Direction-Opt | O(V+E) best, O(V·E) worst | O(D) | O(V) |

Where:
- V = vertices
- E = edges
- D = diameter
- P = processors
