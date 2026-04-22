// OCCTRunner — CLI wrapper for running OCCTSwift geometry scripts.
//
// Usage:
//   occtrunner <script.swift> [--format brep,step,graph-json,graph-sqlite] [--output <dir>]
//
// Manages a cached SPM workspace, copies the user's script in, builds and runs.

import Foundation

FileHandle.standardError.write(Data("DEPRECATED: 'OCCTRunner' standalone target will be removed in a future release. Use 'occtkit run' instead.\n".utf8))

// MARK: - Configuration

struct RunnerConfig {
    let scriptPath: String
    let formats: Set<String>
    let outputDir: String?

    static let defaultFormats: Set<String> = ["brep", "step"]
    static let allFormats: Set<String> = ["brep", "step", "graph-json", "graph-sqlite"]
}

// MARK: - Argument Parsing

func parseArgs() -> RunnerConfig {
    let args = Array(CommandLine.arguments.dropFirst())

    if args.isEmpty || args.contains("--help") || args.contains("-h") {
        printUsage()
        exit(0)
    }

    var scriptPath: String?
    var formats = RunnerConfig.defaultFormats
    var outputDir: String?
    var i = 0

    while i < args.count {
        switch args[i] {
        case "--format":
            i += 1
            guard i < args.count else { fatal("--format requires a value") }
            formats = Set(args[i].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            let invalid = formats.subtracting(RunnerConfig.allFormats)
            if !invalid.isEmpty {
                fatal("Unknown format(s): \(invalid.sorted().joined(separator: ", ")). Valid: \(RunnerConfig.allFormats.sorted().joined(separator: ", "))")
            }
        case "--output", "-o":
            i += 1
            guard i < args.count else { fatal("--output requires a path") }
            outputDir = args[i]
        default:
            if args[i].hasPrefix("-") {
                fatal("Unknown option: \(args[i])")
            }
            if scriptPath != nil {
                fatal("Multiple script files specified")
            }
            scriptPath = args[i]
        }
        i += 1
    }

    guard let path = scriptPath else {
        fatal("No script file specified")
    }

    guard FileManager.default.fileExists(atPath: path) else {
        fatal("Script not found: \(path)")
    }

    return RunnerConfig(scriptPath: path, formats: formats, outputDir: outputDir)
}

func printUsage() {
    let usage = """
    OCCTRunner — Run OCCTSwift geometry scripts

    USAGE:
      occtrunner <script.swift> [options]

    OPTIONS:
      --format <formats>   Comma-separated output formats (default: brep,step)
                           Valid: brep, step, graph-json, graph-sqlite
      --output, -o <dir>   Output directory (default: ~/.occtswift-scripts/output/)
      --help, -h           Show this help

    EXAMPLES:
      occtrunner bracket.swift
      occtrunner bracket.swift --format brep,step,graph-json,graph-sqlite
      occtrunner bracket.swift --format graph-json -o ./output
    """
    print(usage)
}

func fatal(_ message: String) -> Never {
    fputs("Error: \(message)\n", stderr)
    exit(1)
}

// MARK: - Workspace Management

let cacheDir: URL = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".occtswift-scripts/runner-cache")
}()

let workspaceDir: URL = cacheDir.appendingPathComponent("workspace")

func ensureWorkspace() throws {
    let fm = FileManager.default
    let packageSwift = workspaceDir.appendingPathComponent("Package.swift")
    let sourcesDir = workspaceDir.appendingPathComponent("Sources/Script")

    if fm.fileExists(atPath: packageSwift.path) {
        // Workspace exists, just ensure sources dir is there
        try fm.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        return
    }

    // Create fresh workspace
    try fm.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

    let packageContent = """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "OCCTSwiftUserScript",
        platforms: [
            .macOS(.v15)
        ],
        dependencies: [
            .package(url: "https://github.com/gsdali/OCCTSwiftScripts.git", from: "0.3.0"),
        ],
        targets: [
            .executableTarget(
                name: "Script",
                dependencies: [
                    .product(name: "ScriptHarness", package: "OCCTSwiftScripts"),
                ],
                path: "Sources/Script",
                swiftSettings: [
                    .swiftLanguageMode(.v6)
                ]
            ),
        ]
    )
    """
    try packageContent.write(to: packageSwift, atomically: true, encoding: .utf8)
}

