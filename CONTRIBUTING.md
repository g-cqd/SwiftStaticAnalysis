# Contributing to SwiftStaticAnalysis

Thank you for your interest in contributing to SwiftStaticAnalysis! This document provides guidelines and instructions for contributing.

## Getting Started

### Prerequisites

- macOS 15.0+
- Xcode 26.0+
- Swift 6.2+

### Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/g-cqd/SwiftStaticAnalysis.git
   cd SwiftStaticAnalysis
   ```

2. Build the project:
   ```bash
   swift build
   ```

3. Run tests:
   ```bash
   swift test --parallel
   ```

4. Build and run the CLI:
   ```bash
   swift run swa --help
   ```

## Code Guidelines

### Swift API Design

- Follow [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- Use clear, descriptive names that read naturally at the call site
- Prefer method names that form grammatical phrases

### Concurrency

- All public types must conform to `Sendable`
- Use `nonisolated` for pure functions without mutable state
- Prefer `async/await` over completion handlers
- Use `actor` for types requiring synchronized access

### Code Quality

- No force unwrapping (`!`) in library code
- Handle all error cases explicitly
- Add documentation comments for public APIs
- Keep functions focused and testable

### Example

```swift
/// Detects code clones in the given Swift files.
///
/// - Parameters:
///   - files: Array of Swift file paths to analyze.
///   - configuration: Detection configuration options.
/// - Returns: Array of clone groups found.
/// - Throws: `AnalysisError` if files cannot be parsed.
public func detectClones(
    in files: [String],
    configuration: DuplicationConfiguration = .default
) async throws -> [CloneGroup] {
    // Implementation
}
```

## Testing

### Running Tests

```bash
# Run all tests
swift test

# Run tests in parallel
swift test --parallel

# Run specific test suite
swift test --filter DuplicationDetectorTests

# Run with verbose output
swift test -v
```

### Writing Tests

- Use Swift Testing framework (`@Test`, `@Suite`, `#expect`)
- Add tests for all new functionality
- Include edge cases and error conditions
- Use descriptive test names

```swift
@Suite("Clone Detection Tests")
struct CloneDetectionTests {

    @Test("Detects exact clones with minimum tokens")
    func detectsExactClones() async throws {
        let detector = DuplicationDetector()
        let clones = try await detector.detectClones(in: testFiles)

        #expect(clones.count > 0)
        #expect(clones.first?.type == .exact)
    }
}
```

### Test Fixtures

Place test fixtures in `Tests/Fixtures/`:

- `DuplicationScenarios/` - Code samples for clone detection
- `UnusedCodeScenarios/` - Code samples for unused code detection

## Submitting Changes

### Workflow

1. **Fork** the repository
2. **Create a branch** for your feature:
   ```bash
   git checkout -b feature/amazing-feature
   ```
3. **Make your changes** with clear, atomic commits
4. **Add tests** for new functionality
5. **Ensure tests pass**:
   ```bash
   swift test --parallel
   ```
6. **Push** to your fork:
   ```bash
   git push origin feature/amazing-feature
   ```
7. **Open a Pull Request** with a clear description

### Commit Messages

Use clear, descriptive commit messages:

```
feat: Add semantic clone detection using AST fingerprints

- Implement ASTFingerprinter for structure hashing
- Add SemanticCloneDetector with configurable similarity
- Include tests for common semantic patterns
```

Prefix commits with:
- `feat:` - New feature
- `fix:` - Bug fix
- `perf:` - Performance improvement
- `refactor:` - Code refactoring
- `test:` - Adding tests
- `docs:` - Documentation changes

### Pull Request Guidelines

- Provide a clear description of the changes
- Reference any related issues
- Include before/after examples if applicable
- Ensure CI passes

## Reporting Issues

### Bug Reports

Include:
- Swift and Xcode version
- macOS/iOS version
- Minimal reproducible example
- Expected vs actual behavior
- Stack trace if applicable

### Feature Requests

Describe:
- The use case
- Proposed solution
- Alternative approaches considered

## Project Structure

```
SwiftStaticAnalysis/
├── Sources/
│   ├── SwiftStaticAnalysisCore/  # Core parsing and models
│   ├── DuplicationDetector/       # Clone detection algorithms
│   ├── UnusedCodeDetector/        # Unused code detection
│   └── SwiftStaticAnalysisCLI/    # CLI tool
├── Tests/
│   ├── SwiftStaticAnalysisCoreTests/
│   ├── DuplicationDetectorTests/
│   ├── UnusedCodeDetectorTests/
│   └── Fixtures/                   # Test data
└── .github/workflows/              # CI/CD
```

## Getting Help

- Open an issue for questions
- Check existing issues before creating new ones
- Use discussions for general questions

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
