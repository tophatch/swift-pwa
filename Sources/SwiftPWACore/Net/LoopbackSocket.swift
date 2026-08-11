import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Android)
    // Bionic, not glibc — `canImport(Glibc)` is false on Android, which is how
    // this file (and with it all of SwiftPWACore) stopped compiling there.
    import Android
#elseif canImport(WinSDK)
    import WinSDK
#endif

#if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(WinSDK)

    // A loopback TCP socket handle. POSIX file descriptors are `Int32`;
    // Winsock's `SOCKET` is an unsigned pointer-sized handle — so the type
    // (and its "invalid" sentinel, and the read/write/close calls) differ per
    // platform. `LoopbackSocket` hides all of that behind one small surface so
    // its callers stay platform-agnostic.
    #if canImport(WinSDK)
        package typealias SocketHandle = SOCKET
    #else
        package typealias SocketHandle = Int32
    #endif

    /// The one place loopback TCP callers touch the platform socket API. Every
    /// function maps to BSD sockets on Darwin/Glibc and to Winsock on Windows;
    /// nothing else in the dev server or the app driver carries a platform `#if`.
    ///
    /// Two consumers, in opposite directions: `swift-pwa dev`'s live-reload
    /// server (the CLI listens, the app connects) and the app driver (the app
    /// listens, the CLI connects). Both want loopback TCP rather than a Unix
    /// socket, which keeps AF_UNIX-on-Windows out of the picture entirely.
    package enum LoopbackSocket {
        #if canImport(WinSDK)
            package static let invalid = INVALID_SOCKET
        #else
            package static let invalid: SocketHandle = -1
        #endif

        package static func isValid(_ s: SocketHandle) -> Bool {
            s != invalid
        }

        /// Winsock requires a one-time `WSAStartup` before any socket call;
        /// POSIX needs nothing. Safe to call more than once (each startup is
        /// refcounted; a short-lived CLI never needs the matching cleanup).
        package static func startup() {
            #if canImport(WinSDK)
                var wsa = WSADATA()
                _ = WSAStartup(0x0202, &wsa) // request Winsock 2.2
            #endif
        }

        /// A blocking IPv4 TCP stream socket, or `invalid` on failure.
        package static func makeStreamSocket() -> SocketHandle {
            // glibc alone types SOCK_STREAM as an enum; Darwin, Bionic and
            // WinSDK all import it as an Int32 already. 0 = default protocol
            // for the family, i.e. TCP.
            #if canImport(Glibc)
                return socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            #else
                return socket(AF_INET, SOCK_STREAM, 0)
            #endif
        }

        package static func setReuseAddr(_ s: SocketHandle) {
            var yes: Int32 = 1
            #if canImport(WinSDK)
                _ = withUnsafeBytes(of: &yes) {
                    setsockopt(
                        s,
                        SOL_SOCKET,
                        SO_REUSEADDR,
                        $0.bindMemory(to: CChar.self).baseAddress,
                        socklen_t($0.count)
                    )
                }
            #else
                setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            #endif
        }

        /// A `sockaddr_in` for `127.0.0.1:<port>`, built without naming the
        /// platform-divergent `sin_addr` union member (`s_addr` on POSIX vs
        /// `S_un.S_addr` on Windows) or the `sin_family` field type — both are
        /// written as raw bytes.
        private static func loopbackAddr(port: UInt16) -> sockaddr_in {
            var addr = sockaddr_in()
            // AF_INET into sin_family, whatever that field's integer type is.
            withUnsafeMutableBytes(of: &addr.sin_family) { raw in
                var fam = UInt16(AF_INET) // fits both UInt8 (Darwin) and UInt16
                withUnsafeBytes(of: &fam) {
                    raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count)))
                }
            }
            addr.sin_port = port.bigEndian
            // 127.0.0.1 in network byte order, written straight into sin_addr.
            var netAddr = UInt32(0x7F00_0001).bigEndian
            withUnsafeMutableBytes(of: &addr.sin_addr) { raw in
                withUnsafeBytes(of: &netAddr) { raw.copyMemory(from: $0) }
            }
            return addr
        }

        /// Bind the socket to `127.0.0.1:<port>` (`port == 0` → OS-assigned).
        package static func bindLoopback(_ s: SocketHandle, port: UInt16) -> Bool {
            var addr = loopbackAddr(port: port)
            return withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }

        /// Connect the socket to `127.0.0.1:<port>`. The driver client half —
        /// the dev server only ever listens.
        package static func connectLoopback(_ s: SocketHandle, port: UInt16) -> Bool {
            var addr = loopbackAddr(port: port)
            return withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }

        package static func startListening(_ s: SocketHandle, backlog: Int32) -> Bool {
            listen(s, backlog) == 0
        }

        /// The port the socket actually bound (resolves an OS-assigned `0`).
        package static func boundPort(_ s: SocketHandle) -> UInt16 {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
            }
            return UInt16(bigEndian: addr.sin_port)
        }

        package static func acceptOne(_ s: SocketHandle) -> SocketHandle {
            accept(s, nil, nil)
        }

        /// Poll one socket for readability. Returns `> 0` when readable, `0` on
        /// timeout, `< 0` on error — same contract as `poll`/`WSAPoll`.
        package static func pollReadable(_ s: SocketHandle, timeoutMs: Int32) -> Int32 {
            #if canImport(WinSDK)
                var pfd = WSAPOLLFD(fd: s, events: Int16(POLLRDNORM), revents: 0)
                let r = WSAPoll(&pfd, 1, timeoutMs)
                if r <= 0 { return r }
                return (pfd.revents & Int16(POLLRDNORM)) != 0 ? 1 : 0
            #else
                var pfd = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
                let r = poll(&pfd, 1, timeoutMs)
                if r <= 0 { return r }
                return (pfd.revents & Int16(POLLIN)) != 0 ? 1 : 0
            #endif
        }

        /// Read up to `buf.count` bytes into `buf`; returns the count read
        /// (`0` = peer closed, `< 0` = error).
        package static func recvInto(_ s: SocketHandle, _ buf: inout [UInt8]) -> Int {
            buf.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                #if canImport(WinSDK)
                    return Int(recv(s, base.bindMemory(to: CChar.self, capacity: raw.count), Int32(raw.count), 0))
                #else
                    return recv(s, base, raw.count, 0)
                #endif
            }
        }

        /// Write all of `bytes[offset...]` (`count` bytes), looping over short
        /// writes. Returns `false` if any write fails (dead socket).
        package static func sendAll(_ s: SocketHandle, _ bytes: [UInt8], offset: Int, count: Int) -> Bool {
            bytes.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return true }
                var sent = 0
                while sent < count {
                    let ptr = base + offset + sent
                    let remaining = count - sent
                    #if canImport(WinSDK)
                        let n = Int(send(s, ptr.bindMemory(to: CChar.self, capacity: remaining), Int32(remaining), 0))
                    #else
                        let n = send(s, ptr, remaining, 0)
                    #endif
                    if n <= 0 { return false }
                    sent += n
                }
                return true
            }
        }

        package static func closeSocket(_ s: SocketHandle) {
            #if canImport(WinSDK)
                _ = closesocket(s)
            #else
                _ = close(s)
            #endif
        }
    }

#endif
