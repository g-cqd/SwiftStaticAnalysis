# Parallel BFS study for SwiftStaticAnalysis

## Scope
- Review how BFS is used in this codebase and why it is currently sequential.
- Summarize state-of-the-art parallel BFS techniques from the literature.
- Map those techniques to SwiftStaticAnalysis with concrete implementation options.

## Codebase review (current BFS usage)
- `Sources/UnusedCodeDetector/Reachability/ReachabilityGraph.swift` uses sequential BFS inside a Swift `actor` to compute reachability from root declarations. The file explicitly documents why BFS is kept sequential and points out that the parallel speedup comes from edge construction instead.
- `Sources/UnusedCodeDetector/Reachability/DependencyExtractor.swift` already parallelizes edge computation with `ParallelProcessor`, then performs a single batch insertion into the actor.
- `Sources/UnusedCodeDetector/IndexStore/IndexBasedDependencyGraph.swift` runs sequential BFS guarded by `NSLock` to compute reachability for IndexStoreDB-backed graphs.
- `Sources/SwiftStaticAnalysisCore/Incremental/DependencyTracker.swift` uses sequential BFS to compute transitive dependents for incremental analysis.
- `Sources/DuplicationDetector/MinHash/MinHashCloneDetector.swift` uses BFS to compute connected components for clone groups.

Implementation notes that matter for parallelization:
- BFS queues are `Array` with `removeFirst()`, which is O(n) per pop. This is acceptable for small graphs, but it becomes a hot cost at scale.
- Node identities are `String` IDs; visited sets are `Set<String>`. For large graphs, a dense integer mapping plus bitset can reduce memory and speed up atomic checks.
- The reachability graph is an `actor`, which makes parallel traversal tricky unless the traversal operates on a snapshot of adjacency data outside actor isolation.

## Literature summary (parallel BFS state of the art)
The core idea across modern parallel BFS is to process a frontier in parallel, then synchronize between levels. Variations optimize how neighbors are discovered and how much work is done per level.

Shared-memory and general-purpose CPU approaches:
- Direction-optimizing BFS (Beamer, Asanovic, Patterson, 2012) switches between top-down (frontier expands neighbors) and bottom-up (unvisited nodes check for any parent in frontier) to reduce edge examinations when the frontier is large.
- Ordered vs unordered parallel BFS (Hassaan, Burtscher, Pingali, 2010) contrasts strict level-synchronous traversal with relaxed approaches that trade determinism for throughput.
- Work-efficient parallel BFS (Leiserson, Schardl, 2010) uses bag-based or reducer-based parallelism to avoid contention and keep total work near O(V+E).
- Ligra (Shun, Blelloch, 2013) models BFS as vertex-subset operations over frontiers, using parallel primitives that scale well on shared memory.

Distributed memory and large-scale graph approaches:
- Buluç and Madduri (2011) and Yoo et al. (2005) show distributed BFS with careful partitioning and communication. 2D partitioning is commonly used to reduce communication volume.
- Beamer et al. (2013) extend bottom-up BFS to distributed settings by coordinating frontier checks efficiently.

GPU approaches (relevant conceptually, less so for this codebase):
- Luo, Wong, Hwu (2010) and later multi-GPU work show frontier expansion using warp-friendly data layouts, prefix sums, and compacted frontiers.

Key ideas to carry over:
- Level-synchronous frontier traversal with parallel neighbor expansion.
- Direction-optimizing BFS when frontier becomes large relative to remaining graph.
- Per-thread local frontiers with a merge step to reduce synchronization.
- Bitset or bitmap visited representation for fast atomic test-and-set.

## Applicability to SwiftStaticAnalysis
This project is not a BFS benchmark workload. The comments in `Sources/UnusedCodeDetector/Reachability/ReachabilityGraph.swift` correctly note that typical graph sizes are small enough that parallel BFS overhead can dominate. That said, there are two realistic scenarios where parallel BFS could help:
1. Large IndexStoreDB graphs spanning many modules or monorepos.
2. Bulk analysis runs (e.g., CI) where reachability and connected components are performed repeatedly.

Given that reachability order is not observable (only the set of reachable nodes is used), this codebase can use unordered parallel BFS without requiring deterministic visitation order.

## Parallel BFS design options for this repo

### Option A: Improve sequential BFS (low risk)
- Replace `removeFirst()` with an index-based queue (array plus head index) to avoid O(n) shifts.
- Continue using `Set<String>` but reduce allocations by reserving capacity.

