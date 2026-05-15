# SwiftStaticAnalysis — Swift Code-Quality Audit

Audit target: `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis` (Swift 6.2, macOS 15+, Swift 6 language mode + StrictConcurrency on every target).
Auditor passes are read-only.

## Summary

SwiftStaticAnalysis is a mature, performance-conscious Swift 6 codebase that has clearly internalised the migration off legacy concurrency (no `DispatchQueue`/`NSLock`/`os_unfair_lock`/swift-atomics in production paths; uniform use of `Synchronization.Mutex`/`Atomic<UInt64>`, structured concurrency, typed throws, value types, `final` classes, and `~Copyable` Arena). There are **zero force-unwraps, zero `try!`, zero `as!`** anywhere in `Sources/`, two justified `fatalError`s in the Arena, and every `@unchecked Sendable` carries a written rationale. Adoption of `Span`/`RawSpan`, `Mersenne-61` SIMD MinHash, `Synchronization.Atomic`, swift-collections (`OrderedDictionary`, `Deque`), and `RegexBuilder` is broad and competent. The N+1 fix called out in the changelog (`IndexStoreAnalyzer.analyzeUsage` → `allOccurrencesByUSR`) is correctly in place. The dominant remaining issues are: (1) two unbounded `TaskGroup` spawning patterns that ignore their own `maxConcurrency` caps; (2) a chunked-and-fully-drained `ParallelProcessor` pattern that defeats streaming; (3) hand-rolled `Bitmap`/`AtomicBitmap` where `swift-collections` `BitArray` exists; (4) silent `UInt16` truncation in `SoATokenStorage.append`; (5) a wrong "LRU" eviction policy in `RegexCache` (uses `Dictionary.keys.first`, which is unordered); (6) systematic `String` paths instead of `URL`/`FilePath`; (7) `Foundation` imported in every target — `FoundationEssentials` is never used despite README's portability claims being mild; (8) under-utilised Swift Testing parameterised tests (zero `arguments:`), and tags defined but used in only 5 suites.

## Findings

### Concurrency / Sendable

#### High: `ParallelMinHashGenerator.computeSignatures` ignores `maxConcurrency`
- **File**: `Sources/DuplicationDetector/Parallel/ParallelMinHash.swift:56-80`
- **What**: Spawns one task per document with no cap (`for (index, document) in documents.enumerated() { group.addTask { ... } }`).
- **Why**: `self.maxConcurrency` is stored but never consulted. With 100k+ shingled documents (typical for a large codebase), this floods the cooperative thread pool. The neighbouring `computeSignaturesChunked` exists precisely for this reason but is not the default.
- **Recommendation**: Treat `computeSignatures` as a thin wrapper around `computeSignaturesChunked` with `chunkSize = maxConcurrency * 2` — or use the streaming TaskGroup pattern from `ZeroCopyParser.extractParallel` (lines 437–467) which keeps `inFlight` bounded by adding a new task each time one completes.

#### High: `ParallelProcessor.map/compactMap/forEach` blocks each chunk fully before starting the next
- **File**: `Sources/SwiftStaticAnalysisCore/Concurrency/ConcurrencyConfiguration.swift:98-118` (and 138-155, 168-184)
- **What**: The "large batch" path iterates `items.chunks(ofCount: batchSize)` and awaits the whole chunk inside its own `withThrowingTaskGroup` before starting the next chunk.
- **Why**: This serialises chunks. If a chunk contains one slow item, the entire pool idles until it completes. The correct shape is a single `TaskGroup` with `addTask` gated by a "tasks-in-flight" counter, drained with `group.next()` (see `ZeroCopyParser.extractParallel`).
- **Recommendation**: Replace with the bounded `TaskGroup` streaming pattern. Document `compactMap`'s "order not guaranteed" contract more loudly, or use indexed results everywhere.

#### Medium: `BackpressuredChannelStream.makeChannel` leaks an unstructured producer `Task`
- **File**: `Sources/SwiftStaticAnalysisCore/Concurrency/TaskBackedAsyncStream.swift:80-89`
- **What**: `Task { await operation(channel); channel.finish() }` — the returned channel has no `onTermination` analogue, and the task is not stored/cancelled if the caller breaks out of iteration early. (Compare `TaskBackedAsyncStream.makeStream` 32-46 which correctly hooks `continuation.onTermination`.)
- **Why**: The docstring promises "producer task cancelled when iteration terminates" but nothing wires that up. If a consumer `breaks` mid-stream, the producer can keep running until it tries to send on a finished channel.
- **Recommendation**: Return both the channel and a cancellation handle, or wrap in a type that finishes the channel from a `deinit`. Alternatively use `AsyncStream<Element>` with `.bufferingPolicy(.unbounded)` and rely on `onTermination`.

#### Medium: `TaskCooperation.checkpoint` always yields even when not cancelled
- **File**: `Sources/SwiftStaticAnalysisCore/Concurrency/TaskBackedAsyncStream.swift:102-116`
- **What**: On the cadence boundary the function calls `await Task.yield()` unconditionally.
- **Why**: That is the design, but the second `Task.isCancelled` check after the yield can return a stale "true" if cancellation arrives during the yield. The pattern is fine; what is missing is documentation that `checkpoint` consumes a suspension point even on the happy path (callers in tight CPU-bound loops will pay a context-switch cost every 256 iterations).
- **Recommendation**: Either keep this and document the cost, or short-circuit `Task.isCancelled` *before* yielding. The current order is already correct, but consider exposing a `yieldEvery: Int?` to make the cost configurable.

#### Medium: `ParallelVerification.verifyCandidatePairs` chunks once but doesn't pipeline
- **File**: `Sources/DuplicationDetector/Parallel/ParallelVerification.swift:74-89`
- **What**: One `withTaskGroup`, `chunks(ofCount: pairs.count / maxConcurrency)` — better than `ParallelProcessor.map` (no inter-chunk barrier) but each task processes its slice sequentially.
- **Why**: For a workload of N pairs with `maxConcurrency=8`, exactly 8 tasks are spawned of size N/8 each. If pair-cost is skewed, some cores idle while one task finishes a slow tail.
- **Recommendation**: Increase task granularity (e.g., chunk size = `max(64, pairs.count / (maxConcurrency * 8))`), or steal-style: smaller chunks, more tasks, let `TaskGroup` schedule.

