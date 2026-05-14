/// SwiftStaticAnalysisAll — umbrella module including the MCP server.
///
/// Consumers that need to embed the Model Context Protocol server should
/// import this module instead of `SwiftStaticAnalysis`. Importing this
/// module transitively pulls in `modelcontextprotocol/swift-sdk`.
///
/// If you only need the analyzer libraries, import `SwiftStaticAnalysis`
/// instead and skip the MCP dependency entirely.

@_exported import SwiftStaticAnalysis
@_exported import SwiftStaticAnalysisMCP
