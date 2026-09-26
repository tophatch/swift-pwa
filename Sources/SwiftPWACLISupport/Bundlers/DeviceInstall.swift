import Foundation

/// Installs a built `.app` on a physical iOS/iPadOS device over `devicectl`.
/// Shared by `deploy` and `drive`, which both install straight after a signed
/// build.
///
/// That build takes minutes, and a device paired over the network can reset
/// its connection in the meantime: `devicectl` then fails with CoreDeviceError
/// 4000 ("A connection to this device could not be established"), and running
/// the same install again straight afterwards succeeds (#260). So a dropped
/// connection is retried once. Every other failure is reported on the first
/// attempt, with the reason read out of `devicectl`'s own document (see
/// ``DeviceCtlError``).
enum DeviceInstall {
    struct Failure: Error, CustomStringConvertible {
        let device: String
        /// The most specific sentence in `devicectl`'s error chain, if any.
        let reason: String?
        let retried: Bool
        /// What to do next, which only the calling command knows.
        var recovery: String?

        var description: String {
            let why = reason.map { " — \($0)" } ?? " — see devicectl's error above"
            let line = "couldn't install on \(device)\(why)\(retried ? " (after one retry)" : "")"
            return recovery.map { "\(line)\n\($0)" } ?? line
        }
    }

    /// `xcrun` is the tool that runs `devicectl`; tests pass a stand-in that
    /// fails on cue, since a real dropped connection can't be produced on demand.
    static func install(
        app: URL, on device: IOSDeviceResolver.Device, stdoutTo: FileHandle? = nil, xcrun: String = "xcrun"
    ) async throws {
        var retried = false
        while true {
            let report = FileManager.default.temporaryDirectory
                .appendingPathComponent("swift-pwa-install-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: report) }
            do {
                try await Shell.run(
                    "/usr/bin/env",
                    [
                        xcrun, "devicectl", "device", "install", "app",
                        "--device", device.udid, "--json-output", report.path, app.path
                    ],
                    stdoutTo: stdoutTo
                )
                return
            } catch {
                let chain = DeviceCtlError.chain(fromJSON: (try? Data(contentsOf: report)) ?? Data())
                if !retried, DeviceCtlError.isDroppedConnection(chain) {
                    retried = true
                    let line = "swift-pwa: the connection to \(device.name) dropped; retrying the install once.\n"
                    (stdoutTo ?? FileHandle.standardOutput).writeQuietly(Data(line.utf8))
                    continue
                }
                throw Failure(device: device.name, reason: DeviceCtlError.reason(chain), retried: retried)
            }
        }
    }
}