#### Medium: `Bitmap.testAndSet` is non-atomic but called from `bottomUpStep`'s parallel TaskGroup via `frontierBitmap`
- **File**: `Sources/SwiftStaticAnalysisCore/Concurrency/Bitmap.swift:251-257`, callsite `Sources/UnusedCodeDetector/Reachability/ParallelBFS.swift:306, 337`
- **What**: `frontierBitmap` (the *non-atomic* `Bitmap`) is constructed once in the parent (line 306) and then **read** from many concurrent tasks (line 337 `frontierBitmap.test(predecessor)`). The author notes this in the comment ("only written here (single-threaded init) and only read during parallel phase").
- **Why**: The reasoning is sound — `let storage = [UInt64]` is read-only after init, concurrent reads on `Array` are safe. But `Bitmap` is a value type, and the closure captures it by value — each task gets its own copy. This is wasteful (a full byte copy of the frontier per task) but not unsafe. Worth verifying with `print(MemoryLayout)` and either making `Bitmap` reference-typed for shared reads or using a `Span<UInt64>` (Swift 6.2) for zero-copy borrowing.
- **Recommendation**: Promote `Bitmap` to a reference type behind `let` for parallel readers, or pass via `withUnsafePointer` so it's borrowed not copied. See "Native API opportunities" — `BitArray` from swift-collections would replace both.

#### Low: `MemoryMappedFile.findLineRanges` `Mutex` could be a `OnceLock`/`@LazyAtomic`
- **File**: `Sources/SwiftStaticAnalysisCore/Memory/MemoryMappedFile.swift:241-262`
- **What**: A `Mutex<[(Int, Int)]?>` is used to lazily compute and cache line ranges.
- **Why**: Read-mostly after first call. Every read takes the mutex.
- **Recommendation**: With Swift 6.2 you can use `Atomic<UnsafeRawPointer?>`-backed double-checked init, or fall back on a `Mutex` only for the compute path (read the cache via an `Atomic` flag first). For a CLI tool this is a micro-optimisation; flag as Low.

#### Low: `IndexBasedDependencyGraph` uses a single coarse `Mutex(())` (sentinel value)
- **File**: `Sources/UnusedCodeDetector/IndexStore/IndexBasedDependencyGraph.swift:321`
- **What**: `private let lock = Mutex(())` and every public accessor wraps `lock.withLock { _ in ... }`.
- **Why**: This is mutex-as-monitor — fine, but it serialises every concurrent reader (e.g., `nodeCount`, `edgeCount`, `rootNodes`) against any writer. For a read-heavy graph this is the wrong shape.
- **Recommendation**: Split state into `Mutex<Storage>` for the build phase and an *immutable, Sendable snapshot* (`final class GraphSnapshot: Sendable { let nodes, edges, ...; }`) returned by `build()`. After build, callers query the snapshot lock-free. The current `@unchecked Sendable` + mutex pattern is justified per the docstring, but the docstring's reason ("IndexStoreDB closures capture self") only applies during `build`; reads don't need it.

#### Low: `ThreadLocalArena.currentBox` allocates+TLS-stores but returns local on miss
- **File**: `Sources/SwiftStaticAnalysisCore/Memory/Arena.swift:403-411`
- **What**: On TLS miss, allocates a new `ArenaBox`, calls `pthread_setspecific(tlsKey, Unmanaged.passRetained(box).toOpaque())`, then returns `box`. The retain count is balanced by the pthread destructor.
- **Why**: Correct but subtle. `passRetained` and the pthread destructor's `release()` must be paired; if a thread sets a new box without going through this getter (impossible in this codebase, but a future contributor could call `pthread_setspecific` directly), a leak or double-release happens.
- **Recommendation**: Wrap pthread access in a helper that enforces the contract, or — better — use Swift's `@TaskLocal` for per-task arenas. For the few places that need true OS-thread locality, the existing impl is fine; add a `#warning` if the public API tempts use beyond its intent.

### Native API / stdlib adoption

#### High: Hand-rolled `Bitmap`/`AtomicBitmap` duplicates `swift-collections` `BitArray`
- **File**: `Sources/SwiftStaticAnalysisCore/Concurrency/Bitmap.swift` (entire file, 298 lines)
- **What**: `Bitmap` reimplements `BitArray` (from `Collections.BitCollections`). `AtomicBitmap` is unique to this project because `BitArray` isn't atomic, but the non-atomic `Bitmap` is pure duplication.
- **Why**: `BitArray` is the canonical type, has more careful iteration (efficient `firstIndex(of: true)`, range operations, `count(of:)`), supports `RandomAccessCollection`, and is maintained upstream.
- **Recommendation**: Delete `Bitmap` and use `BitArray` for the non-atomic case. Keep `AtomicBitmap` (no stdlib equivalent yet — proposal SE-???/0410 etc. still pending) but rename the `Bitmap`-using callsites.

#### High: `Synchronization.Atomic` "single-word-in-Array" hack `AtomicWord`
- **File**: `Sources/SwiftStaticAnalysisCore/Concurrency/Bitmap.swift:16-22`
- **What**: A `final class AtomicWord` wraps `Atomic<UInt64>` because `Atomic` is `~Copyable` and can't sit in an `Array`.
- **Why**: This is correct, but `Atomic` is `~Copyable`, so each word allocates a separate heap object — for a 1M-bit bitmap that's ~16k heap allocations.
- **Recommendation**: Allocate one `UnsafeMutableBufferPointer<UInt64>` and atomic-access via `_Atomic<UInt64>.atomicLoad(at:ordering:)` (raw atomic ops on word offsets); see `Synchronization` module's `UnsafeAtomic` if/when it lands. Until then, document the per-word allocation cost. Alternative: a single `Atomic<UInt64>` flat-byte buffer keyed by index via `Atomic.byteWiseLoad` — Swift 6.2 doesn't ship this, but a `ManagedBuffer<Void, UInt64>` plus `Atomic.load(rawAddress:)` would halve the allocations.

#### High: `RawSpan(_unsafeBytes:)` uses an underscored, non-public API
- **File**: `Sources/SwiftStaticAnalysisCore/Memory/MemoryMappedFile.swift:166, 414`
- **What**: `RawSpan(_unsafeBytes: buffer)` — note the leading underscore.
- **Why**: Underscored Swift APIs are not source-stable. SE-0447 (`Span`) and SE-0456 (`RawSpan`) define `RawSpan` with `init(_unsafeBytes:)` as the underscored-stability-ABI form; the public initialiser may differ. Building against future toolchains may break.
- **Recommendation**: Track [SE-0447](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md) / [SE-0456](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0456-stop-accepting-unsafe-pointer-as-sendable.md) for the de-underscored form. Currently swift 6.2 still ships only the underscored init for raw bytes; gate behind `#if compiler(>=6.3)` for the stable name once it lands.

