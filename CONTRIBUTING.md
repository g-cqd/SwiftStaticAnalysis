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

2. Enable git hooks:
   ```bash
   git config core.hooksPath .githooks
   ```

3. Build the project:
   ```bash
   swift build
   ```

4. Run tests:
   ```bash
   swift test --parallel
   ```

5. Build and run the CLI:
   ```bash
   swift run swa --help
   ```

## AI-Assisted Development (Vibe Coding)

This project embraces AI-assisted development with Claude Code. Whether you're contributing manually or with AI assistance, follow these guidelines to ensure quality contributions.

### Working with Claude Code

When using Claude Code for contributions:

1. **Plan First, Code Second**
   - Use Plan Mode (Shift+Tab twice) for complex changes
   - Review the plan before allowing code modifications
   - Complex features should have an approved implementation plan

2. **Tests First (RED-GREEN-REFACTOR)**
   - Write failing tests before implementation code
   - The failing test is your contract with the AI
   - Only mark work complete when tests pass

3. **Iterative Refinement**
   - Make small, focused changes
   - Run tests after each iteration
   - Review generated code for style and patterns

4. **Human Review Required**
   - All AI-generated code must be reviewed
   - Watch for unsafe patterns, force unwraps, and concurrency issues
   - Verify naming conventions match project standards

### CLAUDE.md Configuration

The project may include a `CLAUDE.md` file with repo-specific instructions. If contributing new conventions or workflows, consider updating this file.

Key conventions for AI-assisted work:
- Use Swift 6 strict concurrency
- Follow Swift API Design Guidelines
- Run `swift test --parallel` before commits
- Use `swift-format` for code formatting

### Quality Gates

Before submitting AI-assisted contributions:

```bash
# Format code
swift-format format -i -r Sources/ Tests/

# Run all tests
swift test --parallel

# Check for unused code
swift run swa unused --sensible-defaults Sources/

# Check for duplicates
swift run swa duplicates Sources/
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
3. **Plan your implementation** (especially for complex changes)
4. **Write tests first** for new functionality
5. **Make your changes** with clear, atomic commits
6. **Ensure tests pass**:
   ```bash
   swift test --parallel
   ```
7. **Push** to your fork:
   ```bash
   git push origin feature/amazing-feature
   ```
8. **Open a Pull Request** with a clear description

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
- `chore:` - Maintenance tasks

### Pull Request Guidelines

- Provide a clear description of the changes
- Reference any related issues
- Include before/after examples if applicable
- Ensure CI passes
- Note if AI-assisted: "AI-assisted with Claude Code" in description

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
│   ├── SwiftStaticAnalysis/        # Unified module (re-exports all)
│   ├── SwiftStaticAnalysisCore/    # Core parsing and models
│   ├── DuplicationDetector/        # Clone detection algorithms
│   ├── UnusedCodeDetector/         # Unused code detection
│   ├── SymbolLookup/               # Symbol search and resolution
│   ├── SwiftStaticAnalysisMCP/     # MCP server for AI tools
│   ├── swa/                        # CLI tool
│   ├── swa-mcp/                    # MCP server binary
│   ├── StaticAnalysisBuildPlugin/  # Build-time analysis plugin
│   └── StaticAnalysisCommandPlugin/# On-demand analysis plugin
├── Tests/
│   ├── SwiftStaticAnalysisCoreTests/
│   ├── DuplicationDetectorTests/
│   ├── UnusedCodeDetectorTests/
│   ├── SymbolLookupTests/
│   ├── CLITests/
│   └── Fixtures/                   # Test data
├── docs/                           # Research and documentation
└── .github/workflows/              # CI/CD
```

## MCP Server for AI Tools

The project includes an MCP (Model Context Protocol) server that exposes static analysis tools for AI assistants like Claude Code.

### Using the MCP Server

```bash
# Run the MCP server
swift run swa-mcp /path/to/codebase
```

### Available Tools

- `detect_unused_code` - Find unused declarations
- `detect_duplicates` - Find code clones
- `search_symbols` - Search for symbols by name
- `analyze_file` - Full analysis of a single file
- `read_file` - Read file contents with line numbers

## Getting Help

- Open an issue for questions
- Check existing issues before creating new ones
- Use discussions for general questions

## Suppressing False Positives

When developing, you may encounter false positive warnings from the static analysis tool. Use `// swa:ignore` comments to suppress them:

```swift
/// Exhaustive enum for API compatibility. // swa:ignore-unused-cases
enum APIStatus {
    case success
    case pending     // May not be used yet
    case cancelled
}

// swa:ignore
func debugOnlyHelper() {
    // Intentionally unused in production
}
```

See the [README](README.md#ignore-directives) for full documentation on ignore directives.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
