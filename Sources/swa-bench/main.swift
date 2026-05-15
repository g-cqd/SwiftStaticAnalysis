//  main.swift
//  swa-bench — performance benchmark runner
//  MIT License

import ArgumentParser
import DuplicationDetector
import Foundation
import SwiftStaticAnalysis
import SwiftStaticAnalysisCore
import SymbolLookup
import UnusedCodeDetector

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

// MARK: - Scenarios

enum BenchmarkScenario: String, ExpressibleByArgument, CaseIterable, Sendable {
    case duplicatesExact = "duplicates-exact"
    case duplicatesNear = "duplicates-near"
    case duplicatesSemantic = "duplicates-semantic"
    case unusedSimple = "unused-simple"
    case unusedReachability = "unused-reachability"
    case symbolLookup = "symbol-lookup"
}

// MARK: - SwaBench

@main
struct SwaBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swa-bench",
        abstract: "Run a performance benchmark scenario over a fixture and emit JSON results."
    )

    @Argument(help: "Scenario to run.")
    var scenario: BenchmarkScenario

    @Argument(help: "Path to the fixture directory.")
    var fixture: String

    @Option(name: .long, help: "Number of warm-up iterations (results discarded).")
    var warmup: Int = 1

    @Option(name: .long, help: "Number of measured iterations.")
    var iterations: Int = 3

    @Option(name: .long, help: "Optional output path for the JSON report. Defaults to stdout.")
    var output: String?

    @Flag(
        name: .long,
        help:
            "Print median and p99 alongside mean to stderr for human reading. The JSON report always carries the full statistical envelope."
    )
    var statistical: Bool = false

    func run() async throws {
        let files = try findSwiftFiles(in: fixture)
        guard !files.isEmpty else {
            throw ValidationError("No Swift files found under '\(fixture)'.")
        }

        for warmupIteration in 0..<warmup {
            _ = try await runOnce(files: files)
            fputs("  warmup \(warmupIteration + 1)/\(warmup) done\n", stderr)
        }

        var samples: [Sample] = []
        for iteration in 0..<iterations {
            let sample = try await runOnce(files: files)
            samples.append(sample)
            fputs(
                "  iter \(iteration + 1)/\(iterations): \(String(format: "%.3f", sample.wallSeconds))s peakRSS=\(sample.peakRSSBytes / 1024 / 1024)MiB\n",
                stderr
            )
        }

        let walls = samples.map(\.wallSeconds)
        let rss = samples.map(\.peakRSSBytes)
        let report = Report(
            scenario: scenario.rawValue,
            fixture: fixture,
            fileCount: files.count,
            iterations: iterations,
            wallSecondsMean: mean(walls),
            wallSecondsMedian: median(walls),
            wallSecondsP99: percentile(walls, p: 0.99),
            wallSecondsMin: walls.min() ?? 0,
            wallSecondsMax: walls.max() ?? 0,
            peakRSSBytesMean: meanInt(rss),
            peakRSSBytesP99: percentileInt(rss, p: 0.99),
            samples: samples,
            environment: BenchEnvironment.snapshot()
        )

        if statistical {
            fputs(
                """
                  stat: mean=\(String(format: "%.4f", report.wallSecondsMean))s \
                median=\(String(format: "%.4f", report.wallSecondsMedian))s \
                p99=\(String(format: "%.4f", report.wallSecondsP99))s\n
                """,
                stderr
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        if let output {
            try data.write(to: URL(fileURLWithPath: output))
            fputs("Wrote \(output)\n", stderr)
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    // MARK: - Per-iteration runner

    private func runOnce(files: [String]) async throws -> Sample {
        let startRSS = currentRSSBytes()
        let startWall = ContinuousClock.now

        switch scenario {
        case .duplicatesExact:
            let detector = DuplicationDetector(
                configuration: DuplicationConfiguration(
                    cloneTypes: [.exact],
                    algorithm: .suffixArray
                )
            )
            _ = try await detector.detectClones(in: files)
        case .duplicatesNear:
            let detector = DuplicationDetector(
                configuration: DuplicationConfiguration(
                    cloneTypes: [.near],
                    algorithm: .minHashLSH
                )
            )
            _ = try await detector.detectClones(in: files)
        case .duplicatesSemantic:
            let detector = DuplicationDetector(
                configuration: DuplicationConfiguration(cloneTypes: [.semantic])
            )
            _ = try await detector.detectClones(in: files)
        case .unusedSimple:
            let detector = UnusedCodeDetector(configuration: UnusedCodeConfiguration())
            _ = try await detector.detectUnused(in: files)
        case .unusedReachability:
            let detector = UnusedCodeDetector(configuration: .reachability)
            _ = try await detector.detectUnused(in: files)
        case .symbolLookup:
            let finder = SymbolFinder(projectPath: fixture)
            _ = try await finder.find(SymbolQuery.name("Swift"))
        }

        let wall = startWall.duration(to: .now)
        let peakRSS = currentRSSBytes()

        return Sample(
            wallSeconds: durationInSeconds(wall),
            peakRSSBytes: max(startRSS, peakRSS)
        )
    }

    private func findSwiftFiles(in path: String) throws -> [String] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path)
        guard
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw ValidationError("Cannot enumerate '\(path)'.")
        }

        var files: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url.path)
        }
        return files.sorted()
    }
}

