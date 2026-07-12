#if os(Android)
    import Foundation
    import SwiftPWACore

    /// Download a single file through the Kotlin `net.downloadFile` RPC **with
    /// byte-level progress**.
    ///
    /// Swift's `URLSession` (libcurl + BoringSSL) has no injectable CA trust
    /// store on Android, so the on-device model backends
    /// (`StableDiffusionBackend`, `LaMaBackend`, `MobileSAMBackend`) route their
    /// weight downloads through Android's own HTTP stack via this RPC — system
    /// TLS, checksum-verified, cache-reusing.
    ///
    /// The RPC is request/response, so on its own it can only report progress
    /// once (at completion) — a multi-GB model then freezes the progress bar on
    /// its largest file (a 1.7 GB UNet reads as a hang). To match the smooth,
    /// byte-level bar the Apple/desktop `ModelDownloader` gives, this pairs the
    /// one-shot kickoff RPC with a host-event side channel: the Kotlin read loop
    /// pushes periodic `{ bytesDone, totalBytes? }` frames on a per-call channel
    /// (see `AndroidHostEventRouter`), which are forwarded to `onProgress` while
    /// the download runs. The kickoff RPC's reply remains the terminal signal
    /// (it carries the final `bytesWritten`), so no terminal host-event frame is
    /// needed. This mirrors the `GeminiNanoBackend` streaming pattern.
    ///
    /// `onProgress(bytesDone, totalBytes?)` reports the *per-file* byte count
    /// (`totalBytes` from the HTTP `Content-Length`, or `nil` when the server
    /// omits it). Callers that track an aggregate bar across several files add
    /// their own base offset, exactly as the Apple/desktop path does.
    public enum AndroidFileDownload {
        /// Fetch `url` to `destPath`, verifying `sha256` (when non-nil).
        /// Returns the number of bytes written. Throws a `BridgeError` on
        /// failure (HTTP error, checksum mismatch, I/O).
        @discardableResult
        public static func download(
            url: String,
            destPath: String,
            sha256: String?,
            headers: [String: String] = [:],
            onProgress: @escaping @Sendable (Int64, Int64?) -> Void
        ) async throws -> Int64 {
            let channel = nextChannel()
            AndroidHostEventRouter.subscribe(channel: channel) { data in
                guard let frame = try? JSONDecoder().decode(ProgressFrame.self, from: data) else { return }
                onProgress(frame.bytesDone ?? 0, frame.totalBytes)
            }
            // The kickoff reply is terminal (all progress frames precede it on
            // Kotlin's single download thread), so unsubscribe once it returns.
            defer { AndroidHostEventRouter.unsubscribe(channel: channel) }

            let result = try await AndroidRPC.call(
                "net.downloadFile",
                DownloadFileArgs(
                    url: url,
                    destPath: destPath,
                    sha256: sha256,
                    channel: channel,
                    headers: headers.isEmpty ? nil : headers
                ),
                as: DownloadFileResult.self
            )
            return result.bytesWritten
        }

        // MARK: - Wire types

        private struct DownloadFileArgs: Encodable {
            let url: String
            let destPath: String
            let sha256: String?
            /// Host-event channel the Kotlin side pushes progress frames on.
            /// Optional on the Kotlin side — an absent/empty channel disables
            /// progress (the plain request/response behavior).
            let channel: String
            /// Optional request headers (auth, etc.); nil ⇒ none sent.
            let headers: [String: String]?
        }

        private struct DownloadFileResult: Decodable {
            let bytesWritten: Int64
        }

        private struct ProgressFrame: Decodable {
            let bytesDone: Int64?
            let totalBytes: Int64?
        }

        // MARK: - Channel naming

        /// A process-unique channel per download. The host-event router is
        /// single-slot per channel, so concurrent downloads must not collide.
        private static func nextChannel() -> String {
            "net.downloadFile.\(counter.next())"
        }

        private static let counter = ChannelCounter()

        private final class ChannelCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value: UInt64 = 0
            func next() -> UInt64 {
                lock.withLock {
                    value &+= 1
                    return value
                }
            }
        }
    }
#endif
