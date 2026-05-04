import ArgumentParser
import Foundation

struct Dev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Run the app with PWA_DEV_SERVER pointing at a JS dev server."
    )

    @Option(help: "URL of the dev server to load instead of bundled assets.")
    var server: String = "http://localhost:5173"

    func run() async throws {
        let task = Process()
        task.executableURL = try Bash.which("swift")
        task.arguments = ["run"]
        var env = ProcessInfo.processInfo.environment
        env["PWA_DEV_SERVER"] = server
        task.environment = env
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw ExitCode(task.terminationStatus)
        }
    }
}

enum Bash {
    static func which(_ name: String) throws -> URL {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else {
            throw ValidationError("Could not find executable: \(name)")
        }
        return URL(fileURLWithPath: path)
    }
}
