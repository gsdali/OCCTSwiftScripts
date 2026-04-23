// occtkit — multi-call dispatcher for the OCCTSwift script suite.
//
// Dispatch order:
//   1. argv[0] basename matches a subcommand → use it (busybox-style symlinks).
//   2. argv[1] matches a subcommand → use it, pass remaining args.
//   3. otherwise: print help.
//
// `--serve` (anywhere in args) switches the resolved subcommand into a stdin
// JSONL request loop. Each line is `{"args": [...]}`; the response is a JSON
// envelope on stdout:
//
//   {"ok": true|false, "exit": <int>, "stdout": "<captured>",
//    "stderr": "<captured>", "error": "<msg>"?}
//
// `error` is present only when ok=false. Exactly one envelope object is
// emitted per stdin request line — including for malformed requests, build
// failures, and `Run` invocations whose inner subprocess wrote to inherited
// stdout/stderr (those streams are captured into the envelope, not leaked
// to occtkit's own stdout). EOF on stdin → exit 0.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

struct ServeResponse: Encodable {
    let ok: Bool
    let exit: Int32
    let stdout: String
    let stderr: String
    let error: String?
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

    let req: ServeRequest
    do {
        req = try JSONDecoder().decode(ServeRequest.self, from: line)
    } catch {
        emitResponse(ServeResponse(
            ok: false, exit: 1, stdout: "", stderr: "",
            error: "invalid request JSON: \(error.localizedDescription)"
        ))
        return
    }

    let captured = captureOutput { try cmd.run(args: req.args) }
    emitResponse(ServeResponse(
        ok: captured.error == nil && captured.exit == 0,
        exit: captured.exit,
        stdout: String(data: captured.stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: captured.stderrData, encoding: .utf8) ?? "",
        error: captured.error
    ))
}

func emitResponse(_ response: ServeResponse) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(response) {
        // Write directly to FD 1 — the FileHandle.standardOutput cache may
        // be holding the saved-FD reference if we're called during cleanup.
        data.withUnsafeBytes { buf in
            _ = write(STDOUT_FILENO, buf.baseAddress, buf.count)
        }
        var newline: UInt8 = 0x0A
        _ = write(STDOUT_FILENO, &newline, 1)
    }
}

// MARK: - Output capture
//
// Redirect FDs 1 and 2 to temp files for the duration of `work()`, then
// restore them and read back what was written. Captures both in-process
// writes (FileHandle.standardOutput, print, stderr) and child-process
// inherited streams (Process subprocesses spawned by `Run`).
//
// Temp files are used over pipes to sidestep buffer-deadlock when the
// subcommand writes more than the pipe buffer (~64KB) before any drain.

struct CapturedOutput {
    let exit: Int32
    let error: String?
    let stdoutData: Data
    let stderrData: Data
}

func captureOutput(_ work: () throws -> Int32) -> CapturedOutput {
    let tmp = FileManager.default.temporaryDirectory
    let outURL = tmp.appendingPathComponent("occtkit-out-\(UUID().uuidString)")
    let errURL = tmp.appendingPathComponent("occtkit-err-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    defer {
        try? FileManager.default.removeItem(at: outURL)
        try? FileManager.default.removeItem(at: errURL)
    }

    let outFD = open(outURL.path, O_WRONLY)
    let errFD = open(errURL.path, O_WRONLY)
    guard outFD >= 0, errFD >= 0 else {
        if outFD >= 0 { close(outFD) }
        if errFD >= 0 { close(errFD) }
        return runWithoutCapture(work)
    }

    let savedOut = dup(STDOUT_FILENO)
    let savedErr = dup(STDERR_FILENO)
    dup2(outFD, STDOUT_FILENO)
    dup2(errFD, STDERR_FILENO)
    close(outFD)
    close(errFD)

    var exitCode: Int32 = 0
    var error: String? = nil
    do {
        exitCode = try work()
    } catch let e {
        error = e.localizedDescription
        exitCode = 1
    }

    fflush(stdout)
    fflush(stderr)

    dup2(savedOut, STDOUT_FILENO)
    dup2(savedErr, STDERR_FILENO)
    close(savedOut)
    close(savedErr)

    let outData = (try? Data(contentsOf: outURL)) ?? Data()
    let errData = (try? Data(contentsOf: errURL)) ?? Data()
    return CapturedOutput(exit: exitCode, error: error, stdoutData: outData, stderrData: errData)
}

func runWithoutCapture(_ work: () throws -> Int32) -> CapturedOutput {
    do {
        let exitCode = try work()
        return CapturedOutput(exit: exitCode, error: nil, stdoutData: Data(), stderrData: Data())
    } catch {
        return CapturedOutput(exit: 1, error: error.localizedDescription, stdoutData: Data(), stderrData: Data())
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
