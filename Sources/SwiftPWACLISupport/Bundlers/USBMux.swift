#if os(macOS)

    import Darwin
    import Foundation

    /// A minimal client for **usbmuxd**, the macOS daemon that relays TCP
    /// connections into a USB-attached iOS device.
    ///
    /// This exists because there is no other way in. The app driver's control
    /// socket binds the *device's* `127.0.0.1`, and nothing in `devicectl`
    /// forwards a port — its whole verb set is install/launch/copy/info, with no
    /// networking. usbmuxd is the long-standing mechanism (it's what `iproxy`
    /// wraps): the host asks it to `Connect` to a port, and its counterpart on
    /// the device dials `127.0.0.1:<port>` from the inside, which is exactly the
    /// address the driver is listening on.
    ///
    /// The protocol is property lists over a Unix socket, so speaking it
    /// directly costs ~100 lines and keeps this dependency-free — the
    /// alternative is vendoring libimobiledevice for one message type.
    ///
    /// **USB only.** A device paired over Wi-Fi doesn't appear here at all, and
    /// even when it does the network transport dials the device's *routable*
    /// address rather than its loopback. ``forwarder(toDeviceSerial:devicePort:)``
    /// says so in as many words rather than timing out.
    enum USBMux {
        /// usbmuxd's rendezvous socket. Stable across every macOS that ships
        /// `devicectl`.
        static let socketPath = "/var/run/usbmuxd"

        struct Device {
            /// usbmuxd's own handle for the device — what `Connect` takes. Not
            /// stable across replugs, so it's always looked up fresh.
            let id: Int
            /// The device UDID, which is what `devicectl` calls the same device.
            let serial: String
            /// `"USB"` or `"Network"`.
            let connectionType: String

            var isUSB: Bool {
                connectionType == "USB"
            }
        }

        enum Failure: Error, CustomStringConvertible {
            case unreachable(String)
            case refused(port: UInt16, code: Int)
            case malformed(String)

            var description: String {
                switch self {
                case let .unreachable(why):
                    "couldn't talk to usbmuxd at \(USBMux.socketPath): \(why)"
                case let .refused(port, code):
                    // 3 is usbmuxd's "connection refused" — nothing is listening
                    // on that port inside the device.
                    "the device refused a connection to port \(port) (usbmux result \(code))"
                case let .malformed(what):
                    "unexpected reply from usbmuxd: \(what)"
                }
            }
        }

        // MARK: - Wire format

        /// `length, version(1 = plist), message(8 = plist), tag` — all
        /// little-endian, with `length` counting this 16-byte header.
        private static let headerSize = 16
        private static let plistVersion: UInt32 = 1
        private static let plistMessage: UInt32 = 8

        /// Every request carries these; usbmuxd rejects a client that doesn't
        /// identify itself.
        private static var clientIdentity: [String: Any] {
            [
                "ClientVersionString": "swift-pwa",
                "ProgName": "swift-pwa",
                "kLibUSBMuxVersion": 3
            ]
        }

        private static func openSocket() throws -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure.unreachable("socket() failed (errno \(errno))") }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let path = Array(socketPath.utf8)
            guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else {
                throw Failure.unreachable("socket path too long")
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyBytes(from: path)
            }
            let connected = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else {
                close(fd)
                throw Failure.unreachable(
                    "connect() failed (errno \(errno)). Is this macOS with Xcode's device support installed?"
                )
            }
            return fd
        }

        private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
            var sent = 0
            while sent < bytes.count {
                let n = bytes.withUnsafeBytes { raw in
                    Darwin.send(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                }
                guard n > 0 else { throw Failure.unreachable("send() failed (errno \(errno))") }
                sent += n
            }
        }

        private static func readAll(_ fd: Int32, _ count: Int) throws -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: count)
            var got = 0
            while got < count {
                let n = buffer.withUnsafeMutableBytes { raw in
                    Darwin.recv(fd, raw.baseAddress!.advanced(by: got), count - got, 0)
                }
                guard n > 0 else { throw Failure.unreachable("usbmuxd closed the connection early") }
                got += n
            }
            return buffer
        }

        private static func send(_ payload: [String: Any], on fd: Int32, tag: UInt32 = 1) throws {
            let body = try PropertyListSerialization.data(
                fromPropertyList: payload, format: .xml, options: 0
            )
            var header = [UInt32(headerSize + body.count), plistVersion, plistMessage, tag]
            var bytes: [UInt8] = []
            for word in header {
                withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) }
            }
            header.removeAll()
            bytes.append(contentsOf: body)
            try writeAll(fd, bytes)
        }

        private static func receive(on fd: Int32) throws -> [String: Any] {
            let header = try readAll(fd, headerSize)
            let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
            guard length >= UInt32(headerSize), length < 8 * 1024 * 1024 else {
                throw Failure.malformed("implausible frame length \(length)")
            }
            let body = try readAll(fd, Int(length) - headerSize)
            guard let plist = try PropertyListSerialization.propertyList(
                from: Data(body), options: [], format: nil
            ) as? [String: Any] else {
                throw Failure.malformed("body wasn't a plist dictionary")
            }
            return plist
        }

        // MARK: - Requests

        /// Every device usbmuxd currently knows about.
        static func listDevices() throws -> [Device] {
            let fd = try openSocket()
            defer { close(fd) }
            var request = clientIdentity
            request["MessageType"] = "ListDevices"
            try send(request, on: fd)
            let reply = try receive(on: fd)
            guard let list = reply["DeviceList"] as? [[String: Any]] else { return [] }
            return list.compactMap { entry in
                guard let id = entry["DeviceID"] as? Int,
                      let properties = entry["Properties"] as? [String: Any],
                      let serial = properties["SerialNumber"] as? String
                else { return nil }
                return Device(
                    id: id,
                    serial: serial,
                    connectionType: (properties["ConnectionType"] as? String) ?? "Unknown"
                )
            }
        }

        /// The byte-swapped form usbmuxd wants a port in.
        ///
        /// It hands the value straight to the device as a network-order
        /// `sin_port` without converting it, so a host-order port silently
        /// addresses a different one — 56456 would ask for 35036, which almost
        /// always just refuses and looks like the app isn't listening.
        static func wirePort(_ port: UInt16) -> Int {
            Int((port << 8) & 0xFF00 | (port >> 8))
        }

        /// Open a relay to `port` on the device's loopback.
        ///
        /// The returned descriptor is a plain socket: write to it and the bytes
        /// arrive at whatever is listening inside the device. The caller owns it.
        static func connect(deviceID: Int, port: UInt16) throws -> Int32 {
            let fd = try openSocket()
            var request = clientIdentity
            request["MessageType"] = "Connect"
            request["DeviceID"] = deviceID
            // usbmuxd wants the port byte-swapped — it hands the value straight
            // to the device as a network-order `sin_port`.
            request["PortNumber"] = Int((port << 8) & 0xFF00 | (port >> 8))
            do {
                try send(request, on: fd)
                let reply = try receive(on: fd)
                let code = (reply["Number"] as? Int) ?? -1
                guard code == 0 else { throw Failure.refused(port: port, code: code) }
            } catch {
                close(fd)
                throw error
            }
            return fd
        }

        /// Resolve a device by UDID and hand back a forwarder for `devicePort`.
        ///
        /// Fails with the reason rather than a timeout: a device that's paired
        /// over Wi-Fi only is the common case, and it looks identical to a
        /// working setup until a connection silently never completes.
        static func forwarder(toDeviceSerial serial: String, devicePort: UInt16) throws -> USBMuxPortForwarder {
            let devices = try listDevices()
            guard let device = devices.first(where: { $0.serial == serial && $0.isUSB }) else {
                if devices.contains(where: { $0.serial == serial }) {
                    throw Failure.unreachable(
                        "the device is visible to usbmuxd but not over USB. Driving reaches the app "
                            + "through its own loopback, which only the USB transport can relay — "
                            + "connect the device with a cable (a charge-only cable won't do)."
                    )
                }
                throw Failure.unreachable(
                    "no USB-attached device with UDID \(serial). Installing and launching work over "
                        + "Wi-Fi, but driving needs a cable, because the app's control socket is on "
                        + "the device's loopback and only the USB transport relays to it."
                )
            }
            return try USBMuxPortForwarder(deviceID: device.id, devicePort: devicePort)
        }
    }

    /// Listens on this Mac's loopback and relays every connection into the
    /// device, so the rest of `drive` can connect to a local port and be unaware
    /// a device is involved at all.
    ///
    /// One thread per direction per connection: the driver serves one client at
    /// a time, so there are never many, and a blocking pump is far easier to
    /// reason about than a non-blocking one.
    final class USBMuxPortForwarder: @unchecked Sendable {
        /// The port on *this* machine to connect to.
        let localPort: UInt16

        private let deviceID: Int
        private let devicePort: UInt16
        private let listener: Int32
        private let lock = NSLock()
        private var stopped = false

        init(deviceID: Int, devicePort: UInt16) throws {
            self.deviceID = deviceID
            self.devicePort = devicePort

            // Everything is computed into locals first: the accept thread can't
            // be started until every stored property is initialised.
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw USBMux.Failure.unreachable("couldn't open a local socket (errno \(errno))")
            }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(0).bigEndian // any free port
            addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
            let bound = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 4) == 0 else {
                close(fd)
                throw USBMux.Failure.unreachable("couldn't listen on 127.0.0.1 (errno \(errno))")
            }

            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &actual) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &length)
                }
            }
            listener = fd
            localPort = actual.sin_port.bigEndian

            let forwarder = self
            Thread.detachNewThread { forwarder.acceptLoop() }
        }

        private func acceptLoop() {
            while true {
                let client = accept(listener, nil, nil)
                lock.lock()
                let done = stopped
                lock.unlock()
                if done {
                    if client >= 0 { close(client) }
                    return
                }
                guard client >= 0 else { continue }
                guard let upstream = try? USBMux.connect(deviceID: deviceID, port: devicePort) else {
                    close(client)
                    continue
                }
                Thread.detachNewThread { Self.pump(from: client, to: upstream) }
                Thread.detachNewThread { Self.pump(from: upstream, to: client) }
            }
        }

        /// Copy until either end hangs up, then shut *both* down — a half-closed
        /// relay leaves the other pump parked in `recv` forever.
        private static func pump(from source: Int32, to destination: Int32) {
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { raw in
                    recv(source, raw.baseAddress!, raw.count, 0)
                }
                guard n > 0 else { break }
                var sent = 0
                var failed = false
                while sent < n {
                    let written = buffer.withUnsafeBytes { raw in
                        send(destination, raw.baseAddress!.advanced(by: sent), n - sent, 0)
                    }
                    guard written > 0 else { failed = true; break }
                    sent += written
                }
                if failed { break }
            }
            shutdown(source, SHUT_RDWR)
            shutdown(destination, SHUT_RDWR)
        }

        func stop() {
            lock.lock()
            guard !stopped else { return lock.unlock() }
            stopped = true
            lock.unlock()
            shutdown(listener, SHUT_RDWR)
            close(listener)
        }
    }

#endif
