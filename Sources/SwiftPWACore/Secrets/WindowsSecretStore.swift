#if os(Windows)
    import Foundation
    import WinSDK

    /// The Windows ``SecretStore``, backed by **DPAPI**
    /// (`CryptProtectData` / `CryptUnprotectData`, user scope). Each secret is
    /// encrypted with a key derived from the current user's login credentials
    /// (machine-bound, per-user) and written as an opaque blob under
    /// `%LOCALAPPDATA%\<service>\secrets\`. No extra dependency — DPAPI is
    /// in-box (`Crypt32`).
    ///
    /// This is dependency-free and simplest; the Windows Credential Manager is a
    /// possible future alternative (more user-discoverable). Wire it into the
    /// plugin: `ctx.use(SecretsPlugin(WindowsSecretStore()))`.
    public struct WindowsSecretStore: SecretStore {
        private let directory: URL

        /// - Parameter service: namespaces the on-disk secrets folder so two
        ///   apps don't collide. Defaults to `"swift-pwa"`; pass your app id.
        public init(service: String = "swift-pwa") {
            let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"]
                .map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = base.appendingPathComponent(service, isDirectory: true)
                .appendingPathComponent("secrets", isDirectory: true)
        }

        public func get(_ key: String) async throws -> String? {
            let url = fileURL(for: key)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let blob: Data
            do {
                blob = try Data(contentsOf: url)
            } catch {
                throw BridgeError(code: BridgeError.secrets, message: "read failed for \"\(key)\": \(error)")
            }
            guard let plain = Self.unprotect([UInt8](blob)) else {
                throw BridgeError(code: BridgeError.secrets, message: "DPAPI decrypt failed for \"\(key)\"")
            }
            return String(decoding: plain, as: UTF8.self)
        }

        public func set(_ key: String, _ value: String) async throws {
            guard let cipher = Self.protect([UInt8](value.utf8)) else {
                throw BridgeError(code: BridgeError.secrets, message: "DPAPI encrypt failed for \"\(key)\"")
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(cipher).write(to: fileURL(for: key), options: .atomic)
            } catch {
                throw BridgeError(code: BridgeError.secrets, message: "write failed for \"\(key)\": \(error)")
            }
        }

        public func delete(_ key: String) async throws {
            let url = fileURL(for: key)
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                throw BridgeError(code: BridgeError.secrets, message: "delete failed for \"\(key)\": \(error)")
            }
        }

        /// Map a key to a filesystem-safe filename by hex-encoding its UTF-8 —
        /// so any key (spaces, slashes, unicode) is a valid, collision-free name.
        private func fileURL(for key: String) -> URL {
            let hex = key.utf8.map { String(format: "%02x", $0) }.joined()
            return directory.appendingPathComponent(hex).appendingPathExtension("bin")
        }

        // DPAPI wrappers. `CRYPTPROTECT_UI_FORBIDDEN` (0x1) keeps it silent —
        // never a UI prompt (this runs on a background bridge task).
        private static let uiForbidden: DWORD = 0x1

        private static func protect(_ plain: [UInt8]) -> [UInt8]? {
            crypt(plain) { inBlob, outBlob in
                CryptProtectData(inBlob, nil, nil, nil, nil, uiForbidden, outBlob)
            }
        }

        private static func unprotect(_ cipher: [UInt8]) -> [UInt8]? {
            crypt(cipher) { inBlob, outBlob in
                CryptUnprotectData(inBlob, nil, nil, nil, nil, uiForbidden, outBlob)
            }
        }

        /// Shared plumbing: feed `input` as a `DATA_BLOB`, run `op`, and copy the
        /// output blob out (freeing the DPAPI-allocated buffer with `LocalFree`).
        private static func crypt(
            _ input: [UInt8],
            _ op: (_ inBlob: PDATA_BLOB, _ outBlob: PDATA_BLOB) -> WindowsBool
        ) -> [UInt8]? {
            var mutableInput = input
            return mutableInput.withUnsafeMutableBufferPointer { buf -> [UInt8]? in
                var inBlob = DATA_BLOB(cbData: DWORD(buf.count), pbData: buf.baseAddress)
                var outBlob = DATA_BLOB()
                guard op(&inBlob, &outBlob).boolValue else { return nil }
                defer { LocalFree(outBlob.pbData) }
                return Array(UnsafeBufferPointer(start: outBlob.pbData, count: Int(outBlob.cbData)))
            }
        }
    }
#endif
