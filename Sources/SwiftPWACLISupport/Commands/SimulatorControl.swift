import ArgumentParser
import Foundation

/// The `simctl` side of the iOS Simulator: pick a device, boot it, install, run.
///
/// Shared by `deploy` (install + launch and hand back) and `drive` (launch,
/// read the driver handshake off the app's console, tear down) so both agree on
/// how a simulator is chosen — the sole booted one, else the first available,
/// with `--device` naming one explicitly.
enum SimulatorControl {
    struct Device {
        let udid: String
        let name: String
        let state: String
    }

    /// Choose the simulator to target: an explicit `--device` (name or UDID,
    /// booted on demand), else a booted one, else the first available iOS
    /// simulator (booted on demand).
    static func resolve(explicit device: String?) async throws -> String {
        let devices = try await listAvailable()
        if let device {
            guard let match = devices.first(where: { $0.udid == device || $0.name == device }) else {
                throw ValidationError(
                    "no available iOS simulator matches --device \"\(device)\". "
                        + "List them with `xcrun simctl list devices available`."
                )
            }
            try await bootIfNeeded(match)
            return match.udid
        }
        if let booted = devices.first(where: { $0.state == "Booted" }) {
            return booted.udid
        }
        guard let pick = devices.first else {
            throw ValidationError(
                "no iOS simulators are available. Install a runtime (Xcode → Settings → Platforms → iOS) and retry."
            )
        }
        try await bootIfNeeded(pick)
        return pick.udid
    }

    static func bootIfNeeded(_ device: Device) async throws {
        guard device.state != "Booted" else { return }
        print("→ booting simulator \(device.name)")
        // `simctl boot` on an already-booted device errors; we guarded on state.
        try? await Shell.run("/usr/bin/env", ["xcrun", "simctl", "boot", device.udid])
    }

    static func listAvailable() async throws -> [Device] {
        let json = try await Shell.capture(
            "/usr/bin/env", ["xcrun", "simctl", "list", "devices", "available", "-j"], discardStderr: true
        )
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let byRuntime = obj["devices"] as? [String: [[String: Any]]]
        else { return [] }
        var result: [Device] = []
        for (runtime, list) in byRuntime where runtime.contains("iOS") {
            for entry in list {
                guard let udid = entry["udid"] as? String, let name = entry["name"] as? String else { continue }
                result.append(Device(udid: udid, name: name, state: entry["state"] as? String ?? "Shutdown"))
            }
        }
        return result
    }

    static func install(app: URL, on udid: String) async throws {
        try await Shell.run("/usr/bin/env", ["xcrun", "simctl", "install", udid, app.path])
    }

    /// Kill a running instance, ignoring "wasn't running".
    ///
    /// Synchronous on purpose: `drive`'s teardown runs from `MCPServer.deinit`,
    /// which can't await, and a `simctl terminate` is a sub-second call.
    static func terminate(bundleID: String, on udid: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xcrun", "simctl", "terminate", udid, bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Launch the app with its stdout attached to a pipe, so a caller can read
    /// what the app prints (the driver announces its port and token there).
    ///
    /// The app's environment comes from `SIMCTL_CHILD_*` variables — simctl
    /// strips that prefix and passes the rest to the launched process, which is
    /// the only way to get an env var into an app the simulator starts.
    /// `--console-pty` keeps simctl attached and relaying the app's output
    /// line-by-line; the returned Process is that relay, not the app, so
    /// stopping a run needs `terminate(bundleID:on:)` as well.
    static func launchProcess(
        bundleID: String, on udid: String, childEnvironment: [String: String], stdout: Pipe
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "xcrun", "simctl", "launch", "--console-pty", "--terminate-running-process", udid, bundleID
        ]
        var env = ProcessInfo.processInfo.environment
        for (key, value) in childEnvironment { env["SIMCTL_CHILD_\(key)"] = value }
        process.environment = env
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        try process.run()
        return process
    }
}