// MARK: - Report model

struct Sample: Codable, Sendable {
    let wallSeconds: Double
    let peakRSSBytes: Int
}

/// Stable JSON schema:
///
/// ```
/// {
///   "scenario": "duplicates-near",
///   "fixture": "Sources",
///   "fileCount": 121,
///   "iterations": 3,
///   "wallSecondsMean": ...,
///   "wallSecondsMedian": ...,
///   "wallSecondsP99": ...,
///   "wallSecondsMin": ...,
///   "wallSecondsMax": ...,
///   "peakRSSBytesMean": ...,
///   "peakRSSBytesP99": ...,
///   "samples": [...],
///   "environment": {
///     "gitSha": "abc1234",
///     "swiftVersion": "Apple Swift version 6.2 (...)",
///     "host": "Mac-mini.local",
///     "platform": "macOS 26.0 (Darwin 25.4.0)"
///   }
/// }
/// ```
///
/// The CI baseline-compare script (`bench/compare.sh`) reads `wallSecondsMean`
/// and `wallSecondsP99` and compares to the committed baseline under
/// `bench/baselines/<scenario>.json`. Add fields, never rename.
struct Report: Codable, Sendable {
    let scenario: String
    let fixture: String
    let fileCount: Int
    let iterations: Int
    let wallSecondsMean: Double
    let wallSecondsMedian: Double
    let wallSecondsP99: Double
    let wallSecondsMin: Double
    let wallSecondsMax: Double
    let peakRSSBytesMean: Int
    let peakRSSBytesP99: Int
    let samples: [Sample]
    let environment: BenchEnvironment
}

/// Provenance metadata so a baseline can be matched against a host and a
/// toolchain rather than blindly compared across machines.
struct BenchEnvironment: Codable, Sendable {
    let gitSha: String
    let swiftVersion: String
    let host: String
    let platform: String

    static func snapshot() -> BenchEnvironment {
        BenchEnvironment(
            gitSha: captureCommand("git", ["rev-parse", "--short", "HEAD"]) ?? "unknown",
            swiftVersion: captureCommand("swift", ["--version"])?
                .split(separator: "\n").first.map(String.init) ?? "unknown",
            host: ProcessInfo.processInfo.hostName,
            platform: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}

// MARK: - Stats helpers

private func mean(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Double(values.count)
}

private func meanInt(_ values: [Int]) -> Int {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / values.count
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[mid - 1] + sorted[mid]) / 2
    }
    return sorted[mid]
}

/// Linear-interpolated percentile. p in [0, 1].
private func percentile(_ values: [Double], p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let clamped = min(max(p, 0), 1)
    let rank = clamped * Double(sorted.count - 1)
    let lo = Int(rank.rounded(.down))
    let hi = Int(rank.rounded(.up))
    if lo == hi { return sorted[lo] }
    let frac = rank - Double(lo)
    return sorted[lo] * (1 - frac) + sorted[hi] * frac
}

private func percentileInt(_ values: [Int], p: Double) -> Int {
    Int(percentile(values.map(Double.init), p: p))
}

private func durationInSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

/// Run a command and return its trimmed stdout, or nil on failure. Used
/// only at report-construction time, so failures degrade gracefully into
/// an "unknown" string rather than crashing the benchmark.
private func captureCommand(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle(forWritingAtPath: "/dev/null")
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - RSS reading

#if canImport(Darwin)
    private func currentRSSBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) { pointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    pointer,
                    &count
                )
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size)
    }
#else
    private func currentRSSBytes() -> Int {
        guard let contents = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else {
            return 0
        }
        for line in contents.split(separator: "\n") where line.hasPrefix("VmRSS:") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, let kib = Int(parts[parts.count - 2]) {
                return kib * 1024
            }
        }
        return 0
    }
#endif
