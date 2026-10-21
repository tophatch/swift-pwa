import Foundation

#if canImport(QuickLookThumbnailing)
    import ImageIO
    import QuickLookThumbnailing
    import UniformTypeIdentifiers

    /// QuickLook's thumbnail, never its icon: a page falls back to its own
    /// cover from nil, and can't tell a generic document icon from a cover.
    ///
    /// QuickLook asks a cloud file's provider rather than downloading it.
    /// Measured on macOS with a 7.3 MB PDF in a Google Drive for desktop
    /// folder, not downloaded: a 128×128 page-one thumbnail in about a second,
    /// and the file still dataless afterwards (#320).
    enum PlatformThumbnail {
        static func make(path: String, maxSize: Int) async throws -> FsThumbnail? {
            let request = QLThumbnailGenerator.Request(
                fileAt: URL(fileURLWithPath: path),
                size: CGSize(width: maxSize, height: maxSize),
                scale: 1,
                representationTypes: .thumbnail
            )
            let image: CGImage
            do {
                image = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
            } catch is QLThumbnailError {
                // No generator for the type, or none that would answer
                // without the file: the normal case a page falls back from.
                return nil
            }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                png as CFMutableData, UTType.png.identifier as CFString, 1, nil
            ) else {
                throw BridgeError(code: BridgeError.handler, message: "fs.thumbnail: no PNG encoder")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "fs.thumbnail: encoding \(path)'s thumbnail failed"
                )
            }
            return FsThumbnail(png: png as Data, width: image.width, height: image.height)
        }
    }
#endif

