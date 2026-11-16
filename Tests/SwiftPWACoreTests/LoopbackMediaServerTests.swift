import Foundation
@testable import SwiftPWACore
import Testing

/// The loopback server WebKitGTK's media player reads the app's files from
/// (#349), driven over real sockets: the player is a real HTTP client, so a
/// pure test of the response head would miss framing and hang-ups.
@Suite("LoopbackMediaServer")
struct LoopbackMediaServerTests {
    @Test("a GET answers the whole file with the headers a media player needs")
    func wholeFile() throws {
        let site = try Site()
        defer { site.remove() }
        let reply = try site.request("GET", "clip.bin")
        #expect(reply.status == 200)
        #expect(reply.headers["content-length"] == "\(site.clip.count)")
        #expect(reply.headers["accept-ranges"] == "bytes")
        #expect(reply.headers["cache-control"] == "no-store")
        #expect(reply.headers["access-control-allow-origin"] == nil)
        #expect(reply.body == site.clip)
    }

    @Test("a Range answers 206 with that slice")
    func range() throws {
        let site = try Site()
        defer { site.remove() }
        let reply = try site.request("GET", "clip.bin", headers: ["Range: bytes=10-19"])
        #expect(reply.status == 206)
        #expect(reply.headers["content-range"] == "bytes 10-19/\(site.clip.count)")
        #expect(reply.body == site.clip[10 ..< 20])

        let past = try site.request("GET", "clip.bin", headers: ["Range: bytes=\(site.clip.count)-"])
        #expect(past.status == 416)
        #expect(past.headers["content-range"] == "bytes */\(site.clip.count)")
    }

    @Test("HEAD answers the headers without a body")
    func head() throws {
        let site = try Site()
        defer { site.remove() }
        let reply = try site.request("HEAD", "clip.bin")
        #expect(reply.status == 200)
        #expect(reply.headers["content-length"] == "\(site.clip.count)")
        #expect(reply.body.isEmpty)
    }

    @Test("CORS answers the app's own origin and nobody else")
    func cors() throws {
        let site = try Site()
        defer { site.remove() }
        let own = try site.request("GET", "clip.bin", headers: ["Origin: pwa://localhost"])
        #expect(own.headers["access-control-allow-origin"] == "pwa://localhost")
        #expect(own.headers["vary"] == "Origin")
        let foreign = try site.request("GET", "clip.bin", headers: ["Origin: https://example.com"])
        #expect(foreign.headers["access-control-allow-origin"] == nil)
    }