### Option B: Level-synchronous parallel BFS (shared memory)
- Snapshot the adjacency list and roots to a local, Sendable structure outside the actor.
- Map node IDs to dense integers, store adjacency as `[Int]` slices, and store visited as a bitset or `[UInt64]` array.
- Use `TaskGroup` or `DispatchQueue.concurrentPerform` to process the frontier in chunks.
- Each task builds a local `nextFrontier`, then merge at a level barrier.

### Option C: Direction-optimizing BFS
- Leverage existing `reverseEdges` in `ReachabilityGraph` and `IndexBasedDependencyGraph` to implement bottom-up steps.
- Heuristic from Beamer et al.: switch to bottom-up when `frontierEdges` exceeds `remainingEdges / alpha` (alpha often 14-24 in literature), and switch back when the frontier shrinks.
- Bottom-up step scans unvisited nodes and checks for any incoming edge from the frontier. This can be parallelized by partitioning the unvisited set across tasks.

### Option D: Hybrid thresholding
- Keep sequential BFS for graphs smaller than a threshold (e.g., < 50k nodes or < 200k edges).
- Use parallel BFS only when the graph is large enough to amortize overhead.

## Implementation sketch (Swift concurrency)
Pseudo-approach for a level-synchronous parallel BFS:

1. Snapshot graph data:
   - Convert `nodes` and `edges` dictionaries into arrays:
     - `idToIndex: [String: Int]`
     - `indexToId: [String]`
     - `adjacency: [[Int]]`
   - Capture `roots` as `[Int]`.

2. Use a dense visited bitset:
   - `visited: [UInt64]` or `ManagedAtomic<UInt64>` if using atomics.
   - A thread sets a bit with a test-and-set operation to avoid duplicate visits.

3. Iterate levels:
   - Split `frontier` into chunks by index.
   - Each task processes neighbors and pushes newly discovered nodes into a thread-local array.
   - Merge local arrays into `nextFrontier` and repeat.

4. Direction-optimizing variant:
   - When switching to bottom-up, iterate over unvisited nodes in parallel and test incoming neighbors for membership in the frontier (frontier as a bitset).

Notes on actor isolation:
- For `ReachabilityGraph`, add a method to export a snapshot (arrays) so the parallel BFS runs outside the actor.
- For `IndexBasedDependencyGraph`, copy adjacency under the lock and release before parallel traversal.

## Testing and correctness
- Reachability is a set; parallel BFS should be validated against the sequential result.
- Add stress tests with randomized graphs to detect missed nodes or races.
- Ensure caches (`reachableCache`) are invalidated consistently if a parallel path is introduced.

## References
- Scott Beamer, Krste Asanovic, David A. Patterson. "Direction-optimizing Breadth-First Search" (2012). DOI: 10.1109/SC.2012.50. OpenAlex: https://openalex.org/W4253426709
- Scott Beamer, Aydin Buluc, Krste Asanovic, David A. Patterson. "Distributed Memory Breadth-First Search Revisited: Enabling Bottom-Up Search" (2013). DOI: 10.1109/IPDPSW.2013.159. OpenAlex: https://openalex.org/W2081538566
- Aydin Buluc, Kamesh Madduri. "Parallel breadth-first search on distributed memory systems" (2011). DOI: 10.1145/2063384.2063471. OpenAlex: https://openalex.org/W2154111453
- Andrew S. Yoo, Edmond Chow, Keith Henderson, William McLendon, Bruce Hendrickson, Umit V. Catalyurek. "A Scalable Distributed Parallel Breadth-First Search Algorithm on BlueGene/L" (2005). DOI: 10.1109/SC.2005.4. OpenAlex: https://openalex.org/W2141662114
- Charles E. Leiserson, Tao B. Schardl. "A work-efficient parallel breadth-first search algorithm (or how to cope with the nondeterminism of reducers)" (2010). DOI: 10.1145/1810479.1810534. OpenAlex: https://openalex.org/W2152907584
- M. Amber Hassaan, Martin Burtscher, Keshav Pingali. "Ordered and unordered algorithms for parallel breadth first search" (2010). DOI: 10.1145/1854273.1854341. OpenAlex: https://openalex.org/W2037218074
- Julian Shun, Guy E. Blelloch. "Ligra" (2013). DOI: 10.1145/2517327.2442530. OpenAlex: https://openalex.org/W4234988573
- Lijuan Luo, Martin D. F. Wong, Wen-mei Hwu. "An effective GPU implementation of breadth-first search" (2010). DOI: 10.1145/1837274.1837289. OpenAlex: https://openalex.org/W2143114052
