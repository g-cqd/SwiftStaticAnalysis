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

        let report = Report(
            scenario: scenario.rawValue,
            fixture: fixture,
            fileCount: files.count,
            iterations: iterations,
            wallSecondsMean: mean(samples.map(\.wallSeconds)),
            wallSecondsMin: samples.map(\.wallSeconds).min() ?? 0,
            wallSecondsMax: samples.map(\.wallSeconds).max() ?? 0,
            peakRSSBytesMean: meanInt(samples.map(\.peakRSSBytes)),
            samples: samples
        )

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

struct Report: Codable, Sendable {
    let scenario: String
    let fixture: String
    let fileCount: Int
    let iterations: Int
    let wallSecondsMean: Double
    let wallSecondsMin: Double
    let wallSecondsMax: Double
    let peakRSSBytesMean: Int
    let samples: [Sample]
}

private func mean(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Double(values.count)
}

private func meanInt(_ values: [Int]) -> Int {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / values.count
}

private func durationInSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
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
