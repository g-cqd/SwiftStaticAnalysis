import Foundation
import PackagePlugin

// MARK: - StaticAnalysisCommandPlugin

/// Command plugin for running static analysis on Swift code.
///
/// Usage:
/// - `swift package analyze unused` - Find unused code
/// - `swift package analyze duplicates` - Find duplicated code
/// - `swift package analyze` - Run all analyses
@main  // swa:ignore-unused - Plugin entry point called by SPM
struct StaticAnalysisCommandPlugin: CommandPlugin {
    // swa:ignore-unused - Protocol requirement called by SPM
    func performCommand(
        context: PluginContext,
        arguments: [String],
    ) async throws {
        // Get the swa tool
        let swaTool = try context.tool(named: "swa")

        // Parse arguments
        let extractor = ArgumentExtractor(arguments)
        let analysisType = extractor.remainingArguments.first ?? "all"

        // Determine what to analyze
        let commands: [(name: String, args: [String])]
        switch analysisType {
        case "unused":
            commands = [("Unused Code", ["unused", context.package.directoryURL.path])]

        case "duplicates":
            commands = [("Duplications", ["duplicates", context.package.directoryURL.path])]

        case "all":
            commands = [
                ("Unused Code", ["unused", context.package.directoryURL.path]),
                ("Duplications", ["duplicates", context.package.directoryURL.path]),
            ]

        default:
            print("Unknown analysis type: \(analysisType)")
            print("Available: unused, duplicates, all")
            return
        }

        for (name, args) in commands {
            print("Running \(name) Analysis...")
            print(String(repeating: "-", count: 50))

            let process = Process()
            process.executableURL = swaTool.url
            process.arguments = args
            process.currentDirectoryURL = context.package.directoryURL
            // 0.3.0-α: defence-in-depth. The SPM plugin sandbox forbids
            // importing `ProcessExecutor` (Core, internal), so we can't
            // route through the env-allowlisted launcher. Empty the
            // child environment here so `DYLD_INSERT_LIBRARIES` /
            // `SWIFTPM_HOOKS_DIR` / `BASH_ENV` cannot ride into the
            // analyzer process even if the SPM host has them set.
            process.environment = [:]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errors = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            if !output.isEmpty {
                print(output)
            }
            if !errors.isEmpty {
                Diagnostics.warning(errors)
            }

            if process.terminationStatus != 0 {
                Diagnostics.warning("\(name) analysis completed with warnings")
            } else {
                print("\(name) analysis completed successfully")
            }
            print()
        }
    }
}

// MARK: - Xcode Project Support

#if canImport(XcodeProjectPlugin)
    import XcodeProjectPlugin

    extension StaticAnalysisCommandPlugin: XcodeCommandPlugin {
        // swa:ignore-unused - Protocol requirement called by Xcode
        func performCommand(
            context: XcodePluginContext,
            arguments: [String],
        ) throws {
            let swaTool = try context.tool(named: "swa")

            let extractor = ArgumentExtractor(arguments)
            let analysisType = extractor.remainingArguments.first ?? "all"

            let commands: [(name: String, args: [String])]
            switch analysisType {
            case "unused":
                commands = [("Unused Code", ["unused", context.xcodeProject.directoryURL.path])]

            case "duplicates":
                commands = [("Duplications", ["duplicates", context.xcodeProject.directoryURL.path])]

            case "all":
                commands = [
                    ("Unused Code", ["unused", context.xcodeProject.directoryURL.path]),
                    ("Duplications", ["duplicates", context.xcodeProject.directoryURL.path]),
                ]

            default:
                print("Unknown analysis type: \(analysisType)")
                return
            }

            for (name, args) in commands {
                print("Running \(name) Analysis...")
                print(String(repeating: "-", count: 50))

                let process = Process()
                process.executableURL = swaTool.url
                process.arguments = args
                process.currentDirectoryURL = context.xcodeProject.directoryURL
                // 0.3.0-α: defence-in-depth (see SPM branch above).
                process.environment = [:]

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                try process.run()
                process.waitUntilExit()

                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errors = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                if !output.isEmpty { print(output) }
                if !errors.isEmpty { Diagnostics.warning(errors) }

                print()
            }
        }
    }
#endif
