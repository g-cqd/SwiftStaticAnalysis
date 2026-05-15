//  SILParserTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore

@Suite("SIL Parser Tests")
struct SILParserTests {
    @Test("Parses a single-block function with no branches")
    func parsesStraightLineFunction() {
        let sil = """
            sil_stage canonical

            sil hidden @testAdd : $@convention(thin) (Int, Int) -> Int {
            bb0(%0 : $Int, %1 : $Int):
              %2 = struct_extract %0, #Int._value
              %3 = struct_extract %1, #Int._value
              return %3
            } // end sil function 'testAdd'
            """
        let functions = SILParser.parse(sil)
        #expect(functions.count == 1)
        #expect(functions[0].mangledName == "testAdd")
        #expect(functions[0].blockOrder == ["bb0"])
        let block = functions[0].blocks["bb0"]
        #expect(block?.arguments == ["%0", "%1"])
        #expect(block?.successors == [], "return is a terminator with no successors")
    }

    @Test("Conditional branch yields two successors")
    func parsesConditionalBranch() {
        let sil = """
            sil hidden @testGate : $@convention(thin) (Int) -> Int {
            bb0(%0 : $Int):
              %1 = builtin "cmp_slt_Int64"(%0, %0) : $Builtin.Int1
              cond_br %1, bb1, bb2

            bb1:
              br bb3(%0)

            bb2:
              br bb3(%0)

            bb3(%2 : $Int):
              return %2
            } // end sil function 'testGate'
            """
        let functions = SILParser.parse(sil)
        #expect(functions.count == 1)
        let function = functions[0]
        #expect(function.blockOrder == ["bb0", "bb1", "bb2", "bb3"])
        #expect(function.blocks["bb0"]?.successors == ["bb1", "bb2"])
        #expect(function.blocks["bb1"]?.successors == ["bb3"])
        #expect(function.blocks["bb2"]?.successors == ["bb3"])
        #expect(function.blocks["bb3"]?.successors == [])
    }

    @Test("Multiple functions are parsed independently")
    func parsesMultipleFunctions() {
        let sil = """
            sil hidden @first : $@convention(thin) () -> () {
            bb0:
              %0 = tuple ()
              return %0
            } // end sil function 'first'

            sil hidden @second : $@convention(thin) (Int) -> Int {
            bb0(%0 : $Int):
              return %0
            } // end sil function 'second'
            """
        let functions = SILParser.parse(sil)
        #expect(functions.count == 2)
        #expect(functions[0].mangledName == "first")
        #expect(functions[1].mangledName == "second")
    }
}
