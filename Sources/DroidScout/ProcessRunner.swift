import Foundation

struct CommandResult: Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
}

enum ProcessRunner {
    static func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval = 30
    ) async -> CommandResult {
        await Task.detached(priority: .utility) {
            runSync(executablePath: executablePath, arguments: arguments, timeout: timeout)
        }.value
    }

    static func runSync(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval = 30
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return CommandResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }

        let stdoutReader = PipeReader(fileHandle: stdoutPipe.fileHandleForReading)
        let stderrReader = PipeReader(fileHandle: stderrPipe.fileHandleForReading)
        stdoutReader.start()
        stderrReader.start()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                process.waitUntilExit()
                stdoutReader.finish()
                stderrReader.finish()
                return CommandResult(stdout: "", stderr: "Timed out after \(Int(timeout))s", exitCode: -9)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        stdoutReader.finish()
        stderrReader.finish()
        let stdoutData = stdoutReader.data
        let stderrData = stderrReader.data
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return CommandResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }
}

private final class PipeReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var storage = Data()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [fileHandle] in
            let data = fileHandle.readDataToEndOfFile()
            self.lock.lock()
            self.storage = data
            self.lock.unlock()
            self.group.leave()
        }
    }

    func finish() {
        group.wait()
    }

}

extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var shellEscaped: String {
        "'\(replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

extension URL {
    var pathString: String { path(percentEncoded: false) }
}
