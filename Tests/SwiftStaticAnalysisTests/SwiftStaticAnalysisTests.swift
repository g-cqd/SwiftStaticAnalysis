import SwiftStaticAnalysis
import SwiftStaticAnalysisAll
import SwiftStaticAnalysisMCP
import Testing

@Suite("SwiftStaticAnalysis Re-Export Tests")
struct SwiftStaticAnalysisTests {
    @Test("analyzer-only umbrella re-exports the public API surface")
    func reexportsPublicAPIs() throws {
        let duplication = DuplicationConfiguration.highPerformance
        #expect(duplication.algorithm == .suffixArray)
        #expect(duplication.cloneTypes.contains(.near))

        let unused = UnusedCodeConfiguration.hybrid
        #expect(unused.mode == .indexStore)
        #expect(unused.hybridMode)

        let symbol = SymbolQuery.definition(of: "NetworkManager")
        #expect(symbol.mode == .definition)
        #expect(symbol.pattern.primaryIdentifier == "NetworkManager")

        let location = SourceLocation(file: "Sources/Example.swift", line: 7, column: 3)
        #expect(location.line == 7)
    }

    @Test("SwiftStaticAnalysisAll exports the MCP server alongside analyzers")
    func swiftStaticAnalysisAllExportsMCP() throws {
        _ = try SWAMCPServer(codebasePath: nil)
    }
}
