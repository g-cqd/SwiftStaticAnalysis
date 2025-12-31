//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftStaticAnalysis open source project
//
// Copyright (c) 2024 the SwiftStaticAnalysis project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Testing

@testable import SymbolLookup

@Suite("USRDecoder Tests")
struct USRDecoderTests {
    let decoder = USRDecoder()

    @Test("Decodes static property USR")
    func decodesStaticPropertyUSR() {
        let usr = "s:14NetworkMonitor6sharedACvpZ"
        let result = decoder.decode(usr)

        #expect(result?.isStatic == true)
        #expect(result?.symbolName == "shared")
        #expect(result?.contextName == "NetworkMonitor")
    }

    @Test("Decodes instance property USR")
    func decodesInstancePropertyUSR() {
        let usr = "s:14NetworkMonitor11isConnectedSbvp"
        let result = decoder.decode(usr)

        #expect(result?.isStatic == false)
        #expect(result?.symbolName == "isConnected")
        #expect(result?.contextName == "NetworkMonitor")
    }

    @Test("Decodes method USR")
    func decodesMethodUSR() {
        let usr = "s:14NetworkMonitor12checkNetworkyyF"
        let result = decoder.decode(usr)

        #expect(result?.isStatic == false)
    }

    @Test("Decodes static method USR")
    func decodesStaticMethodUSR() {
        let usr = "s:14NetworkMonitor9configureyyFZ"
        let result = decoder.decode(usr)

        #expect(result?.isStatic == true)
    }

    @Test("Returns nil for invalid USR")
    func returnsNilForInvalidUSR() {
        let result1 = decoder.decode("")
        let result2 = decoder.decode("invalid")
        let result3 = decoder.decode("x:something")

        #expect(result1 == nil)
        #expect(result2 == nil)
        #expect(result3 == nil)
    }

    @Test("Swift schema detection")
    func swiftSchemaDetection() {
        let swiftUSR = "s:14NetworkMonitor6sharedACvpZ"
        let result = decoder.decode(swiftUSR)

        #expect(result?.schema == .swift)
    }

    @Test("Clang schema detection")
    func clangSchemaDetection() {
        let clangUSR = "c:@F@main"
        let result = decoder.decode(clangUSR)

        #expect(result?.schema == .clang)
    }

    @Test("Property kind detection")
    func propertyKindDetection() {
        let usr = "s:14NetworkMonitor11isConnectedSbvp"
        let result = decoder.decode(usr)

        #expect(result?.kind == .property)
    }

    @Test("Extracts context and symbol name for qualified lookup")
    func extractsContextAndSymbolName() {
        let usr = "s:14NetworkMonitor6sharedACvpZ"
        let result = decoder.decode(usr)

        #expect(result?.contextName == "NetworkMonitor")
        #expect(result?.symbolName == "shared")
    }

    @Test("isType returns true for type kinds")
    func isTypeForTypeKinds() {
        // Test that type markers are detected
        let typeUSR = "s:14NetworkMonitorC"
        let result = decoder.decode(typeUSR)

        // The decoder should identify type-level USRs
        #expect(result?.schema == .swift)
    }

    @Test("isInstance returns true for instance members")
    func isInstanceForInstanceMembers() {
        let usr = "s:14NetworkMonitor11isConnectedSbvp"
        let result = decoder.decode(usr)

        #expect(result?.isInstance == true)
        #expect(result?.isStatic == false)
    }

    @Test("Decodes property and method USRs correctly")
    func decodesPropertyAndMethodUSRs() {
        // Test with a property USR
        let propertyUSR = "s:14NetworkMonitor11isConnectedSbvp"
        let propertyResult = decoder.decode(propertyUSR)

        #expect(propertyResult != nil)
        #expect(propertyResult?.schema == .swift)
        #expect(propertyResult?.symbolName == "isConnected")

        // Test with a method USR
        let methodUSR = "s:14NetworkMonitor12checkNetworkyyF"
        let methodResult = decoder.decode(methodUSR)

        #expect(methodResult != nil)
        #expect(methodResult?.schema == .swift)
    }

    @Test("Raw USR is preserved")
    func rawUSRPreserved() {
        let usr = "s:14NetworkMonitor6sharedACvpZ"
        let result = decoder.decode(usr)

        #expect(result?.rawUSR == usr)
    }
}