#### Medium: Hand-rolled SoA storage when `Span<T>` would suffice
- **File**: `Sources/SwiftStaticAnalysisCore/Memory/SoATokenStorage.swift:74-263` (`SoATokenStorage`) and `:282-359` (`ArenaTokenStorage`)
- **What**: Two storage layouts: one for append/iteration (`SoATokenStorage`), one for zero-copy borrowed access (`ArenaTokenStorage` with raw `UnsafeBufferPointer`).
- **Why**: `ArenaTokenStorage` is `@unchecked Sendable` because of `UnsafeBufferPointer`. With Swift 6.2 `Span<T>` (and `~Escapable`) the lifetime is enforced by the compiler — you can drop `@unchecked Sendable` entirely.
- **Recommendation**: Replace `kinds: UnsafeBufferPointer<UInt8>` with `kinds: Span<UInt8>` (and similar for others). The struct becomes `~Escapable`/`~Copyable` rather than `@unchecked Sendable`. Callers will need adjustment but get safety from the compiler.

#### Medium: `[UInt8]` byte arrays passed where `Span<UInt8>` would prevent copies
- **File**: `Sources/SwiftStaticAnalysisCore/Memory/MemoryMappedFile.swift:201-216` (subscript range), `:389-395` (`asBytes()`)
- **What**: `subscript(range: Range<Int>) -> [UInt8]` and `asBytes() -> [UInt8]` allocate fresh byte arrays.
- **Why**: When the caller only needs a window into the mapped file, returning a `Span<UInt8>` would be zero-copy and safe (the parent `FileSlice` retains the mapping).
- **Recommendation**: Add `borrowing func bytes() -> Span<UInt8>` returning a span of the mapped region. Keep `asBytes()` for legacy callers that genuinely need an owned array.

#### Medium: `Foundation` import everywhere; no `FoundationEssentials`
- **File**: ~98 `import Foundation` sites across `Sources/`
- **What**: Every target imports `Foundation`. `FoundationEssentials` (the slimmer cross-platform subset that lives in swift-foundation) is never imported.
- **Why**: The MCP server and CLI need `URL`, `JSONEncoder`, `FileManager`, `ProcessInfo`, `Date` — all `FoundationEssentials`. Heavy bits (`NSObject`, `Bundle`, `NotificationCenter`) are not used. On Linux/musl/Swift-on-Server, swapping `Foundation` for `FoundationEssentials` cuts a real amount of code size and avoids the ICU dependency.
- **Recommendation**: In `SwiftStaticAnalysisCore`/`Memory`/`Utilities` files that only need `URL`/`JSON`/`FileManager`, switch to `import FoundationEssentials` guarded by `#if canImport(FoundationEssentials)`. Keep `import Foundation` where `NSString`/`pathExtension`/regex bridging is required. Even a partial migration helps Linux portability and CI cold-start.

#### Medium: Paths everywhere as `String`; never `URL.FilePath` or `System.FilePath`
- **File**: pervasive — every public API takes `path: String`. See e.g. `MemoryMappedFile.init(path: String, ...)`, `ZeroCopyParser.parse(_:String)`, `SourceFileReader.readSource(at: String, ...)`, the entire CLI, MCP, IndexStore layer.
- **What**: `String` is used to model filesystem paths.
- **Why**: `String` does not enforce path-ness, doesn't carry separator awareness, and loses information about absolute-vs-relative. Apple's `FilePath` from `System` (or `swift-system`) is `Sendable`, expresses path operations natively, and avoids `URL`'s overhead.
- **Recommendation**: Introduce `import System` (already present transitively) and add `FilePath`-accepting overloads at the public layer. Internal call sites can keep `String` for performance, but the API boundary should favour `FilePath`. For URL-string conversion at the boundary, prefer `URL(filePath: String, directoryHint:)` (iOS 16+/macOS 13+) over `URL(fileURLWithPath:)`.

#### Medium: `ObjCBool` smuggled in via `FileManager.fileExists(atPath:isDirectory:)`
- **File**: `Sources/swa/SWA.swift:707, 1093`; `Sources/SwiftStaticAnalysisMCP/CodebaseContext.swift:34`; `Sources/SwiftStaticAnalysisMCP/SWAMCPServer.swift:1118`.
- **What**: Four call sites use the inout `ObjCBool` overload.
- **Why**: `ObjCBool` is an `objc_msgSend`-era bridge. The cleaner Swift API is `URL.resourceValues(forKeys: [.isDirectoryKey])`, or `URL.isDirectory` on macOS 13+.
- **Recommendation**: Replace with `(try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false`. The performance is comparable and the call site is honest about Foundation usage.

#### Medium: `RegexCache` "LRU" eviction is undefined behaviour
- **File**: `Sources/SwiftStaticAnalysisCore/Utilities/RegexCache.swift:52-56`
- **What**: `if storage.cache.count >= capacity, let firstKey = storage.cache.keys.first { storage.cache.removeValue(forKey: firstKey) }`.
- **Why**: `Dictionary.keys.first` has *unspecified* order. The "first key" is whatever the hash table happens to expose — eviction picks a random entry. The class is called `RegexCache` and is documented as a cache, but the eviction policy isn't actually LRU.
- **Recommendation**: Use `OrderedDictionary` (already a dependency, used elsewhere in this codebase) and `removeFirst()` for true insertion-order eviction. Or rename to "bounded cache with unspecified eviction" if that's deliberate.

#### Medium: `chunks(ofCount:)` cycles are good — but `compactMap` + `compacted()` is a smell
- **File**: `Sources/SwiftStaticAnalysisCore/Concurrency/ConcurrencyConfiguration.swift:117`, `Sources/DuplicationDetector/Parallel/ParallelMinHash.swift:78, 116, 228`
- **What**: `Array(allResults.compacted())` is used to filter `Optional` from arrays. `compactMap { $0 }` (or `.compacted()`) is fine, but in `ConcurrencyConfiguration.swift:117` it's after fully populating `allResults: [R?]` — those nils *can never exist* because the task group has already written every slot before that line. The `compacted` is dead code that obscures a logic invariant.
- **Recommendation**: Build `[(Int, R)]` (no Optional) and sort. Or use a `Result<R, Error>?` and unwrap at the end with a type-level guarantee.

