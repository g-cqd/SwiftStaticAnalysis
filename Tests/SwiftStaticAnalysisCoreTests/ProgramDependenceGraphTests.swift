//  ProgramDependenceGraphTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore

@Suite("Program Dependence Graph Tests")
struct ProgramDependenceGraphTests {
    @Test("Extracts def-use chain from a straight-line function")
    func extractsDefUse() {
        let sil = """
            sil hidden @testAdd : $@convention(thin) (Int, Int) -> Int {
            bb0(%0 : $Int, %1 : $Int):
              %2 = struct_extract %0, #Int._value
              %3 = struct_extract %1, #Int._value
              %4 = integer_literal $Builtin.Int1, -1
              %5 = builtin "sadd_with_overflow_Int64"(%2, %3, %4) : $(Builtin.Int64, Builtin.Int1)
              return %5
            } // end sil function 'testAdd'
            """
        let functions = SILParser.parse(sil)
        #expect(functions.count == 1)
        let pdg = ProgramDependenceGraph.build(from: functions[0])

        // Every defined value should have a definition record.
        let defined: Set<String> = ["0", "1", "2", "3", "4", "5"]
        for name in defined {
            #expect(
                pdg.definitions[SILValue(name: name)] != nil,
                "%\(name) should be in the definitions map",
            )
        }
        // %0 is a block argument (instructionIndex == -1).
        #expect(pdg.definitions[SILValue(name: "0")]?.instructionIndex == -1)
        // %5 is the last instruction's result.
        #expect(pdg.definitions[SILValue(name: "5")]?.instructionIndex == 3)

        // %2 is used by %5 (the builtin call) → exactly one use site.
        let uses2 = pdg.uses[SILValue(name: "2")] ?? []
        #expect(uses2.count == 1)
        // %5 is used by the terminator `return %5` → one use site.
        let uses5 = pdg.uses[SILValue(name: "5")] ?? []
        #expect(uses5.count == 1)
    }

    @Test("Edges include both data dependence and control flow")
    func includesBothEdgeKinds() {
        let sil = """
            sil hidden @testBr : $@convention(thin) (Int) -> Int {
            bb0(%0 : $Int):
              cond_br %0, bb1, bb2

            bb1:
              br bb3(%0)

            bb2:
              br bb3(%0)

            bb3(%1 : $Int):
              return %1
            } // end sil function 'testBr'
            """
        let functions = SILParser.parse(sil)
        let pdg = ProgramDependenceGraph.build(from: functions[0])

        let controlEdges = pdg.edges.filter { $0.kind == .controlFlow }
        // bb0→bb1, bb0→bb2, bb1→bb3, bb2→bb3 = 4 control-flow edges.
        #expect(controlEdges.count == 4)

        let dataEdges = pdg.edges.filter { $0.kind == .dataDependence }
        // Every `%0` use (in cond_br, in br bb3(%0) twice) and `%1`
        // use (in return) creates a data-dep edge.
        #expect(dataEdges.count >= 4)
    }

    @Test("Comments inside instructions are stripped before operand scan")
    func stripsTrailingComments() {
        let sil = """
            sil hidden @testComment : $@convention(thin) (Int) -> Int {
            bb0(%0 : $Int):
              %1 = struct_extract %0, #Int._value             // user: %2
              %2 = struct $Int (%1)                           // user: %3
              return %2                                       // id: %3
            } // end sil function 'testComment'
            """
        let functions = SILParser.parse(sil)
        let pdg = ProgramDependenceGraph.build(from: functions[0])

        // The `// user: %3` comment on the third line should NOT
        // produce a phantom `%3` use site — it's a comment, not an
        // operand reference.
        #expect(pdg.uses[SILValue(name: "3")] == nil)

        // Real uses: %0 → %1, %1 → %2, %2 → return.
        #expect(pdg.uses[SILValue(name: "0")]?.count == 1)
        #expect(pdg.uses[SILValue(name: "1")]?.count == 1)
        #expect(pdg.uses[SILValue(name: "2")]?.count == 1)
    }
}
