//  SymbolLookup.swift
//  SwiftStaticAnalysis
//  MIT License

/// Symbol Lookup and Actor Isolation Analysis Module.
///
/// This module provides:
/// - Symbol resolution by name, qualified name, or USR
/// - Actor isolation domain inference
/// - Cross-isolation boundary violation detection
///
/// ## Overview
///
/// The module implements a three-layer symbol resolution architecture:
/// 1. **FileIndex** (dynamic) - Open files with live updates
/// 2. **BackgroundIndex** (persistent) - LMDB-backed IndexStoreDB
/// 3. **StaticIndex** (pre-built) - SDK and dependency symbols
///
/// ## Key Types
///
/// - ``SymbolQuery``: Represents a lookup query with filters
/// - ``SymbolMatch``: Result from symbol resolution
/// - ``IsolationDomain``: Actor isolation classification
/// - ``IsolationViolation``: Cross-boundary access violation
///
/// ## Example Usage
///
/// ```swift
/// // Simple name lookup
/// let query = SymbolQuery.name("shared")
/// let matches = try await finder.find(query)
///
/// // Qualified name with isolation analysis
/// let query = SymbolQuery.qualified("NetworkMonitor.shared")
///     .with(includeIsolation: true)
/// let matches = try await finder.find(query)
///
/// // USR-based lookup
/// let query = SymbolQuery.usr("s:14NetworkMonitor6sharedACvpZ")
/// let matches = try await finder.find(query)
/// ```
///
/// ## Actor Isolation
///
/// The module correctly handles Swift's actor isolation semantics:
/// - Instance members of actors are isolated to the actor instance
/// - Static properties on actors are **nonisolated** (global storage)
/// - `@MainActor` and other global actors propagate to members
///
/// - SeeAlso: ``IsolationDomain`` for the isolation lattice definition

// Re-export public types
@_exported import SwiftStaticAnalysisCore
