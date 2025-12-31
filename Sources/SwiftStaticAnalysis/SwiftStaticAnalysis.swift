/// SwiftStaticAnalysis - A high-performance Swift static analysis framework.
///
/// This module re-exports the four main components:
/// - ``SwiftStaticAnalysisCore``: Core infrastructure and models
/// - ``DuplicationDetector``: Clone detection algorithms
/// - ``UnusedCodeDetector``: Unused code detection
/// - ``SymbolLookup``: Symbol resolution and lookup

@_exported import DuplicationDetector
@_exported import SwiftStaticAnalysisCore
@_exported import SymbolLookup
@_exported import UnusedCodeDetector
