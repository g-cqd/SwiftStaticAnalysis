//  BinaryTrustChecker.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - BinaryTrustChecker

/// Defence-in-depth check that a binary or dylib path is safe to
/// `dlopen`/`exec` from this process. Refuses any path whose target
/// is not (a) a regular file (b) owned by root (c) not group- or
/// world-writable.
///
/// The check is shared by every subsystem that hands an absolute path
/// to a loader: `IndexStoreReader.findLibIndexStore` (which dlopens a
/// `libIndexStore.dylib`) and `SourceKitLSPClient` (which spawns
/// `sourcekit-lsp`). Without this gate a low-privilege user with write
/// access under `/Applications/Xcode.app/...`, `/Library/Developer/...`
/// or any toolchain path that landed on disk via a non-installer flow
/// could plant a hostile binary that subsequent invocations would load.
public enum BinaryTrustChecker {
    /// Returns `true` if `path` exists, is a regular file owned by uid 0,
    /// and is not writable by group or other. Symlinks are rejected by
    /// `lstat`: callers are expected to pre-resolve to a canonical path
    /// or accept this stricter posture.
    public static func isTrusted(at path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return false }
        guard info.st_uid == 0 else { return false }
        // Group- or world-writable binaries are tampering targets even
        // when nominally root-owned.
        if (info.st_mode & UInt16(S_IWGRP | S_IWOTH)) != 0 { return false }
        return true
    }
}
