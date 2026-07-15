#if os(Linux)
    import CZstd
    import Foundation
    import SwiftPWACore

    // NOTE: The body of this type is shared verbatim with the GTK4 copy
    // (Sources/SwiftPWAGTK4/) and the Windows copy (Sources/SwiftPWAWindows/) —
    // only the `#if os(...)` guard differs. The three backends are separate
    // Swift targets, so the apply logic can't live in one file; keep all three
    // copies in sync.

    /// Reconstruct a delta (binary-patch) update artifact via the vendored,
    /// compiled-in Zstandard decoder (the `CZstd` C target — a single-file
    /// decoder amalgamation, no system libzstd / DLL). The runtime counterpart
    /// to the publish-side `swift-pwa updater diff`/`patch` (which shell out to
    /// the `zstd` CLI): a shipped app can't assume a `zstd` binary on `PATH`,
    /// so it calls the decoder API directly. The exact sequence (window-log-max
    /// → refPrefix → decompressDCtx) is what reconstructs a `zstd --patch-from`
    /// frame; it was validated byte-for-byte against real patch bytes before
    /// landing. Design: docs/proposals/delta-updates.md.
    enum ZstdPatch {
        // Sentinel return values of ZSTD_getFrameContentSize (macros that
        // don't reliably import into Swift): UNKNOWN = (0ULL - 1),
        // ERROR = (0ULL - 2).
        private static let contentSizeUnknown = UInt64.max
        private static let contentSizeError = UInt64.max - 1

        /// Reconstruct the new artifact from `base` (the installed artifact
        /// bytes) and `patch` (a `zstd --patch-from` frame). Throws a
        /// `BridgeError(code: .handler)` on any libzstd failure so the
        /// caller can fall back to a full download.
        static func apply(base: Data, patch: Data) throws -> Data {
            let contentSize: UInt64 = patch.withUnsafeBytes { raw in
                ZSTD_getFrameContentSize(raw.baseAddress, raw.count)
            }
            guard contentSize != contentSizeUnknown, contentSize != contentSizeError else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "delta patch: unusable frame content size"
                )
            }
            guard let dctx = ZSTD_createDCtx() else {
                throw BridgeError(code: BridgeError.handler, message: "delta patch: ZSTD_createDCtx failed")
            }
            defer { ZSTD_freeDCtx(dctx) }
            // patch-from uses a window large enough to reference the whole
            // base; permit it (the CLI diff caps at windowLog 30).
            _ = ZSTD_DCtx_setParameter(dctx, ZSTD_d_windowLogMax, 31)

            var out = Data(count: Int(contentSize))
            let written: Int = try out.withUnsafeMutableBytes { outRaw in
                try base.withUnsafeBytes { baseRaw in
                    let rp = ZSTD_DCtx_refPrefix(dctx, baseRaw.baseAddress, baseRaw.count)
                    if ZSTD_isError(rp) != 0 {
                        throw BridgeError(
                            code: BridgeError.handler,
                            message: "delta patch: refPrefix failed (\(String(cString: ZSTD_getErrorName(rp))))"
                        )
                    }
                    return try patch.withUnsafeBytes { patchRaw in
                        let got = ZSTD_decompressDCtx(
                            dctx,
                            outRaw.baseAddress, outRaw.count,
                            patchRaw.baseAddress, patchRaw.count
                        )
                        if ZSTD_isError(got) != 0 {
                            throw BridgeError(
                                code: BridgeError.handler,
                                message: "delta patch: reconstruction failed (\(String(cString: ZSTD_getErrorName(got))))"
                            )
                        }
                        return got
                    }
                }
            }
            guard written == Int(contentSize) else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "delta patch: reconstructed \(written) bytes, expected \(contentSize)"
                )
            }
            return out
        }
    }
#endif
