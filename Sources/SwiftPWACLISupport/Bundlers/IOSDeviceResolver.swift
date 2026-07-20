import ArgumentParser
import Foundation

/// Resolves a physical iOS/iPadOS device to target, over `xcrun devicectl list
/// devices`. Shared between `deploy` (which installs/launches on the resolved
/// device) and the free-team profile minter (which builds a throwaway project
/// against it to register the device + mint a profile) — the two agree on the
/// selection rules, so they share one implementation.
///
/// The JSON parse is a pure function so it's unit-testable without a device.
enum IOSDeviceResolver {
    struct Device: Equatable {
        let udid: String
        let name: String
        let connected: Bool
    }

    /// Pure parse of `devicectl list devices --json-output -` → the physical
    /// iOS/iPadOS devices. `connected` is derived from
    /// `connectionProperties.tunnelState`.
    static func parse(_ json: String) -> [Device] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]]
        else { return [] }
        return devices.compactMap { dev in
            let hw = dev["hardwareProperties"] as? [String: Any]
            let platform = (hw?["platform"] as? String) ?? ""
            guard platform == "iOS" || platform == "iPadOS" else { return nil }
            guard let udid = hw?["udid"] as? String else { return nil }
            let name = (dev["deviceProperties"] as? [String: Any])?["name"] as? String ?? udid
            let tunnel = (dev["connectionProperties"] as? [String: Any])?["tunnelState"] as? String
            return Device(udid: udid, name: name, connected: tunnel == "connected")
        }
    }

    static func list() async throws -> [Device] {
        let json = try await Shell.capture(
            "/usr/bin/env", ["xcrun", "devicectl", "list", "devices", "--json-output", "-"], discardStderr: true
        )
        return parse(json)
    }

    /// Choose the device to target. An explicit `--device` (UDID or name) wins
    /// and is passed through even if `devicectl` currently lists it as
    /// disconnected (it can bring the connection up). Otherwise pick the sole
    /// *connected* device, erroring clearly on none or several — never a silent
    /// pick.
    static func resolve(explicit: String?) async throws -> Device {
        let devices = try await list()
        if let explicit {
            if let match = devices.first(where: { $0.udid == explicit || $0.name == explicit }) {
                return match
            }
            // Not in the list — trust the user; devicectl resolves udid/name/dns.
            return Device(udid: explicit, name: explicit, connected: false)
        }
        let connected = devices.filter(\.connected)
        switch connected.count {
        case 1:
            return connected[0]
        case 0:
            let paired = devices.isEmpty
                ? "none paired"
                : "paired but not connected: " + devices.map { "\($0.name) (\($0.udid))" }.joined(separator: ", ")
            throw ValidationError(
                "no connected iOS device found (\(paired)). Plug in and unlock a device (trust this Mac), "
                    + "or pass --device <udid|name>."
            )
        default:
            throw ValidationError(
                "\(connected.count) iOS devices are connected: "
                    + connected.map { "\($0.name) (\($0.udid))" }.joined(separator: ", ")
                    + ". Pass --device <udid|name> to choose one."
            )
        }
    }
}
