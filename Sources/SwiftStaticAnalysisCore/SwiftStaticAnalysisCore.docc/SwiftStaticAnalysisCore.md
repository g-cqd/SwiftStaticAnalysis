# ``SwiftStaticAnalysisCore``

Core infrastructure, parsing, and AST visitor types for Swift static analysis.

## Overview

SwiftStaticAnalysisCore provides the foundational types and parsing infrastructure used by the duplication and unused code detectors:

- **Declaration Model**: Represents Swift declarations (classes, functions, properties, etc.)
- **Reference Tracking**: Tracks references between declarations
- **AST Visitors**: SwiftSyntax-based visitors for collecting declarations and references
- **Parser Infrastructure**: Concurrent file parsing with caching

> Note: For high-level usage documentation, see the ``SwiftStaticAnalysis`` umbrella module.

## Topics

### Core Types

- ``Declaration``
- ``DeclarationKind``
- ``Reference``
- ``SourceLocation``
- ``AnalysisResult``

### Parsing

- ``SwiftFileParser``
- ``ConcurrencyConfiguration``

### Visitors

- ``DeclarationCollector``
- ``ReferenceCollector``
- ``ScopeTracker``
