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
