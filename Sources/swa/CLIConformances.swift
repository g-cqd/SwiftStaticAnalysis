//  CLIConformances.swift
//  swa
//  MIT License
//
//  `ExpressibleByArgument` conformances for the domain enums. The
//  conformance lives in the executable target rather than the public
//  library so that consumers of `DuplicationDetector` /
//  `UnusedCodeDetector` don't pull in `ArgumentParser`. Same-package
//  conformance, so `@retroactive` is not required.

import ArgumentParser
import DuplicationDetector
import SwiftStaticAnalysisCore
import SymbolLookup
import UnusedCodeDetector

extension DeclarationKind: ExpressibleByArgument {}
extension AccessLevel: ExpressibleByArgument {}
extension CloneType: ExpressibleByArgument {}
extension DetectionMode: ExpressibleByArgument {}
extension DetectionAlgorithm: ExpressibleByArgument {}
extension Confidence: ExpressibleByArgument {}
extension ParallelMode: ExpressibleByArgument {}
extension OutputFormat: ExpressibleByArgument {}

// MARK: - LSHStrategyArg

/// CLI surface for `DuplicationDetector.LSHStrategy`. Defined as a flat
/// raw enum so ArgumentParser can parse `--lsh-strategy <name>` directly;
/// the associated-value variants are reconstructed from a sibling flag
/// (`--lsh-probes-per-band`) in the subcommand's `run()`.
public enum LSHStrategyArg: String, ExpressibleByArgument, CaseIterable, Sendable {
    case standard
    case multiProbe = "multi-probe"
    case parallel

    public func toLSHStrategy(probesPerBand: Int) -> LSHStrategy {
        switch self {
        case .standard:
            return .standard
        case .multiProbe:
            return .multiProbe(probesPerBand: probesPerBand)
        case .parallel:
            return .parallel(maxConcurrency: nil)
        }
    }
}