// MARK: - Script Preparation

func prepareScript(_ config: RunnerConfig) throws -> URL {
    let scriptURL = URL(fileURLWithPath: config.scriptPath)
    var source = try String(contentsOf: scriptURL, encoding: .utf8)

    // Inject graph export calls if graph formats are requested
    let wantsGraphJSON = config.formats.contains("graph-json")
    let wantsGraphSQLite = config.formats.contains("graph-sqlite")

    if wantsGraphJSON || wantsGraphSQLite {
        // Insert graph export before emit() call
        let graphCall = "try ctx.addGraphsForAllShapes(sqlite: \(wantsGraphSQLite))"
        if let emitRange = source.range(of: "try ctx.emit(") {
            source.insert(contentsOf: "\n\(graphCall)\n", at: emitRange.lowerBound)
        }
    }

    // Disable STEP if not requested
    if !config.formats.contains("step") {
        source = source.replacingOccurrences(
            of: "ScriptContext()",
            with: "ScriptContext(exportSTEP: false)"
        )
        source = source.replacingOccurrences(
            of: "ScriptContext(exportSTEP: true",
            with: "ScriptContext(exportSTEP: false"
        )
    }

    let destURL = workspaceDir
        .appendingPathComponent("Sources/Script")
        .appendingPathComponent("main.swift")
    try source.write(to: destURL, atomically: true, encoding: .utf8)
    return destURL
}

// MARK: - Build & Run

func buildAndRun() throws {
    let buildProcess = Process()
    buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    buildProcess.arguments = ["build", "--package-path", workspaceDir.path]
    buildProcess.currentDirectoryURL = workspaceDir

    let buildPipe = Pipe()
    buildProcess.standardError = buildPipe

    try buildProcess.run()
    buildProcess.waitUntilExit()

    if buildProcess.terminationStatus != 0 {
        let errorData = buildPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        fputs("Build failed:\n\(errorOutput)\n", stderr)
        exit(1)
    }

    // Run the built executable
    let runProcess = Process()
    runProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    runProcess.arguments = ["run", "--skip-build", "--package-path", workspaceDir.path, "Script"]
    runProcess.currentDirectoryURL = workspaceDir

    try runProcess.run()
    runProcess.waitUntilExit()

    if runProcess.terminationStatus != 0 {
        exit(runProcess.terminationStatus)
    }
}

// MARK: - Output Copy

func copyOutput(_ config: RunnerConfig) throws {
    guard let outputDir = config.outputDir else { return }

    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser

    // Find the actual output directory (iCloud or local)
    let iCloudDir = home
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        .appendingPathComponent("OCCTSwiftScripts/output")
    let localDir = home.appendingPathComponent(".occtswift-scripts/output")
    let sourceDir = fm.fileExists(atPath: iCloudDir.path) ? iCloudDir : localDir

    guard fm.fileExists(atPath: sourceDir.path) else { return }

    let destURL = URL(fileURLWithPath: outputDir)
    try fm.createDirectory(at: destURL, withIntermediateDirectories: true)

    let contents = try fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)
    for file in contents {
        let dest = destURL.appendingPathComponent(file.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: file, to: dest)
    }

    print("Output copied to \(outputDir)")
}

// MARK: - Main

let config = parseArgs()

do {
    try ensureWorkspace()
    _ = try prepareScript(config)
    try buildAndRun()
    try copyOutput(config)
} catch {
    fatal("\(error.localizedDescription)")
}
