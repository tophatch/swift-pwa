import Foundation
#if os(Windows)
    import WinSDK
#endif

/// Web assets embedded as an **overlay appended to the executable**, for
/// single-file Windows distribution. The CLI's `--single-file` bundler appends
/// the overlay after `swift build`; at runtime the app reads its own `.exe` and
/// serves these bytes from memory (Windows WebView2 backend) — so a portable
/// app ships as **one `.exe`** with no sibling `web/` folder.
///
/// Appending data after a PE image is the standard "overlay" technique
/// (installers/self-extractors do it): the Windows loader ignores trailing
/// bytes, so the exe still runs. Layout, appended after the image:
/// ```
///   [asset bytes …][TOC json][UInt64-LE assetRegionLen][UInt64-LE tocLen][8-byte magic]
/// ```
/// Read back-to-front: last 8 bytes are the magic, the preceding two
/// little-endian `UInt64`s give the TOC and asset-region lengths, and the TOC
/// (a JSON array of `{path, offset, length}`) maps each web file to a slice of
/// the asset region.
///
/// Single-file is Windows-only today (it's the one platform whose artifact is a
/// loose folder; `.app`/AppImage/`.ipa`/`.apk` already bundle `web/` inside), so
/// `current` resolves to `nil` everywhere else.
public struct EmbeddedWebAssets: Sendable {
    /// Normalized request path (`"foo/bar.js"`, no leading slash) → bytes.
    private let assets: [String: Data]

    public init(assets: [String: Data]) { self.assets = assets }

    /// 8-byte trailer marker identifying a swift-pwa web overlay.
    static let magic: [UInt8] = Array("SPWA1WEB".utf8)

    public var isEmpty: Bool {
        assets.isEmpty
    }

    /// Bytes for a request path (leading slash optional; query/fragment
    /// stripped). `nil` if the overlay has no such file.
    public func data(for path: String) -> Data? { assets[Self.normalize(path)] }

    /// Content type for a path, reusing the shared extension→MIME table.
    public func mimeType(for path: String) -> String {
        AssetProvider.mimeType(for: URL(fileURLWithPath: Self.normalize(path)))
    }

    static func normalize(_ path: String) -> String {
        var p = path
        if let q = p.firstIndex(of: "?") { p = String(p[..<q]) }
        if let h = p.firstIndex(of: "#") { p = String(p[..<h]) }
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    // MARK: - Encode (bundler side)

    private struct Entry: Codable { let path: String; let offset: Int; let length: Int }

    /// Build the overlay blob to append to the exe. `files` are
    /// `(relativePath, bytes)` pairs, e.g. `("index.html", …)`,
    /// `("assets/app.js", …)`.
    public static func makeOverlay(files: [(path: String, data: Data)]) throws -> Data {
        var region = Data()
        var entries: [Entry] = []
        for file in files {
            entries.append(Entry(path: normalize(file.path), offset: region.count, length: file.data.count))
            region.append(file.data)
        }
        let toc = try JSONEncoder().encode(entries)
        var out = Data()
        out.append(region)
        out.append(toc)
        out.append(contentsOf: le64(UInt64(region.count)))
        out.append(contentsOf: le64(UInt64(toc.count)))
        out.append(contentsOf: magic)
        return out
    }

    // MARK: - Decode (runtime side)

    /// Parse the overlay (if any) from an executable on disk.
    public static func read(fromExecutableAt url: URL) -> EmbeddedWebAssets? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size > 24 else { return nil }

        let footerLen: Int64 = 24 // regionLen(8) + tocLen(8) + magic(8)
        try? handle.seek(toOffset: UInt64(size - footerLen))
        guard let footer = try? handle.read(upToCount: Int(footerLen)),
              footer.count == Int(footerLen) else { return nil }
        let f = [UInt8](footer)
        guard Array(f[16 ..< 24]) == magic else { return nil }
        let regionLen = readLE64(f, 0)
        let tocLen = readLE64(f, 8)

        let tocStart = size - footerLen - Int64(tocLen)
        let regionStart = tocStart - Int64(regionLen)
        guard regionStart >= 0 else { return nil }

        try? handle.seek(toOffset: UInt64(tocStart))
        guard let tocData = try? handle.read(upToCount: Int(tocLen)), tocData.count == Int(tocLen),
              let entries = try? JSONDecoder().decode([Entry].self, from: tocData) else { return nil }
        try? handle.seek(toOffset: UInt64(regionStart))
        guard let regionData = try? handle.read(upToCount: Int(regionLen)),
              regionData.count == Int(regionLen) else { return nil }

        let region = [UInt8](regionData)
        var assets: [String: Data] = [:]
        for entry in entries {
            guard entry.offset >= 0, entry.length >= 0, entry.offset + entry.length <= region.count else { return nil }
            assets[entry.path] = Data(region[entry.offset ..< (entry.offset + entry.length)])
        }
        return EmbeddedWebAssets(assets: assets)
    }

    /// The current process's embedded web assets, if its executable carries an
    /// overlay. `nil` on a normal (folder) build and on non-Windows hosts.
    /// Resolved once, lazily.
    public static let current: EmbeddedWebAssets? = {
        guard let exe = executablePath() else { return nil }
        let parsed = read(fromExecutableAt: URL(fileURLWithPath: exe))
        return (parsed?.isEmpty == false) ? parsed : nil
    }()

    /// Whether the running app is a single-file build (has an embedded
    /// overlay). Cheap to call after the first `current` resolution.
    public static var isPresent: Bool {
        current != nil
    }

    private static func executablePath() -> String? {
        #if os(Windows)
            var buf = [UInt16](repeating: 0, count: 32768)
            let n = GetModuleFileNameW(nil, &buf, UInt32(buf.count))
            guard n > 0 else { return nil }
            return String(decoding: buf[0 ..< Int(n)], as: UTF16.self)
        #else
            return nil // single-file distribution is Windows-only
        #endif
    }

    // MARK: - Little-endian helpers

    private static func le64(_ v: UInt64) -> [UInt8] { (0 ..< 8).map { UInt8((v >> ($0 * 8)) & 0xFF) } }
    private static func readLE64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0 ..< 8 { v |= UInt64(bytes[offset + i]) << (i * 8) }
        return v
    }
}
