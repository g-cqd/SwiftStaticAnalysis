//  LSPFramingTests.swift
//  SwiftStaticAnalysisLSPServerTests
//  MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisLSPServer

@Suite("LSPFraming")
struct LSPFramingTests {
    @Test("encode prefixes Content-Length and a blank line separator")
    func encodePrefixesContentLengthHeader() throws {
        let payload = Data(#"{"jsonrpc":"2.0","method":"initialized"}"#.utf8)
        let framed = LSPFraming.encode(payload)

        // Header up to the `\r\n\r\n` separator.
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let headerEnd = try #require(framed.range(of: separator))
        let header = try #require(String(data: framed.subdata(in: 0..<headerEnd.lowerBound), encoding: .ascii))

        #expect(header == "Content-Length: \(payload.count)")
        let body = framed.subdata(in: headerEnd.upperBound..<framed.count)
        #expect(body == payload)
    }

    @Test("encode then decode round-trips the JSON payload")
    func encodeDecodeRoundTrip() throws {
        let payloads: [Data] = [
            Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8),
            Data(#"{"result":{"capabilities":{}},"id":2,"jsonrpc":"2.0"}"#.utf8),
            // Multi-byte UTF-8 (an "é") to verify byte-length accounting:
            Data(#"{"jsonrpc":"2.0","method":"café"}"#.utf8),
        ]

        for payload in payloads {
            let framed = LSPFraming.encode(payload)
            let decoded = try #require(LSPFraming.decode(framed))
            #expect(decoded.payload == payload)
            #expect(decoded.consumed == framed.count)
        }
    }

    @Test("decode handles two back-to-back messages")
    func decodeHandlesBackToBackMessages() throws {
        let firstPayload = Data(#"{"jsonrpc":"2.0","method":"a"}"#.utf8)
        let secondPayload = Data(#"{"jsonrpc":"2.0","method":"b"}"#.utf8)
        var stream = LSPFraming.encode(firstPayload)
        stream.append(LSPFraming.encode(secondPayload))

        let firstDecoded = try #require(LSPFraming.decode(stream))
        #expect(firstDecoded.payload == firstPayload)

        let remainder = stream.subdata(in: firstDecoded.consumed..<stream.count)
        let secondDecoded = try #require(LSPFraming.decode(remainder))
        #expect(secondDecoded.payload == secondPayload)
    }

    @Test("decode returns nil for an incomplete header")
    func decodeReturnsNilForIncompleteHeader() {
        let partialHeader = Data("Content-Length: 42\r\n".utf8)  // missing trailing CRLF
        #expect(LSPFraming.decode(partialHeader) == nil)
    }

    @Test("decode returns nil when payload is shorter than declared length")
    func decodeReturnsNilForIncompletePayload() {
        let payload = Data("{}".utf8)
        let framed = LSPFraming.encode(payload)
        // Drop the last byte to simulate a partial read.
        let truncated = framed.subdata(in: 0..<(framed.count - 1))
        #expect(LSPFraming.decode(truncated) == nil)
    }

    @Test("typed decode rejects oversized Content-Length")
    func typedDecodeRejectsOversizedContentLength() {
        // 9 GB header — must not allocate. Closes the DoS vector flagged
        // in the audit (LSP framing accepted unbounded Content-Length).
        let header = Data("Content-Length: 9999999999\r\n\r\n".utf8)
        let result = LSPFraming.decode(header, maxBytes: 1024)
        guard case .oversized(let declared, let limit) = result else {
            Issue.record("Expected .oversized, got \(result)")
            return
        }
        #expect(declared == 9_999_999_999)
        #expect(limit == 1024)
    }

    @Test("typed decode rejects negative Content-Length")
    func typedDecodeRejectsNegativeContentLength() {
        let header = Data("Content-Length: -1\r\n\r\n".utf8)
        #expect(LSPFraming.decode(header, maxBytes: 1024) == .malformedHeader)
    }

    @Test("typed decode rejects non-decimal Content-Length")
    func typedDecodeRejectsNonDecimalContentLength() {
        let header = Data("Content-Length: abc\r\n\r\n".utf8)
        #expect(LSPFraming.decode(header, maxBytes: 1024) == .malformedHeader)
    }

    @Test("typed decode reports incomplete when payload still arriving")
    func typedDecodeReportsIncompleteForPartial() {
        let payload = Data("{}".utf8)
        let framed = LSPFraming.encode(payload)
        let truncated = framed.subdata(in: 0..<(framed.count - 1))
        #expect(LSPFraming.decode(truncated, maxBytes: 1024) == .incomplete)
    }
}