    @Test("without the token, from a foreign Host, or by another method, nothing is served")
    func refusals() throws {
        let site = try Site()
        defer { site.remove() }
        #expect(try site.raw("GET /clip.bin HTTP/1.1\r\nHost: 127.0.0.1:\(site.port)\r\n\r\n").status == 404)
        #expect(try site
            .raw("GET /\(String(repeating: "0", count: 32))/clip.bin HTTP/1.1\r\nHost: 127.0.0.1:\(site.port)\r\n\r\n")
            .status == 404)
        #expect(try site.request("GET", "clip.bin", host: "rebound.example:\(site.port)").status == 404)
        let post = try site.request("POST", "clip.bin")
        #expect(post.status == 405)
        #expect(post.headers["allow"] == "GET, HEAD")
        #expect(try site.request("GET", "missing.bin").status == 404)
        #expect(try site.request("GET", "../outside.bin").status == 404)
        #expect(try site.request("GET", "%2E%2E/outside.bin").status == 404)
    }

    @Test("a directory mounted after the server started is served")
    func laterMount() throws {
        let site = try Site()
        defer { site.remove() }
        let pack = site.scratch.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try Data("pack".utf8).write(to: pack.appendingPathComponent("song.mp3"))
        #expect(try site.request("GET", "packs/song.mp3").status == 404)
        site.provider.mount(pack, at: "/packs")
        let reply = try site.request("GET", "packs/song.mp3")
        #expect(reply.status == 200)
        #expect(reply.headers["content-type"] == "audio/mpeg")
        #expect(reply.body == Data("pack".utf8))
    }

    /// A player hangs up mid-body on every seek. On POSIX that write raises
    /// SIGPIPE, whose default action would end this test process.
    @Test("a client that hangs up mid-body leaves the server serving")
    func hangUp() throws {
        let site = try Site(clipSize: 8 * 1024 * 1024)
        defer { site.remove() }
        for _ in 0 ..< 3 {
            let socket = try site.connect()
            let request = Array("GET \(site.path("clip.bin")) HTTP/1.1\r\nHost: 127.0.0.1:\(site.port)\r\n\r\n".utf8)
            _ = LoopbackSocket.sendAll(socket, request, offset: 0, count: request.count)
            var buffer = [UInt8](repeating: 0, count: 1024)
            _ = LoopbackSocket.recvInto(socket, &buffer)
            LoopbackSocket.closeSocket(socket)
        }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(try site.request("GET", "clip.bin", headers: ["Range: bytes=0-3"]).status == 206)
    }

    @Test("several connections are answered at once")
    func concurrent() async throws {
        let site = try Site()
        defer { site.remove() }
        // One that never finishes its request mustn't hold the others up.
        let idle = try site.connect()
        defer { LoopbackSocket.closeSocket(idle) }
        let statuses = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0 ..< 6 {
                group.addTask { try site.request("GET", "clip.bin", headers: ["Range: bytes=\(i)-\(i + 9)"]).status }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(statuses == Array(repeating: 206, count: 6))
    }

    // MARK: -

    private struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    private struct Site: @unchecked Sendable {
        let scratch: URL
        let provider: AssetProvider
        let server: LoopbackMediaServer
        let clip: Data
        let port: UInt16
        let basePath: String

        init(clipSize: Int = 64 * 1024) throws {
            scratch = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swift-pwa-media-server-\(UUID().uuidString)")
            let web = scratch.appendingPathComponent("web")
            try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
            clip = Data((0 ..< clipSize).map { UInt8(truncatingIfNeeded: $0 * 7) })
            try clip.write(to: web.appendingPathComponent("clip.bin"))
            try Data("secret".utf8).write(to: scratch.appendingPathComponent("outside.bin"))
            provider = AssetProvider(root: web)
            server = try LoopbackMediaServer.start(provider: provider)
            let base = try #require(URL(string: server.baseURL))
            port = try UInt16(#require(base.port))
            basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
            #expect(server.baseURL.hasPrefix("http://127.0.0.1:"))
        }

        func remove() {
            server.stop()
            try? FileManager.default.removeItem(at: scratch)
        }

        func path(_ relative: String) -> String { basePath + relative }

        func connect() throws -> SocketHandle {
            let socket = LoopbackSocket.makeStreamSocket()
            guard LoopbackSocket.connectLoopback(socket, port: port) else {
                LoopbackSocket.closeSocket(socket)
                throw LoopbackServerError.socket("connect failed")
            }
            return socket
        }

        func request(
            _ method: String,
            _ relative: String,
            headers: [String] = [],
            host: String? = nil
        ) throws -> Reply {
            let lines = ["\(method) \(path(relative)) HTTP/1.1", "Host: \(host ?? "127.0.0.1:\(port)")"] + headers
            return try raw(lines.joined(separator: "\r\n") + "\r\n\r\n")
        }

        /// Send `text` and read until the server closes, which it does after
        /// every response.
        func raw(_ text: String) throws -> Reply {
            let socket = try connect()
            defer { LoopbackSocket.closeSocket(socket) }
            let bytes = Array(text.utf8)
            guard LoopbackSocket.sendAll(socket, bytes, offset: 0, count: bytes.count) else {
                throw LoopbackServerError.socket("send failed")
            }
            var received = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = LoopbackSocket.recvInto(socket, &buffer)
                if n <= 0 { break }
                received.append(contentsOf: buffer[0 ..< n])
            }
            let separator: [UInt8] = [13, 10, 13, 10]
            guard let end = (0 ... max(0, received.count - 4)).first(where: {
                received.count >= $0 + 4 && Array(received[$0 ..< $0 + 4]) == separator
            }) else { throw LoopbackServerError.socket("no response head") }
            let head = String(decoding: received[0 ..< end], as: UTF8.self).components(separatedBy: "\r\n")
            let status = Int(head[0].split(separator: " ")[1]) ?? 0
            var fields: [String: String] = [:]
            for line in head.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            return Reply(status: status, headers: fields, body: Data(received[(end + 4)...]))
        }
    }
}