#### Low: `parseAll` is sequential despite its plural name
- **File**: `Sources/SwiftStaticAnalysisCore/Memory/ZeroCopyParser.swift:197-204`
- **What**: `public func parseAll(_ paths: [String]) async throws -> [ZeroCopyParsedFile]` loops `parse(path)` serially.
- **Why**: The neighbouring `BatchTokenExtractor.extractParallel` does the right thing. Two functions in the same file have wildly different concurrency semantics. A caller who reads "parseAll" expects parallelism.
- **Recommendation**: Either rename to `parseSequentially` or change the body to use the same streaming TaskGroup as `extractParallel`. Cache contention is fine — the actor serialises `parse()` anyway.

### Memory / data structures

#### High: `SoATokenStorage.append(length: Int)` silently truncates oversized tokens
- **File**: `Sources/SwiftStaticAnalysisCore/Memory/SoATokenStorage.swift:155-170`
- **What**: `length: UInt16(min(length, Int(UInt16.max)))` — same for `column`.
- **Why**: A token longer than 65535 bytes (rare, but possible — large string literals, multi-line raw strings) silently records a wrong length. Downstream code (`text(at:)`, clone detection, snippet extraction) will read a truncated window and the analysis becomes incorrect *without warning*.
- **Recommendation**: Either widen to `UInt32` (4 extra bytes/token — 4×N more memory but no truncation), or `precondition(length <= UInt16.max, ...)` to fail loudly. Same for `column` (`UInt16` is fine for Swift source columns in practice, but use `precondition` not `min`).

#### Medium: `MultiFileSoAStorage.totalTokenCount` is a leaky abstraction
- **File**: `Sources/SwiftStaticAnalysisCore/Memory/SoATokenStorage.swift:385-387`
- **What**: `storage.count - files.count` to subtract the file-boundary sentinels.
- **Why**: Hidden invariant: every `addFile` call appends exactly one sentinel. If a caller calls `addFile(...)` with an *empty* token storage, the subtraction is still correct, but only by coincidence. Worse: the sentinel kind is `255` and shares the same `[UInt8]` lane as real tokens — any code that iterates `kinds` and decodes via `TokenKindByte(rawValue:)` will see `255` and resolve to `unknown`-via-default, which is fine for analysis but confusing for debugging.
- **Recommendation**: Either keep a separate `boundaries: [Int]` array (no in-band sentinels) or document the invariant explicitly and add a `#if DEBUG` assertion that `files.count` matches the sentinel count in `storage.kinds`.

