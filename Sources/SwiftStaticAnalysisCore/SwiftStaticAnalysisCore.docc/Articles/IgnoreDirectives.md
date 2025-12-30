# Ignore Directives

Suppress false positives directly in your source code using `// swa:ignore` comments.

## Overview

Sometimes static analysis tools report issues that are intentional or unavoidable. Rather than filtering them every time, you can mark specific declarations to be ignored permanently.

## Supported Directives

| Directive | Effect |
|-----------|--------|
| `// swa:ignore` | Ignore all warnings for this declaration |
| `// swa:ignore-unused` | Ignore unused code warnings only |
| `// swa:ignore-unused-cases` | Ignore unused enum case warnings |
| `// swa:ignore-duplicates` | Ignore duplication warnings for this declaration |
| `// swa:ignore-duplicates:begin` | Start of region to ignore for duplication |
| `// swa:ignore-duplicates:end` | End of region to ignore for duplication |

## Comment Formats

All standard Swift comment formats are supported:

```swift
// swa:ignore                    // Line comment
/// Doc comment. // swa:ignore   // In documentation comments
/* swa:ignore */                 // Block comment
/** swa:ignore */                // Doc block comment
```

## Usage Examples

### Ignoring a Function

```swift
// swa:ignore
func debugHelper() {
    // Intentionally unused in production
    // Used only during development debugging
}
```

### Ignoring Enum Cases

For exhaustive enums that need all cases for serialization:

```swift
/// API error types for JSON serialization.
/// All cases required for Codable conformance. // swa:ignore-unused-cases
public enum APIError: String, Codable {
    case networkError
    case authenticationFailed
    case serverError           // May not be used yet
    case rateLimited
    case maintenanceMode
}
```

### Ignoring Protocol Requirements

```swift
protocol DataSource {
    func numberOfItems() -> Int

    // swa:ignore-unused
    func item(at index: Int) -> Item  // Required by protocol
}
```

### Ignoring Objective-C Interop

```swift
class LegacyHandler: NSObject {
    // swa:ignore
    @objc func handleLegacyCallback(_ data: NSDictionary) {
        // Called from Objective-C code
    }
}
```

### Ignoring Generated or Intentionally Duplicated Code

For code that is intentionally duplicated (generated code, copy-paste templates, etc.):

```swift
// swa:ignore-duplicates
func generatedHandler1() {
    // This won't be flagged as a duplicate
    performStandardSetup()
    processData()
    cleanup()
}

// swa:ignore-duplicates
func generatedHandler2() {
    // Intentionally similar to handler1
    performStandardSetup()
    processData()
    cleanup()
}
```

For larger regions of generated code, use range markers:

```swift
// swa:ignore-duplicates:begin
struct GeneratedModel1: Codable {
    var id: String
    var name: String
    var createdAt: Date
}

struct GeneratedModel2: Codable {
    var id: String
    var name: String
    var createdAt: Date
}
// swa:ignore-duplicates:end
```

## Enum Case Inheritance

When you mark an enum with `// swa:ignore-unused-cases`, all its cases automatically inherit the directive:

```swift
/// Protocol message types. // swa:ignore-unused-cases
enum MessageType {
    case request    // Automatically ignored
    case response   // Automatically ignored
    case error      // Automatically ignored
}
```

This is useful for:
- Codable enums with all cases defined
- State machines with reserved states
- Protocol definitions requiring exhaustive cases

## Placement Rules

Place the directive comment:

1. **On the line before** the declaration
2. **On the same line** as the declaration
3. **At the end of a doc comment** before the declaration

```swift
// Option 1: Line before
// swa:ignore
func unused1() {}

// Option 2: Same line
func unused2() {} // swa:ignore

// Option 3: In doc comment
/// Does something. // swa:ignore
func unused3() {}
```

## Scope

Ignore directives apply to:
- The specific declaration they're attached to
- Nested declarations (for types)
- Enum cases (when using `ignore-unused-cases` on the enum)

```swift
// swa:ignore
struct DebugHelpers {
    // All members are also ignored
    static func helper1() {}
    static func helper2() {}
}
```

## Best Practices

1. **Be specific** - Use `swa:ignore-unused` instead of `swa:ignore` when only suppressing unused warnings

2. **Document why** - Add a comment explaining why the directive is needed:
   ```swift
   // swa:ignore - Required for Objective-C interop
   @objc func legacyMethod() {}
   ```

3. **Review periodically** - Ignores can mask real issues; review them during major refactors

4. **Prefer configuration** - For project-wide patterns (like excluding test files), use CLI flags instead:
   ```bash
   swa unused . --exclude-paths "**/Tests/**"
   ```

5. **Use for known false positives** - Not for code you "might need later"

## Checking Directive Coverage

To see which declarations have ignore directives:

```bash
# Show all declarations with directives
grep -r "swa:ignore" --include="*.swift" .
```

## See Also

- <doc:UnusedCodeDetection>
- <doc:CIIntegration>
