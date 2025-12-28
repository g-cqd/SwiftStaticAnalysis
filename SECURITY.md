# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it through GitHub Issues.

For sensitive security matters, please prefix your issue title with `[SECURITY]`.

We will:
- Acknowledge receipt within 48 hours
- Provide an initial assessment within 7 days
- Work with you to understand and resolve the issue

## Security Features

SwiftStaticAnalysis implements several security measures:

### Memory Safety
- Uses Swift's memory-safe constructs throughout
- Memory-mapped I/O prevents loading entire large files into memory
- Arena allocation provides controlled memory management

### No Code Execution
- Static analysis only - no dynamic code evaluation
- Does not execute or compile analyzed code
- Safe to run on untrusted codebases

### File System Safety
- Read-only analysis by default
- No network connectivity required
- Output only to explicitly specified locations

### Data Handling
- No collection of telemetry or analytics
- No external service dependencies
- All processing happens locally

## Best Practices

When using SwiftStaticAnalysis:

1. **Run in sandboxed environments** for untrusted code
2. **Review output** before taking automated actions
3. **Keep updated** to receive security fixes
4. **Report issues** promptly through proper channels
