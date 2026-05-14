import Testing

import SwiftStaticAnalysis

@Suite("SwiftStaticAnalysis Re-Export Tests")
struct SwiftStaticAnalysisTests {
    @Test("umbrella module re-exports the public API surface")
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

        _ = try SWAMCPServer(codebasePath: nil)
    }
}
