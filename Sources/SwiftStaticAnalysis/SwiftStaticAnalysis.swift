/// SwiftStaticAnalysis - A high-performance Swift static analysis framework.
///
/// This module re-exports the three main components:
/// - ``SwiftStaticAnalysisCore``: Core infrastructure and models
/// - ``DuplicationDetector``: Clone detection algorithms
/// - ``UnusedCodeDetector``: Unused code detection

@_exported import DuplicationDetector
@_exported import SwiftStaticAnalysisCore
@_exported import UnusedCodeDetector
