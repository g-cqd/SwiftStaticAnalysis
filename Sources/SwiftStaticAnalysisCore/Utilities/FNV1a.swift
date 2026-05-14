//  FNV1a.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - FNV1a

/// FNV-1a 64-bit hash. Non-cryptographic; suitable for content
/// fingerprints (change detection), bucket selection (LSH), and stable
/// document identifiers.
///
/// Centralised in 0.2.0; previous releases inlined the same constants
/// across `ChangeDetector`, `ShingleGenerator`, `LSH`, and
/// `MemoryMappedFile.FileSlice.hash()`.
public enum FNV1a {
    /// FNV-1a 64-bit offset basis.
    public static let offsetBasis: UInt64 = 14_695_981_039_346_656_037

    /// FNV-1a 64-bit prime.
    public static let prime: UInt64 = 1_099_511_628_211

    /// Compute FNV-1a hash of a sequence of bytes.
    @inlinable
    public static func hash(_ data: Data) -> UInt64 {
        var hash = offsetBasis
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// Compute FNV-1a hash of a raw byte buffer (zero-copy view).
    @inlinable
    public static func hash(_ buffer: UnsafeRawBufferPointer) -> UInt64 {
        var hash = offsetBasis
        for i in 0..<buffer.count {
            hash ^= UInt64(buffer.loadUnaligned(fromByteOffset: i, as: UInt8.self))
            hash = hash &* prime
        }
        return hash
    }

    /// Compute FNV-1a hash of the UTF-8 view of a string.
    @inlinable
    public static func hash(_ string: String) -> UInt64 {
        var hash = offsetBasis
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// Compute FNV-1a hash over a sequence of strings, separated by a NUL
    /// byte to make composite keys unambiguous (e.g. "ab"+"c" ≠ "a"+"bc").
    @inlinable
    public static func hash(_ strings: [String]) -> UInt64 {
        var hash = offsetBasis
        for string in strings {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
            // NUL separator
            hash ^= 0
            hash = hash &* prime
        }
        return hash
    }

    /// Compute FNV-1a hash of a sequence of `UInt64` values, mixing each
    /// in little-endian byte order.
    @inlinable
    public static func hash(_ values: some Sequence<UInt64>) -> UInt64 {
        var hash = offsetBasis
        for value in values {
            for shift in stride(from: 0, through: 56, by: 8) {
                hash ^= UInt64((value >> UInt64(shift)) & 0xff)
                hash = hash &* prime
            }
        }
        return hash
    }
}