#### Medium: `ZeroCopyParsedFile.snippet` has unreachable `?? ""` on String coalesce
- **File**: `Sources/SwiftStaticAnalysisCore/Memory/ZeroCopyParser.swift:117`
- **What**: `return String(source.utf8[startIdx..<endIdx]) ?? ""`
- **Why**: `String(_:Substring.UTF8View)` returns a non-optional `String`. The `?? ""` is dead — likely a warning suppressed somewhere, more likely silently accepted. The pattern misleads readers about possible failure modes.
- **Recommendation**: Drop the coalesce. (Verify by compiling with `-warnings-as-errors` — the build setting is on per the README; either Swift's warning is gone in 6.2 or this is being silenced.)

#### Medium: `Arena.allocate(count:)` ignores the configured `alignment` when count is typed
- **File**: `Sources/SwiftStaticAnalysisCore/Memory/Arena.swift:188-194`
- **What**: Uses `MemoryLayout<T>.alignment`, which is correct for `T`, but the *configured* `arenaBlockSize` is fixed at 64KB and the alignment is allocator-wide. For mixed `T`s with different alignments, this is fine; the comment "Arena alignment must be a positive power of two" applies to the configuration's *block* alignment, not the per-allocation alignment.
- **Why**: Minor — code works correctly, but `ArenaConfiguration.alignment` is exposed publicly and looks like a per-allocation control. It isn't.
- **Recommendation**: Rename `ArenaConfiguration.alignment` to `defaultAllocationAlignment` and document that per-`T` `allocate(count:)` uses `MemoryLayout<T>.alignment` regardless. Or remove the field — it isn't read anywhere in `allocate(size:alignment:)` (line 161 takes its alignment from the argument, default 8).

#### Low: `Arena.copy(_:)` doesn't preserve the source array's count under empty input
- **File**: `Sources/SwiftStaticAnalysisCore/Memory/Arena.swift:218-225`
- **What**: `let buffer = allocate(count: array.count)` then `update(from: src, count: array.count)`.
- **Why**: For `array.count == 0`, this allocates a zero-length buffer. `UnsafeMutableBufferPointer(start: nil, count: 0)` is the canonical empty form. Verify the `allocate` path handles size==0 (line 161: yes — allocates `max(blockSize, 0 + 8)`, wastes a block of 64KB).
- **Recommendation**: Early-return on empty array. Avoids a wasted block.

### Visitors / SwiftSyntax

#### Low: Visitors store `[Declaration]`/`[Reference]` referring to `SourceLocation`s but not raw syntax nodes
- **File**: `Sources/SwiftStaticAnalysisCore/Visitors/DeclarationCollector.swift`, `ReferenceCollector.swift`
- **What**: Declarations capture `name: String`, `location: SourceLocation`, `range: SourceLocation`, etc. — all owned types. No `let node: FunctionDeclSyntax` is retained.
- **Why**: This is *the right thing*. SwiftSyntax nodes are arena-allocated (their `SyntaxArena` lives in the `SourceFileSyntax` root). Holding a `FunctionDeclSyntax` past the parse retains the whole tree.
- **Recommendation**: Keep doing what you're doing. Add a documented "Lifetime contract" note to the public Declaration/Reference types so future contributors don't add a `node:` field.

#### Low: `ScopeTrackingVisitor.init(file:tree:)` takes a `SourceFileSyntax` but doesn't keep it
- **File**: `Sources/SwiftStaticAnalysisCore/Utilities/ScopeTracker.swift:105-110`
- **What**: Constructs a `SourceLocationConverter(fileName: file, tree: tree)` which captures `tree`.
- **Why**: `SourceLocationConverter` holds a reference to the `SourceFileSyntax` (and therefore the whole `SyntaxArena`). For the duration of the visitor — usually the duration of a single parse pass — that's fine and probably desired. But if visitors are kept around longer than the parse (e.g., cached for incremental analysis), this prevents the tree from being freed.
- **Recommendation**: Document that `ScopeTrackingVisitor` instances should be short-lived and discarded after `walk(_:)` completes. Add an `@available` note if Swift 6.2 surfaces lifetime warnings.

### IndexStoreDB

#### Strength (verified): N+1 fix is in place
- **File**: `Sources/UnusedCodeDetector/IndexStore/IndexStoreReader.swift:416-435` (`allOccurrencesByUSR(in:)`), called by `IndexStoreAnalyzer.analyzeUsage()` `Sources/UnusedCodeDetector/IndexStore/IndexStoreAnalyzer.swift:85-110`.
- The implementation correctly sweeps files once (`db.symbolOccurrences(inFilePath:)`) and groups locally instead of `findOccurrences(ofUSR:)` per definition. Comment block accurately describes the previous behaviour and the fix.

#### Medium: `IndexStoreReader.allDefinedSymbols`/`allDefinitions` use empty-string sentinel queries
- **File**: `Sources/UnusedCodeDetector/IndexStore/IndexStoreReader.swift:367-390, 437-466`
- **What**: `db.forEachCanonicalSymbolOccurrence(containing: "", anchorStart: false, anchorEnd: false, ...)` — leverages "" as "match anything".
- **Why**: Relies on an undocumented IndexStoreDB behaviour that empty `containing` matches every symbol. If a future IndexStoreDB release tightens this to "match nothing" (more sensible), the analyser silently returns no definitions.
- **Recommendation**: Pin the IndexStoreDB revision (already done in `Package.swift` line 90) and add an integration test asserting the empty-string behaviour. Long-term, ask upstream for an explicit `forEachSymbol` API.

#### Low: `IndexStorePathFinder.dirMatchesProject` does a `dir.contains(projectName)` fallback
- **File**: `Sources/UnusedCodeDetector/IndexStore/IndexStoreReader.swift:625-658`
- **What**: After exact/normalized/URL-encoded checks, falls back to substring match.
- **Why**: For a project named `Foo`, this matches `FooBar-deadbeef`, `MyFoo-xxx`, etc. — false positives that point the analyser at the wrong DerivedData.
- **Recommendation**: Either drop the substring fallback or constrain it to anchored prefix match (`dir.hasPrefix(projectName + "-")`).

### CLI

#### Medium: `SWA.swift` at 1152 LOC mixes commands, formatting, and filesystem walking
- **File**: `Sources/swa/SWA.swift`
- **What**: Four `AsyncParsableCommand` types (`Analyze`, `Duplicates`, `Unused`, `Symbol`) plus `OutputFormatter` plus `findSwiftFiles` plus `canonicalizePath` plus exclusion logic plus filter logic all live in one file.
- **Why**: Maintenance friction. The `// swiftlint:disable:next function_body_length` annotation on `Unused.run()` (line 328) is a tell — the file is at the size where reviewers stop reading.
- **Recommendation**: Split each command into its own file (`Sources/swa/Commands/Analyze.swift`, etc.). Move `OutputFormatter` into `SwiftStaticAnalysisOutput`. Move `findSwiftFiles` into `Sources/SwiftStaticAnalysisCore/Utilities/SwiftFileEnumerator.swift` and unit-test it.

#### Medium: `--parallel` flag is documented "deprecated" but not actually `@available(*, deprecated)`
- **File**: `Sources/swa/SWA.swift:167-168, 322-323`
- **What**: Two `@Flag` declarations: `var parallel: Bool = false` with help text saying "deprecated: use --parallel-mode".
- **Why**: A deprecation that isn't enforced is a permanent feature. Users keep using it; the codebase keeps the resolution logic.
- **Recommendation**: Either remove (with a CHANGELOG note) or emit a runtime warning to stderr when `parallel` is true and `parallelMode` is nil: `eprint("warning: --parallel is deprecated; use --parallel-mode {none,safe,maximum}")`.

#### Medium: `Symbol.run()` chains `try await finder.findUsages(of: match)` per match
- **File**: `Sources/swa/SWA.swift:585-591`
- **What**: `for match in matches { let occurrences = try await finder.findUsages(of: match); ... }`
- **Why**: Sequential awaits in a CLI command for what could be parallel index queries.
- **Recommendation**: Replace with a `withThrowingTaskGroup` that fans out and collects, capped at `ProcessInfo.processInfo.activeProcessorCount`.

#### Medium: Three separate code paths converge on `findSwiftFiles` — defaults aren't shared
- **File**: `Sources/swa/SWA.swift:1084-1151`
- **What**: `defaultExcludedDirectories` lives in `swa`; identical logic likely exists elsewhere.
- **Why**: Tested via CLI tests only — library consumers reimplement the wheel.
- **Recommendation**: Move `defaultExcludedDirectories` and `findSwiftFiles` into `SwiftStaticAnalysisCore` so they're reusable from the MCP server and library callers.

#### Low: `CLIConformances.swift` retroactive conformances on public enums work but are subtle
- **File**: `Sources/swa/CLIConformances.swift:17-24`
- **What**: `extension DeclarationKind: ExpressibleByArgument {}` (etc.) — same-package conformances, no `@retroactive` needed (and code correctly avoids it).
- **Why**: Correct and idiomatic. The risk is that future *consumers* of `SwiftStaticAnalysisCore` who also build a CLI on top will need to redefine these conformances, but `swa` "owns" them via being in the same package.
- **Recommendation**: Consider whether `ExpressibleByArgument` should be a public protocol-level extension in `SwiftStaticAnalysisCore` itself (gated behind `#if canImport(ArgumentParser)`) so external CLI authors get them for free.

#### Low: `outputXcode` for usages says `warning:` — fine for CI, surprising in interactive use
- **File**: `Sources/swa/SWA.swift:678-683`
- **What**: Emits `warning: Reference (...)`.
- **Why**: This is intentional per the comment, and the right call for CI gating, but a query like `swa symbol Foo --usages` now puts the user's terminal full of yellow warning glyphs.
- **Recommendation**: Document this behaviour in the help text for `--format xcode` so it's not a surprise.

### Footguns

#### Strength: No `try!`, no `as!`, no force-unwraps in `Sources/`
- Verified via `grep -rEn 'try!|as!|!=|![[:space:]]' Sources/`. The two `fatalError`s in `Arena` are documented "should-not-happen" paths in a noncopyable allocator. The `.swift-format` rules `NeverForceUnwrap`/`NeverUseForceTry` are effectively enforced.

#### Strength: Typed throws everywhere
- `MemoryMappedFile.init throws(MemoryMappedFileError)`, `IndexStoreReader.init throws(IndexStoreError)`, etc. Excellent — Swift 6.2 typed-throws adoption is rare and done well here.

#### Low: `@unchecked Sendable` justifications are present but verbose
- Every `@unchecked Sendable` declaration carries a long rationale in its docstring. Good practice. The risk: rationales drift from code over time. Add a `#if DEBUG` invariant for each (e.g., for `MemoryMappedFile`, a sanity check that all stored properties are `let` — at runtime, just `precondition`s on the relevant fields).

#### Low: Unstructured `Task { ... }` in `BackpressuredChannelStream.makeChannel`
- Already covered above. The only other unstructured-`Task` spawn (`TaskBackedAsyncStream.makeStream`) is correctly tied to `continuation.onTermination`. Audit `grep -rn '^\s*Task {' Sources/` returns only these two sites.

### Naming / API Design

#### Low: `BackpressuredChannelStream.makeChannel` returns an `AsyncChannel`, not a "stream"
- **File**: `Sources/SwiftStaticAnalysisCore/Concurrency/TaskBackedAsyncStream.swift:69-89`
- **What**: The enum is called `BackpressuredChannelStream` and its only method is `makeChannel(operation:) -> AsyncChannel<Element>`.
- **Why**: `Stream` suggests `AsyncStream`. The factory returns the channel directly. Mild Apple-API-Design-Guidelines violation: the type and method names don't agree on what's being made.
- **Recommendation**: Rename to `BackpressuredChannel.make(operation:)` or `AsyncChannel.makeWithProducer(...)` as a static method extension.

#### Low: `ParallelProcessor.map(_:maxConcurrency:operation:)` returns "results in same order as input" but `compactMap` doesn't
- **File**: `Sources/SwiftStaticAnalysisCore/Concurrency/ConcurrencyConfiguration.swift:71, 127`
- **What**: `map` docstring promises ordered output; `compactMap` says "order not guaranteed".
- **Why**: Inconsistent contract — callers must remember which is which.
- **Recommendation**: Either make both ordered (the cost is small — indexed results, sort once) or rename `compactMap` to `parallelCompactMap` and document loudly.

#### Low: `Bitmap.testAndSet` returns "true if previously unset" — the opposite of `AtomicBitmap.testAndSet` semantics is asserted but easy to misread
- **File**: `Sources/SwiftStaticAnalysisCore/Concurrency/Bitmap.swift:63-75, 251-257`
- Both return "true if previously unset". Consistent. Good. Only a nit: the verb-name `testAndSet` is the inverse of CAS conventions in some other languages (Java/C# `compareAndSet` returns "true if exchanged"). Either is defensible; document at the protocol level.

#### Nit: `Arena.allocate(count:)` returning `UnsafeMutableBufferPointer<T>` but `Arena.copy(_:)` returns the same
- **File**: `Arena.swift:188, 218`
- Both return `UnsafeMutableBufferPointer<T>` — fine; consistent.

### Tests

#### Strength: 100% Swift Testing
- Every test uses `@Test`, `@Suite`, `#expect`. No XCTest holdovers. Tag system (`TestTags.swift`) is defined.

#### High: Zero parameterised tests despite the natural fit
- **File**: every `*Tests.swift`
- **What**: `grep -rEn '@Test.*arguments:' Tests/` returns nothing.
- **Why**: Tests like `MinHashSIMDEquivalenceTests`, `LCPCorrectnessTests`, `SAISCorrectnessTests`, `LSHIndexTests` (and many more) test invariants over multiple inputs. Each variation is currently a separate `@Test`. Swift Testing's parameterised form (`@Test(arguments: [(50, 0.5), (100, 0.8), ...])`) would shrink the test file by a factor and surface failure variants distinctly.
- **Recommendation**: Convert at least the SIMD-equivalence, hashing, and clone-detection threshold-sweep tests to parameterised form. Start with `MinHashSIMDEquivalenceTests.swift` — it likely already loops manually.

#### Medium: Tags are defined but only used in 5 suites
- **File**: `Tests/SwiftStaticAnalysisCoreTests/TestTags.swift` defines 15 tags; `grep -rn '\.tags(' Tests/` finds 5 sites.
- **Recommendation**: Either apply tags broadly (especially `.slow`, `.integration`, `.concurrency`) so CI can selectively run subsets, or remove the unused tag definitions.

#### Low: No `.disabled(...)` or `.bug(...)` traits visible
- Not necessarily a problem, but consider using `.bug("URL")` to link tests to issues for incoming regressions.

## Native API / Swift-package opportunities (concrete swaps)

| Replace | With | Where | Rationale |
|---|---|---|---|
| Hand-rolled `Bitmap` | `Collections.BitArray` | `Sources/SwiftStaticAnalysisCore/Concurrency/Bitmap.swift` and consumers | Already depend on `swift-collections`. `BitArray` is `RandomAccessCollection`, `Sendable`, has efficient `count(of:)`. Keep `AtomicBitmap` (no stdlib equivalent). |
| `[AtomicWord]` array-of-classes for atomic bitmap | Single `ManagedBuffer<Void, UInt64>` + atomic-on-offset | `AtomicBitmap` in same file | 1 allocation vs N. Lower cache pressure. Until stdlib `UnsafeAtomic` lands, alternative is a `Mutex<[UInt64]>` for the rare-write case. |
| `UnsafeBufferPointer<UInt8>` in `ArenaTokenStorage` | `Span<UInt8>` (Swift 6.2) | `Sources/SwiftStaticAnalysisCore/Memory/SoATokenStorage.swift:282-359` | Compiler-enforced lifetime, drop `@unchecked Sendable`. |
| `[UInt8]` return from `FileSlice.asBytes()`/`subscript` | `Span<UInt8>` borrow | `MemoryMappedFile.swift:201-216, 389-395` | Zero-copy windows into mapped pages. |
| `URL(fileURLWithPath:)` | `URL(filePath: ..., directoryHint:)` | CLI, MCP, IndexStorePathFinder | macOS 13+ canonical form, avoids string-bridge cost. |
| `String` paths at API boundary | `System.FilePath` | Public APIs of `MemoryMappedFile`, `ZeroCopyParser`, etc. | Type-safe path manipulation. |
| `Foundation` everywhere | `FoundationEssentials` where possible | `SwiftStaticAnalysisCore` (most files), `Memory/`, `Utilities/` | Cuts binary size, Linux-friendly. Guard with `#if canImport(FoundationEssentials)`. |
| `FileManager.fileExists(atPath:isDirectory:)` with `ObjCBool` | `URL.resourceValues(forKeys: [.isDirectoryKey])` | `SWA.swift:707, 1093`; `SWAMCPServer.swift:1118`; `CodebaseContext.swift:34` | Drops `ObjCBool` bridge. |
| `Dictionary.keys.first` "LRU" | `OrderedDictionary.removeFirst()` | `RegexCache.swift:52-56` | Defined eviction order. |
| `Array(allResults.compacted())` post-fill from indexed task group | Build `[R]` directly, no Optional | `ConcurrencyConfiguration.swift:117`; `ParallelMinHash.swift:78, 116, 228` | Dead `compacted` call, misleading code. |
| `RawSpan(_unsafeBytes:)` underscored init | Tracked SE-0447/SE-0456 stable initialiser | `MemoryMappedFile.swift:166, 414` | Underscored API is not source-stable. Gate with `#if compiler(>=6.3)` when available. |
| Per-document `group.addTask` without cap | Bounded-`inFlight` streaming TaskGroup (see `ZeroCopyParser.extractParallel:437-467`) | `ParallelMinHash.computeSignatures`; `ParallelProcessor.map/compactMap/forEach` | Honours `maxConcurrency`; avoids scheduler thrash. |
| Sequential `parseAll` | `extractParallel`-style streaming TaskGroup | `ZeroCopyParser.parseAll:197-204` | Name promises parallel; implementation is sequential. |
| `nonisolated(unsafe) let xRegex = Regex { ... }` | Same, but document a clear migration plan | `RegexPatterns.swift`, `ClosureNormalizer.swift`, `SWAMCPServer.swift:833` | Current state is required (Regex isn't yet Sendable); add a tracking issue and revisit each release. |
| `chunks(ofCount:)` then await all-then-next-chunk | Single TaskGroup with finer-grained chunks | `ParallelProcessor.map`, `ParallelMinHash.computeSignaturesChunked` | Removes inter-chunk barriers. |
| `@TaskLocal Arena` via pthread TLS | `@TaskLocal var arena: ArenaBox` | `ThreadLocalArena` in `Arena.swift:384-422` | Structured-concurrency-native; works inside `withTaskGroup` without pthread fiddling. |

## Strengths

1. **Strict Swift 6 concurrency posture is real, not aspirational.** All targets enable `.swiftLanguageMode(.v6)` and `enableExperimentalFeature("StrictConcurrency")`. The code lives with the consequences (typed errors, `Sendable` everywhere, `Mutex` not `DispatchQueue`).
2. **Zero force-unwraps, zero `try!`, zero `as!` in `Sources/`.** This is exceptional for a 6k-line+ codebase. The `.swift-format` rules (`NeverForceUnwrap`, `NeverUseForceTry`) are demonstrably enforced.
3. **Typed throws used pervasively.** `throws(MemoryMappedFileError)`, `throws(IndexStoreError)` etc. Swift 6.2's marquee error-handling feature is exercised — not common in the wild.
4. **`Synchronization` migration is complete.** No `DispatchQueue`, `NSLock`, or `os_unfair_lock` in production code; `Mutex` and `Atomic<UInt64>` are used uniformly. swift-atomics dropped per CHANGELOG.
5. **N+1 fix verified.** `IndexStoreReader.allOccurrencesByUSR(in:)` is correctly file-sweep-then-group, with a clear comment explaining the previous O(definitions × occurrences) cost.
6. **`Span`/`RawSpan` adoption is meaningful.** `MemoryMappedFile.withRawSpan` returns lifetime-bounded views; `~Escapable` is leaned on.
7. **`SyntaxArena` lifetime hygiene.** Visitors capture Strings and SourceLocations, not syntax nodes — the AST can be released after each parse.
8. **`Sendable` discipline.** Every `@unchecked Sendable` carries written justification. None look accidental.
9. **Direction-optimising parallel BFS (Beamer et al.).** `Sources/UnusedCodeDetector/Reachability/ParallelBFS.swift` is real engineering — α/β heuristic, top-down/bottom-up switching, `AtomicBitmap` visited, dense graph projection.
10. **Mersenne-61 SIMD MinHash.** `Sources/DuplicationDetector/MinHash/MinHash.swift:166-251` is a clean SIMD4 implementation with documented bit-equivalence to the scalar reference.
11. **swift-async-algorithms `AsyncChannel` for genuine backpressure.** `BackpressuredChannelStream` is the right tool over `AsyncStream.bufferingNewest` — and the docstring honestly explains the trade-off.
12. **`OrderedDictionary` LRU caches** in `ZeroCopyParser` and `SwiftFileParser` are correct (in contrast to the buggy `RegexCache`).
13. **swift-algorithms idiomatic use.** `chunks(ofCount:)`, `combinations(ofCount: 2)`, `compacted()`, `indexed()` are all over the place.
14. **`RegexBuilder`** consistently preferred over string-pattern regex; cached compiled forms via `nonisolated(unsafe) let`.
15. **`@AsyncParsableCommand` + `ExpressibleByArgument` on domain enums.** CLI is idiomatic — subcommands, `validate()` for input bounds, `ExitCode(2)` for "findings exist".
16. **Test target separation per library.** Mirrors source layout; encourages module-level testing.
17. **DocC adoption.** Articles directory in `Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/Articles/`.
18. **`Arena.withScope`** — RAII-style nested-arena pattern with proper offset rollback in `defer`.

## Top 10 actionable improvements (ranked by impact/effort)

1. **Fix `ParallelMinHashGenerator.computeSignatures` and `ParallelProcessor.map` to honour `maxConcurrency`.** Replace per-item `group.addTask` with the bounded-`inFlight` streaming pattern from `ZeroCopyParser.extractParallel`. Single biggest correctness/perf risk in the parallel layer. (`ParallelMinHash.swift:56-80`, `ConcurrencyConfiguration.swift:71-184`)

2. **Replace silent `UInt16` truncation in `SoATokenStorage.append` with `precondition` (or widen to `UInt32`).** A 65536-byte string literal produces incorrect token lengths and propagates wrong clone/snippet output without any warning. (`SoATokenStorage.swift:155-170`)

3. **Fix `RegexCache` eviction.** `Dictionary.keys.first` is unordered — eviction is currently random. Swap to `OrderedDictionary` (already a transitive dependency). (`RegexCache.swift:52-56`)

4. **Add cancellation to `BackpressuredChannelStream.makeChannel`.** Return both the channel and a `Task` handle (or a wrapper that finishes on `deinit`), so the documented "producer cancelled on iteration termination" actually holds. (`TaskBackedAsyncStream.swift:80-89`)

5. **Replace hand-rolled non-atomic `Bitmap` with `Collections.BitArray`.** Delete ~150 lines of code, gain `RandomAccessCollection`, and align with the project's own dependency. Keep `AtomicBitmap`. (`Bitmap.swift`)

6. **Make `SWA.swift` palatable (1152 → ~300 LOC per file).** Split four `AsyncParsableCommand` types into separate files under `Sources/swa/Commands/`; move `OutputFormatter` to `SwiftStaticAnalysisOutput`; move `findSwiftFiles`/`defaultExcludedDirectories` into `SwiftStaticAnalysisCore`. The function-body-length suppression at line 328 is a smell that linting silenced.

7. **Migrate `Foundation` → `FoundationEssentials` where possible.** Mechanical change with real Linux/binary-size payoff; guard with `#if canImport(FoundationEssentials)`. Start with `Sources/SwiftStaticAnalysisCore/Memory/` and `Utilities/`, leave `Sources/swa/` and `MCP` alone where `NSString` regex bridges are used.

8. **Parameterise the long-tail tests using `@Test(arguments:)`.** Concrete starting set: `MinHashSIMDEquivalenceTests`, `LSHIndexTests`, `MinHashAccuracyTests`, threshold/`minTokens` sweeps in `Duplicates`/`Unused` integration. Apply existing tags (`.algorithm`, `.boundary`, `.slow`, `.concurrency`) systematically — they're defined but used in only 5 suites.

9. **Bound `Symbol.run()`'s per-match `findUsages` calls with a TaskGroup.** Currently sequential `for match in matches { try await finder.findUsages(...) }` — trivially parallelisable, with a measurable win on large match sets. (`SWA.swift:585-591`)

10. **Replace `String` paths with `URL.FilePath` (or `System.FilePath`) at public API boundaries.** Mechanical, expressive, removes the `ObjCBool` smuggling sites (`SWA.swift:707, 1093`, etc.). At the same time, swap the four `URL(fileURLWithPath:)` clusters to `URL(filePath:directoryHint:)`. (Package-wide; biggest payoff in `MemoryMappedFile`, `ZeroCopyParser`, the CLI, and `IndexStorePathFinder`.)

---

### Appendix A — Notable files and their roles

- `Sources/SwiftStaticAnalysisCore/Concurrency/TaskBackedAsyncStream.swift` (117 LOC) — Two streaming helpers + cooperative cancellation.
- `Sources/SwiftStaticAnalysisCore/Concurrency/ConcurrencyConfiguration.swift` (184 LOC) — `ConcurrencyConfiguration` + chunked `ParallelProcessor`.
- `Sources/SwiftStaticAnalysisCore/Concurrency/Bitmap.swift` (298 LOC) — `AtomicBitmap`, `Bitmap` (hand-rolled).
- `Sources/SwiftStaticAnalysisCore/Memory/Arena.swift` (422 LOC) — `~Copyable` arena, `ThreadLocalArena` via pthread.
- `Sources/SwiftStaticAnalysisCore/Memory/MemoryMappedFile.swift` (538 LOC) — mmap, `RawSpan`, `Mutex`-guarded line-range cache.
- `Sources/SwiftStaticAnalysisCore/Memory/SoATokenStorage.swift` (518 LOC) — SoA layout, `ArenaTokenStorage` `@unchecked Sendable`.
- `Sources/SwiftStaticAnalysisCore/Memory/ZeroCopyParser.swift` (477 LOC) — actor with `OrderedDictionary` LRU; correct streaming `extractParallel`.
- `Sources/SwiftStaticAnalysisCore/Visitors/DeclarationCollector.swift` (857 LOC) — heavy `ScopeTrackingVisitor` subclass; correctly captures `String`s, not nodes.
- `Sources/SwiftStaticAnalysisCore/Visitors/ResultBuilderAnalyzer.swift` (646 LOC) — `SyntaxVisitor` subclass for `@resultBuilder` analysis.
- `Sources/DuplicationDetector/MinHash/MinHash.swift` (384 LOC) — SIMD4 Mersenne-61 MinHash, weighted variant.
- `Sources/DuplicationDetector/Parallel/ParallelMinHash.swift` (264 LOC) — unbounded TaskGroup issue lives here.
- `Sources/DuplicationDetector/Parallel/ParallelVerification.swift` — chunked verification; better than ParallelProcessor pattern.
- `Sources/UnusedCodeDetector/Reachability/ParallelBFS.swift` — direction-optimising BFS (Beamer et al.).
- `Sources/UnusedCodeDetector/IndexStore/IndexStoreReader.swift` (660 LOC) — wraps IndexStoreDB; N+1 fix verified.
- `Sources/UnusedCodeDetector/IndexStore/IndexBasedDependencyGraph.swift` — coarse Mutex (could use snapshot pattern).
- `Sources/swa/SWA.swift` (1152 LOC) — the monolith CLI file.

### Appendix B — Verification commands used

```bash
# Footguns
grep -rEn '(try!|as!)' Sources/                          # → empty
grep -rEn '![[:space:]]|![).,;}]|!\.' Sources/ | grep -v '!='  # → only DocC examples
grep -rEn 'fatalError|preconditionFailure' Sources/      # → 2 in Arena, 1 in TokenNormalizer string-table, 1 in CFGBuilder comment

# Concurrency primitives
grep -rn 'DispatchQueue\|NSLock\|os_unfair_lock\|DispatchSemaphore' Sources/   # → only comments referring to removal
grep -rn '@unchecked Sendable' Sources/                  # → 7 sites, all justified
grep -rn 'nonisolated(unsafe)' Sources/                  # → 12 sites (Regex constants + MCP server)
grep -rn 'Mutex\|Atomic<' Sources/ | head -10            # → consistent use

# Native APIs
grep -rn 'Span<\|RawSpan\|InlineArray' Sources/          # → RawSpan used in MemoryMappedFile only
grep -rn 'import FoundationEssentials' Sources/          # → 0 sites
grep -rn 'FilePath' Sources/                             # → only via regex variable names
grep -rn 'OrderedDictionary\|Deque\|BitArray\|TreeDictionary' Sources/  # → OrderedDictionary, Deque used; BitArray not

# Tests
grep -rn 'XCTAssert\|import XCTest' Tests/               # → empty
grep -rEn '@Test.*arguments:' Tests/                     # → 0 parameterised tests
grep -rEn '\.tags\(' Tests/                              # → 5 sites
```
