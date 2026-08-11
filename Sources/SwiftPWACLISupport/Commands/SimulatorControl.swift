import ArgumentParser
import Foundation

/// The `simctl` side of the iOS Simulator: pick a device, boot it, install, run.
///
/// Shared by `deploy` (install + launch and hand back) and `drive` (launch,
/// read the driver handshake off the app's console, tear down) so both agree on
/// how a simulator is chosen — the sole booted one, else the first available,
/// with `--device` naming one explicitly.
///
/// **Every call is bounded.** `simctl` doesn't reliably fail: on a cold machine
/// it wedges, and a CI job spent 39 minutes inside one `boot` with no output and
/// no exit before it was killed. A timeout turns that into a diagnosable error
/// instead of a run that looks like a slow build, and the phase lines below turn
/// "nothing happened" into "we got as far as booting".
enum SimulatorControl {
    /// Generous, because a first boot on a cold machine legitimately takes a
    /// while — but finite, because the failure mode is "never returns".
    static let bootTimeout: TimeInterval = 300
    static let commandTimeout: TimeInterval = 120

    struct Device {
        let udid: String
        let name: String
        let state: String
    }

    /// Choose the simulator to target: an explicit `--device` (name or UDID,
    /// booted on demand), else a booted one, else the first available iOS
    /// simulator (booted on demand).
    ///
    /// `log` is where phase lines go — stdout for `deploy`, the lifecycle log
    /// for `drive` (whose stdout carries the verb's result).
    static func resolve(explicit device: String?, log: FileHandle = .standardOutput) async throws -> String {
        let devices = try await listAvailable()
        if let device {
            guard let match = devices.first(where: { $0.udid == device || $0.name == device }) else {
                throw ValidationError(
                    "no available iOS simulator matches --device \"\(device)\". "
                        + "List them with `xcrun simctl list devices available`."
                )
            }
            try await bootIfNeeded(match, log: log)
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
        try await bootIfNeeded(pick, log: log)
        return pick.udid
    }

    static func bootIfNeeded(_ device: Device, log: FileHandle = .standardOutput) async throws {
        guard device.state != "Booted" else { return }
        log.writeQuietly(Data("→ booting simulator \(device.name) (up to \(Int(bootTimeout))s)\n".utf8))
        // `simctl boot` on an already-booted device errors; we guarded on state.
        // A *failure* here is tolerable (the install below will say so more
        // clearly), but a hang is not — hence the bound.
        try await Shell.run(
            "/usr/bin/env", ["xcrun", "simctl", "boot", device.udid],
            stdoutTo: log, timeout: bootTimeout
        )
        // Boot returns before the device finishes coming up; `bootstatus -b`
        // waits for that, and is the difference between installing into a
        // half-booted device and installing into a ready one.
        try? await Shell.run(
            "/usr/bin/env", ["xcrun", "simctl", "bootstatus", device.udid, "-b"],
            stdoutTo: log, timeout: bootTimeout
        )
    }

    static func listAvailable() async throws -> [Device] {
        let json = try await Shell.capture(
            "/usr/bin/env", ["xcrun", "simctl", "list", "devices", "available", "-j"],
            timeout: commandTimeout, discardStderr: true
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

    static func install(app: URL, on udid: String, log: FileHandle = .standardOutput) async throws {
        try await Shell.run(
            "/usr/bin/env", ["xcrun", "simctl", "install", udid, app.path],
            stdoutTo: log, timeout: commandTimeout
        )
    }

    /// Kill a running instance, ignoring "wasn't running".
    ///
    /// Synchronous on purpose: `drive`'s teardown runs from `MCPServer.deinit`,
    /// which can't await. Bounded for the same reason as everything else here —
    /// teardown must not be able to outlive the run it's tearing down.
    static func terminate(bundleID: String, on udid: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xcrun", "simctl", "terminate", udid, bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
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
