// Run subcommand — execute an arbitrary user .swift file as an OCCTSwift script.
//
// Maintains a cached SPM workspace under ~/.occtswift-scripts/runner-cache,
// copies the user's source in, builds and runs.
//
// Workspace ScriptHarness dependency resolution order:
//   1. $OCCTKIT_SCRIPTS_PATH (path-based dep) — explicit override
//   2. Auto-detect package root from argv[0] (path-based dep) — works when
//      running via `swift run occtkit ...` from a built tree
//   3. Remote `from: "0.2.0"` (last published tag at time of writing)
//
// Usage:
//   occtkit run <script.swift> [--format brep,step,graph-json,graph-sqlite] [--output <dir>]

import Foundation
import ScriptHarness

enum RunCommand: Subcommand {
    static let name = "run"
    static let summary = "Run a user .swift file via a cached SPM workspace"
    static let usage = """
        Usage: occtkit run <script.swift> [options]
        Options:
          --format <list>   brep, step, graph-json, graph-sqlite (default: brep,step)
          --output, -o <d>  Copy output dir to <d> after run
        """

    private struct Config {
        let scriptPath: String
        let formats: Set<String>
        let outputDir: String?
        static let defaultFormats: Set<String> = ["brep", "step"]
        static let allFormats: Set<String> = ["brep", "step", "graph-json", "graph-sqlite"]
    }

    static func run(args: [String]) throws -> Int32 {
        let config = try parse(args: args)
        try ensureWorkspace()
        try prepareScript(config)
        try buildAndRun()
        try copyOutput(config)
        return 0
    }

    // MARK: - Argument parsing

    private static func parse(args: [String]) throws -> Config {
        if args.isEmpty || args.contains("--help") || args.contains("-h") {
            throw ScriptError.message(usage)
        }
        var scriptPath: String?
        var formats = Config.defaultFormats
        var outputDir: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--format":
                i += 1
                guard i < args.count else { throw ScriptError.message("--format requires a value") }
                formats = Set(args[i].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
                let invalid = formats.subtracting(Config.allFormats)
                if !invalid.isEmpty {
                    throw ScriptError.message("Unknown format(s): \(invalid.sorted().joined(separator: ", "))")
                }
            case "--output", "-o":
                i += 1
                guard i < args.count else { throw ScriptError.message("--output requires a path") }
                outputDir = args[i]
            default:
                if args[i].hasPrefix("-") {
                    throw ScriptError.message("Unknown option: \(args[i])")
                }
                if scriptPath != nil { throw ScriptError.message("Multiple script files specified") }
                scriptPath = args[i]
            }
            i += 1
        }
        guard let path = scriptPath else { throw ScriptError.message("No script file specified") }
        guard FileManager.default.fileExists(atPath: path) else {
            throw ScriptError.message("Script not found: \(path)")
        }
        return Config(scriptPath: path, formats: formats, outputDir: outputDir)
    }

    // MARK: - Workspace

    private static let cacheDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".occtswift-scripts/runner-cache")
    private static let workspaceDir: URL = cacheDir.appendingPathComponent("workspace")

    private static func resolveScriptsDep() -> String {
        if let p = ProcessInfo.processInfo.environment["OCCTKIT_SCRIPTS_PATH"],
           FileManager.default.fileExists(atPath: p + "/Package.swift") {
            return ".package(path: \"\(p)\")"
        }
        // argv[0] is typically <pkg>/.build/<cfg>/occtkit when run via `swift run`
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidate = exe.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
            return ".package(path: \"\(candidate.path)\")"
        }
        return ".package(url: \"https://github.com/gsdali/OCCTSwiftScripts.git\", from: \"0.2.0\")"
    }

    private static func ensureWorkspace() throws {
        let fm = FileManager.default
        let packageSwift = workspaceDir.appendingPathComponent("Package.swift")
        let sourcesDir = workspaceDir.appendingPathComponent("Sources/Script")
        try fm.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let scriptsDep = resolveScriptsDep()
        let packageContent = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "OCCTSwiftUserScript",
            platforms: [.macOS(.v15)],
            dependencies: [
                \(scriptsDep),
            ],
            targets: [
                .executableTarget(
                    name: "Script",
                    dependencies: [
                        .product(name: "ScriptHarness", package: "OCCTSwiftScripts"),
                    ],
                    path: "Sources/Script",
                    swiftSettings: [.swiftLanguageMode(.v6)]
                ),
            ]
        )
        """
        try packageContent.write(to: packageSwift, atomically: true, encoding: .utf8)
    }

    private static func prepareScript(_ config: Config) throws {
        let scriptURL = URL(fileURLWithPath: config.scriptPath)
        var source = try String(contentsOf: scriptURL, encoding: .utf8)

        let wantsGraphJSON = config.formats.contains("graph-json")
        let wantsGraphSQLite = config.formats.contains("graph-sqlite")
        if wantsGraphJSON || wantsGraphSQLite {
            let graphCall = "try ctx.addGraphsForAllShapes(sqlite: \(wantsGraphSQLite))"
            if let emitRange = source.range(of: "try ctx.emit(") {
                source.insert(contentsOf: "\n\(graphCall)\n", at: emitRange.lowerBound)
            }
        }
        if !config.formats.contains("step") {
            source = source.replacingOccurrences(of: "ScriptContext()", with: "ScriptContext(exportSTEP: false)")
            source = source.replacingOccurrences(of: "ScriptContext(exportSTEP: true", with: "ScriptContext(exportSTEP: false")
        }

        let destURL = workspaceDir
            .appendingPathComponent("Sources/Script")
            .appendingPathComponent("main.swift")
        try source.write(to: destURL, atomically: true, encoding: .utf8)
    }

    private static func buildAndRun() throws {
        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        buildProcess.arguments = ["build", "--package-path", workspaceDir.path]
        buildProcess.currentDirectoryURL = workspaceDir
        let buildPipe = Pipe()
        buildProcess.standardError = buildPipe
        try buildProcess.run()
        buildProcess.waitUntilExit()
        if buildProcess.terminationStatus != 0 {
            let errorOutput = String(data: buildPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ScriptError.message("Build failed:\n\(errorOutput)")
        }

        let runProcess = Process()
        runProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        runProcess.arguments = ["run", "--skip-build", "--package-path", workspaceDir.path, "Script"]
        runProcess.currentDirectoryURL = workspaceDir
        try runProcess.run()
        runProcess.waitUntilExit()
        if runProcess.terminationStatus != 0 {
            throw ScriptError.message("Script exited with code \(runProcess.terminationStatus)")
        }
    }

    private static func copyOutput(_ config: Config) throws {
        guard let outputDir = config.outputDir else { return }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output")
        let local = home.appendingPathComponent(".occtswift-scripts/output")
        let sourceDir = fm.fileExists(atPath: iCloud.path) ? iCloud : local
        guard fm.fileExists(atPath: sourceDir.path) else { return }

        let destURL = URL(fileURLWithPath: outputDir)
        try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
        for file in try fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil) {
            let dest = destURL.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: file, to: dest)
        }
        print("Output copied to \(outputDir)")
    }
}
