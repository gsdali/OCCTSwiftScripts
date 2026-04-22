// occtkit — multi-call dispatcher for the OCCTSwift script suite.
//
// Dispatch order:
//   1. argv[0] basename matches a subcommand → use it (busybox-style symlinks).
//   2. argv[1] matches a subcommand → use it, pass remaining args.
//   3. otherwise: print help.
//
// `--serve` (anywhere in args) switches the resolved subcommand into a stdin
// JSONL request loop. Each line is `{"args": [...]}`; the response is a JSON
// object on stdout. Per-line errors emit `{"error": "..."}` and the loop
// continues. EOF on stdin → exit 0.

import Foundation

@MainActor
func printHelp() {
    var msg = "occtkit — OCCTSwift script suite\n\nUSAGE:\n  occtkit <subcommand> [args...]\n  occtkit <subcommand> --serve   (read JSONL requests on stdin)\n\nSUBCOMMANDS:\n"
    for cmd in Registry.all {
        msg += "  \(cmd.name.padding(toLength: 20, withPad: " ", startingAt: 0))\(cmd.summary)\n"
    }
    print(msg, terminator: "")
}

func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

@MainActor
func dispatch(_ cmd: any Subcommand.Type, args: [String]) -> Int32 {
    if args.contains("--serve") {
        return runServe(cmd: cmd)
    }
    do {
        return try cmd.run(args: args)
    } catch {
        writeError("Error: \(error.localizedDescription)")
        return 1
    }
}

struct ServeRequest: Decodable {
    let args: [String]
}

@MainActor
func runServe(cmd: any Subcommand.Type) -> Int32 {
    let stdin = FileHandle.standardInput
    var buffer = Data()
    while true {
        let chunk = stdin.availableData
        if chunk.isEmpty {
            return 0
        }
        buffer.append(chunk)
        while let nlIdx = buffer.firstIndex(of: 0x0A) {
            let lineRange = buffer.startIndex..<nlIdx
            let line = buffer.subdata(in: lineRange)
            buffer.removeSubrange(buffer.startIndex...nlIdx)
            handleServeLine(cmd: cmd, line: line)
        }
    }
}

@MainActor
func handleServeLine(cmd: any Subcommand.Type, line: Data) {
    if line.isEmpty || line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
        return
    }
    do {
        let req = try JSONDecoder().decode(ServeRequest.self, from: line)
        _ = try cmd.run(args: req.args)
    } catch {
        let payload: [String: String] = ["error": "\(error.localizedDescription)"]
        if let data = try? JSONEncoder().encode(payload) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }
}

// MARK: - Entry

let argv = CommandLine.arguments
let exe = (argv.first as NSString?)?.lastPathComponent ?? "occtkit"

if let direct = Registry.find(exe) {
    exit(dispatch(direct, args: Array(argv.dropFirst())))
}

let rest = Array(argv.dropFirst())
guard let first = rest.first, !first.hasPrefix("-") else {
    printHelp()
    exit(rest.first == "--help" || rest.first == "-h" ? 0 : (rest.isEmpty ? 0 : 1))
}

guard let cmd = Registry.find(first) else {
    writeError("Unknown subcommand: \(first)")
    printHelp()
    exit(1)
}

exit(dispatch(cmd, args: Array(rest.dropFirst())))
