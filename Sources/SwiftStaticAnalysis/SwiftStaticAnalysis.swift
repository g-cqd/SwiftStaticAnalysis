/// SwiftStaticAnalysis — high-performance Swift static analysis framework.
///
/// This module re-exports the four analyzer components:
/// - ``SwiftStaticAnalysisCore``: core infrastructure and models
/// - ``DuplicationDetector``: clone detection algorithms
/// - ``UnusedCodeDetector``: unused code detection
/// - ``SymbolLookup``: symbol resolution and lookup
///
/// MCP server support is in a separate product, `SwiftStaticAnalysisAll`,
/// so consumers that just want the analyzer libraries do not pull in the
/// `modelcontextprotocol/swift-sdk` dependency.

@_exported import DuplicationDetector
@_exported import SwiftStaticAnalysisCore
@_exported import SymbolLookup
@_exported import UnusedCodeDetector
