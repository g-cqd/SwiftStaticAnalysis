import Foundation
import PackagePlugin

// MARK: - StaticAnalysisBuildPlugin

/// Build tool plugin that runs static analysis on every build.
///
/// Runs both unused code detection and duplication detection with
/// Xcode-compatible output for automated reporting in the build log.
@main  // swa:ignore-unused - Plugin entry point called by SPM
struct StaticAnalysisBuildPlugin: BuildToolPlugin {
    // swa:ignore-unused - Protocol requirement called by SPM
    func createBuildCommands(
        context: PluginContext,
        target: Target,
    ) async throws -> [Command] {
        guard let sourceTarget = target as? SourceModuleTarget else {
            return []
        }

        // Get Swift source files
        let sourceFiles = sourceTarget.sourceFiles
            .filter { $0.url.pathExtension == "swift" }
            .map(\.url)

        guard !sourceFiles.isEmpty else {
            return []
        }

        // Get the swa tool
        let swaTool = try context.tool(named: "swa")

        // Build arguments for full analysis with Xcode output
        let arguments = [
            sourceTarget.directoryURL.path,
            "--format", "xcode",
        ]

        // Create output directory for prebuild command
        let outputDir = context.pluginWorkDirectoryURL
            .appendingPathComponent("static-analysis-output")

        return [
            .prebuildCommand(
                displayName: "Static Analysis \(target.name)",
                executable: swaTool.url,
                arguments: arguments,
                outputFilesDirectory: outputDir,
            )
        ]
    }
}

// MARK: - Xcode Project Support

#if canImport(XcodeProjectPlugin)
    import XcodeProjectPlugin

    extension StaticAnalysisBuildPlugin: XcodeBuildToolPlugin {
        // swa:ignore-unused - Protocol requirement called by Xcode
        func createBuildCommands(
            context: XcodePluginContext,
            target: XcodeTarget,
        ) throws -> [Command] {
            // Get Swift source files from Xcode target
            let sourceFiles = target.inputFiles
                .filter { $0.url.pathExtension == "swift" }
                .map(\.url)

            guard !sourceFiles.isEmpty else {
                return []
            }

            // Get the swa tool
            let swaTool = try context.tool(named: "swa")

            // Analyze the project directory with Xcode output format
            let arguments = [
                context.xcodeProject.directoryURL.path,
                "--format", "xcode",
            ]

            let outputDir = context.pluginWorkDirectoryURL
                .appendingPathComponent("static-analysis-output")

            return [
                .prebuildCommand(
                    displayName: "Static Analysis \(target.displayName)",
                    executable: swaTool.url,
                    arguments: arguments,
                    outputFilesDirectory: outputDir,
                )
            ]
        }
    }
#endif