#if os(Linux)
    import Crypto
    import Glibc

    /// The freedesktop thumbnail cache, then the thumbnailer the desktop
    /// installed for the file's type.
    ///
    /// Who makes thumbnails differs by desktop. GNOME runs the `.thumbnailer`
    /// entries itself and has no thumbnail service at all (measured on Ubuntu
    /// 26.04: no tumbler); XFCE runs tumbler, which reads the same entries. Both
    /// write the shared cache in `~/.cache/thumbnails`, keyed by the MD5 of the
    /// file's URI. So: a valid cached thumbnail, else the entry for the file's
    /// type, run directly, with what it draws stored in the cache for the file
    /// manager to reuse. A file on a FUSE or network mount — a GVFS Google
    /// Drive — gets the cache only, because a thumbnailer reads the whole file.
    enum PlatformThumbnail {
        static func make(path: String, maxSize: Int) async throws -> FsThumbnail? {
            let uri = URL(fileURLWithPath: path).absoluteString
            var info = stat()
            // A regular file: a folder or a device has no thumbnail here.
            guard stat(path, &info) == 0, info.st_mode & 0o170000 == 0o100000 else { return nil }
            let mtime = Int(info.st_mtim.tv_sec)
            let key = Insecure.MD5.hash(data: Data(uri.utf8)).map { String(format: "%02x", $0) }.joined()
            // The largest of the spec's sizes within maxSize; below 128 there is
            // none, so the thumbnail is drawn at maxSize and not cached.
            let bucket = ThumbnailCache.buckets.last { $0.size <= maxSize }
            if let bucket, let cached = ThumbnailCache.read(key: key, bucket: bucket, uri: uri, mtime: mtime) {
                return cached
            }
            if isRemote(path) {
                // What the file manager drew while the file was here, at a
                // smaller size if that's all there is.
                for smaller in ThumbnailCache.buckets.reversed() where smaller.size < (bucket?.size ?? 0) {
                    if let cached = ThumbnailCache.read(key: key, bucket: smaller, uri: uri, mtime: mtime) {
                        return cached
                    }
                }
                return nil
            }
            guard let mimeType = MimeGlobs.mimeType(forFileName: (path as NSString).lastPathComponent),
                  let thumbnailer = ThumbnailerEntry.find(for: mimeType)
            else { return nil }
            let size = bucket?.size ?? maxSize
            guard var png = try await thumbnailer.run(path: path, uri: uri, size: size),
                  var dimensions = PNGChunks.dimensions(png)
            else { return nil }
            // An entry may read the size as a width (atril's does: 256×331 for
            // a page asked for at 256), so once more at what fits.
            let longer = max(dimensions.width, dimensions.height)
            if longer > size {
                guard let refit = try await thumbnailer.run(path: path, uri: uri, size: size * size / longer),
                      let refitDimensions = PNGChunks.dimensions(refit),
                      max(refitDimensions.width, refitDimensions.height) <= size
                else { return nil }
                png = refit
                dimensions = refitDimensions
            }
            if let bucket {
                ThumbnailCache.write(png, key: key, bucket: bucket.name, uri: uri, mtime: mtime)
            }
            return FsThumbnail(png: png, width: dimensions.width, height: dimensions.height)
        }

        /// FUSE (GVFS, sshfs, rclone), NFS, SMB, 9p: the filesystem of the
        /// innermost mount holding `path`, from `/proc/self/mounts`.
        static func isRemote(_ path: String) -> Bool {
            guard let mounts = try? String(contentsOfFile: "/proc/self/mounts", encoding: .utf8) else { return false }
            let resolved = (path as NSString).resolvingSymlinksInPath
            var best: (point: String, type: String)?
            for line in mounts.split(separator: "\n") {
                let fields = line.split(separator: " ")
                guard fields.count >= 3 else { continue }
                // Spaces in a mount point are written as \040.
                let point = fields[1].replacingOccurrences(of: "\\040", with: " ")
                guard resolved == point || resolved.hasPrefix(point == "/" ? "/" : point + "/") else { continue }
                if point.count >= (best?.point.count ?? -1) { best = (point, String(fields[2])) }
            }
            guard let type = best?.type else { return false }
            return type.hasPrefix("fuse") || ["nfs", "nfs4", "cifs", "smb3", "smbfs", "9p", "ceph", "afs"]
                .contains(type)
        }
    }

    /// `~/.cache/thumbnails/<size>/<md5 of the URI>.png`, valid while its
    /// `Thumb::URI` names the file and its `Thumb::MTime` is the file's.
    enum ThumbnailCache {
        static let buckets: [(name: String, size: Int)] = [
            ("normal", 128), ("large", 256), ("x-large", 512), ("xx-large", 1024)
        ]

        static var root: URL {
            let env = ProcessInfo.processInfo.environment
            let cache = env["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? (NSHomeDirectory() as NSString).appendingPathComponent(".cache")
            return URL(fileURLWithPath: cache).appendingPathComponent("thumbnails")
        }

        static func read(key: String, bucket: (name: String, size: Int), uri: String, mtime: Int) -> FsThumbnail? {
            let file = root.appendingPathComponent(bucket.name).appendingPathComponent("\(key).png")
            // Larger than its size allows: drawn by an entry that overshot, and
            // not a bound a page can lay out against.
            guard let png = FileManager.default.contents(atPath: file.path),
                  let dimensions = PNGChunks.dimensions(png),
                  max(dimensions.width, dimensions.height) <= bucket.size
            else { return nil }
            let text = PNGChunks.text(png)
            // Seconds only: tumbler writes the fraction too ("1792563527.678858"),
            // which GLib's own check then rejects as invalid.
            guard text["Thumb::URI"] == uri,
                  text["Thumb::MTime"].flatMap({ Int($0.split(separator: ".").first ?? "") }) == mtime
            else { return nil }
            return FsThumbnail(png: png, width: dimensions.width, height: dimensions.height)
        }

        static func write(_ png: Data, key: String, bucket: String, uri: String, mtime: Int) {
            let dir = root.appendingPathComponent(bucket)
            // The spec's 0700: thumbnails show what's in private files.
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let tagged = PNGChunks.addingText(["Thumb::URI": uri, "Thumb::MTime": String(mtime)], to: png)
            let file = dir.appendingPathComponent("\(key).png")
            try? tagged.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// A file's MIME type from its name, by shared-mime-info's `globs2` — the
    /// database GIO reads, without GIO.
    enum MimeGlobs {
        static func mimeType(forFileName name: String) -> String? {
            let lowered = name.lowercased()
            var best: (weight: Int, length: Int, type: String)?
            for dir in XDGDataDirs.all {
                guard let text = try? String(contentsOfFile: dir + "/mime/globs2", encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                    let fields = line.split(separator: ":", omittingEmptySubsequences: false)
                    guard fields.count >= 3, let weight = Int(fields[0]), fields[2].hasPrefix("*.") else { continue }
                    let suffix = fields[2].dropFirst().lowercased()
                    guard !suffix.contains(where: { "*?[".contains($0) }), lowered.hasSuffix(suffix) else { continue }
                    // The heaviest glob, then the longest (`*.tar.gz` over `*.gz`);
                    // on a tie the more specific directory, which comes first.
                    if best.map({ (weight, suffix.count) > ($0.weight, $0.length) }) ?? true {
                        best = (weight, suffix.count, String(fields[1]))
                    }
                }
            }
            return best?.type
        }
    }

    enum XDGDataDirs {
        /// `$XDG_DATA_HOME`, then `$XDG_DATA_DIRS`, most specific first.
        static var all: [String] {
            let env = ProcessInfo.processInfo.environment
            let home = env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/share")
            let dirs = env["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/share:/usr/share"
            return [home] + dirs.split(separator: ":").map(String.init)
        }
    }

    /// A `[Thumbnailer Entry]` from `<data dir>/thumbnailers/*.thumbnailer`.
    struct ThumbnailerEntry {
        let exec: [String]

        static func find(for mimeType: String) -> ThumbnailerEntry? {
            for dir in XDGDataDirs.all {
                let folder = dir + "/thumbnailers"
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
                for name in names.sorted() where name.hasSuffix(".thumbnailer") {
                    guard let text = try? String(contentsOfFile: folder + "/" + name, encoding: .utf8) else { continue }
                    var fields: [String: String] = [:]
                    for line in text.split(separator: "\n") {
                        guard let eq = line.firstIndex(of: "=") else { continue }
                        fields[line[..<eq].trimmingCharacters(in: .whitespaces)] =
                            line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    }
                    guard let types = fields["MimeType"]?.split(separator: ";"),
                          types.contains(where: { $0 == mimeType }),
                          let exec = fields["Exec"], fields["TryExec"].map({ executable($0) != nil }) ?? true
                    else { continue }
                    return ThumbnailerEntry(exec: tokenize(exec))
                }
            }
            return nil
        }

        /// `program`'s path: itself when absolute, else the first on `PATH`.
        static func executable(_ program: String) -> String? {
            if program.hasPrefix("/") {
                return FileManager.default.isExecutableFile(atPath: program) ? program : nil
            }
            let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            return path.split(separator: ":").map { "\($0)/\(program)" }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }

        /// The desktop-entry `Exec` quoting: words split on spaces, double
        /// quotes grouping, backslash escaping inside them.
        static func tokenize(_ exec: String) -> [String] {
            var words: [String] = []
            var word = ""
            var quoted = false
            var escaped = false
            var started = false
            for ch in exec {
                if escaped { word.append(ch); escaped = false; continue }
                if quoted, ch == "\\" { escaped = true; continue }
                if ch == "\"" { quoted.toggle(); started = true; continue }
                if ch == " ", !quoted {
                    if started { words.append(word); word = ""; started = false }
                    continue
                }
                word.append(ch)
                started = true
            }
            if started { words.append(word) }
            return words
        }

        /// The thumbnail it draws, or nil when it draws none (exits non-zero,
        /// writes nothing, or runs past 30 s).
        func run(path: String, uri: String, size: Int) async throws -> Data? {
            // GNOME's own name for the output: Ubuntu's AppArmor profiles let a
            // thumbnailer (papers-thumbnailer, measured) write only there.
            let output = "/tmp/.gnome_desktop_thumbnail.swiftpwa-\(UUID().uuidString).png"
            defer { try? FileManager.default.removeItem(atPath: output) }
            var arguments = exec.map { word -> String in
                var out = ""
                var percent = false
                for ch in word {
                    guard percent else {
                        if ch == "%" { percent = true } else { out.append(ch) }
                        continue
                    }
                    percent = false
                    switch ch {
                    case "s": out += String(size)
                    case "u": out += uri
                    case "i": out += path
                    case "o": out += output
                    case "%": out += "%"
                    default: break
                    }
                }
                return out
            }
            guard !arguments.isEmpty else { return nil }
            guard let program = Self.executable(arguments.removeFirst()) else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let status: Int32 = await withCheckedContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(returning: -1)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                    if process.isRunning { process.terminate() }
                }
            }
            guard status == 0 else { return nil }
            return FileManager.default.contents(atPath: output)
        }
    }

    /// The few PNG chunks the thumbnail cache is about.
    enum PNGChunks {
        static func dimensions(_ png: Data) -> (width: Int, height: Int)? {
            let bytes = [UInt8](png.prefix(24))
            guard bytes.count == 24, bytes[12 ..< 16] == [0x49, 0x48, 0x44, 0x52] else { return nil }
            func be32(_ at: Int) -> Int { bytes[at ..< at + 4].reduce(0) { $0 << 8 | Int($1) } }
            return (be32(16), be32(20))
        }

        static func text(_ png: Data) -> [String: String] {
            let bytes = [UInt8](png)
            var out: [String: String] = [:]
            var at = 8
            while at + 8 <= bytes.count {
                let length = bytes[at ..< at + 4].reduce(0) { $0 << 8 | Int($1) }
                let type = String(decoding: bytes[at + 4 ..< at + 8], as: UTF8.self)
                guard at + 12 + length <= bytes.count else { break }
                if type == "tEXt", let nul = bytes[at + 8 ..< at + 8 + length].firstIndex(of: 0) {
                    out[String(decoding: bytes[at + 8 ..< nul], as: UTF8.self)] =
                        String(decoding: bytes[nul + 1 ..< at + 8 + length], as: UTF8.self)
                }
                if type == "IEND" { break }
                at += 12 + length
            }
            return out
        }

        /// `png` with `tEXt` chunks for `entries` straight after `IHDR`.
        static func addingText(_ entries: [String: String], to png: Data) -> Data {
            let bytes = [UInt8](png)
            guard bytes.count > 33 else { return png }
            var out = Array(bytes[0 ..< 33])
            for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
                let body = [UInt8]("tEXt".utf8) + [UInt8](key.utf8) + [0] + [UInt8](value.utf8)
                out += be32(body.count - 4) + body + be32(Int(crc32(body)))
            }
            return Data(out + bytes[33...])
        }

        private static func be32(_ value: Int) -> [UInt8] {
            [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        }

        private static let crcTable: [UInt32] = (0 ..< 256).map { n in
            (0 ..< 8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }

        static func crc32(_ bytes: [UInt8]) -> UInt32 {
            ~bytes.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
        }
    }
#endif

#if os(Windows)
    import CWicShim

    /// The shell's thumbnail, the one Explorer shows (`SIIGBF_THUMBNAILONLY`,
    /// never the type's icon).
    ///
    /// Measured on Windows 11 (#320): a OneDrive placeholder isn't downloaded
    /// to draw one — the shell answers `WTS_E_DATAFILEUNAVAILABLE` and the file
    /// stays a placeholder — and a PDF has none without a reader that installs
    /// a thumbnail handler (Windows has no PDF thumbnailer of its own).
    enum PlatformThumbnail {
        static func make(path: String, maxSize: Int) async throws -> FsThumbnail? {
            var width: Int32 = 0
            var height: Int32 = 0
            var length: Int32 = 0
            var hresult: CLong = 0
            // The shell parses a path, and refuses one written with forward
            // slashes (E_INVALIDARG), which is how Foundation writes them.
            let native = path.replacingOccurrences(of: "/", with: "\\")
            let png = native.withCString(encodedAs: UTF16.self) {
                swiftpwa_shell_thumbnail_png($0, Int32(maxSize), &width, &height, &length, &hresult)
            }
            guard let png else {
                let code = UInt32(bitPattern: Int32(truncatingIfNeeded: hresult))
                // WTS_E_*: no handler for the type, a placeholder, a handler that
                // couldn't draw this file. STG_E_FILENOTFOUND: not in the cache.
                if code & 0xFFFF_FF00 == 0x8004_B200 || code == 0x8003_0002 { return nil }
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "fs.thumbnail: the shell failed for \(path) (HRESULT 0x\(String(code, radix: 16)))"
                )
            }
            defer { swiftpwa_wic_free(png) }
            return FsThumbnail(png: Data(bytes: png, count: Int(length)), width: Int(width), height: Int(height))
        }
    }
#endif
