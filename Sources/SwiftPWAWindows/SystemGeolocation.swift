#if os(Windows)
    import CWebView2Shim
    import Foundation
    import SwiftPWACore

    /// WinRT `Windows.Devices.Geolocation` ``GeolocationProvider``.
    ///
    /// Built-in WinRT, so unlike the Phi Silica tier there's no NuGet package,
    /// no Windows App SDK bootstrapper and nothing to provision — it rides the
    /// `WindowsApp.lib` the shim target already links.
    ///
    /// Access is governed by Settings → Privacy & security → Location. An
    /// unpackaged Win32 app doesn't get its own entry there; it's covered by
    /// the desktop-apps toggle, so a refusal usually means location is off for
    /// desktop apps generally rather than for this app specifically. The error
    /// message says as much, because "denied" on its own would send someone
    /// looking for a per-app switch that isn't there.
    public final class SystemGeolocation: GeolocationProvider, @unchecked Sendable {
        public init() {}

        public func current(_ request: GeoRequest) async throws -> GeoFix {
            let timeout = UInt32((request.timeoutSeconds ?? 20) * 1000)
            let maximumAge = UInt32(request.maximumAgeSeconds ?? 0)
            let high: Int32 = request.accuracy == .high ? 1 : 0

            return try await withCheckedThrowingContinuation { continuation in
                let box = Unmanaged.passRetained(WinGeoBox { result in
                    continuation.resume(with: result)
                }).toOpaque()
                // The shim's one-shot blocks on the WinRT operation, so it runs
                // off the calling task's thread rather than stalling it. The
                // box is laundered through `UInt` because a raw pointer isn't
                // `Sendable` and this closure escapes.
                let boxBits = UInt(bitPattern: box)
                DispatchQueue.global().async {
                    guard let box = UnsafeMutableRawPointer(bitPattern: boxBits) else { return }
                    swiftpwa_wingeo_get_position(high, timeout, maximumAge, winGeoTrampoline, box)
                    Unmanaged<WinGeoBox>.fromOpaque(box).release()
                }
            }
        }

        public func watch(_ request: GeoRequest) -> AsyncThrowingStream<GeoFix, any Error> {
            let high: Int32 = request.accuracy == .high ? 1 : 0
            return AsyncThrowingStream { continuation in
                let box = Unmanaged.passRetained(WinGeoBox { result in
                    switch result {
                    case let .success(fix): continuation.yield(fix)
                    case let .failure(error): continuation.finish(throwing: error)
                    }
                }).toOpaque()

                guard let session = swiftpwa_wingeo_watch(high, winGeoTrampoline, box) else {
                    // The shim already reported why through the callback, which
                    // finished the stream; just drop the box.
                    Unmanaged<WinGeoBox>.fromOpaque(box).release()
                    return
                }
                // Laundered through `UInt` for strict concurrency — a raw
                // pointer isn't `Sendable` and this closure escapes.
                // The session is an opaque struct declared only in the header,
                // so it imports as `OpaquePointer` rather than a typed pointer.
                let sessionBits = UInt(bitPattern: session)
                let boxBits = UInt(bitPattern: box)
                continuation.onTermination = { _ in
                    if let session = OpaquePointer(bitPattern: sessionBits) {
                        swiftpwa_wingeo_stop(session)
                    }
                    if let box = UnsafeMutableRawPointer(bitPattern: boxBits) {
                        Unmanaged<WinGeoBox>.fromOpaque(box).release()
                    }
                }
            }
        }
    }

    /// Heap box carrying the result handler across the C boundary.
    final class WinGeoBox: @unchecked Sendable {
        let deliver: (Result<GeoFix, any Error>) -> Void
        init(_ deliver: @escaping (Result<GeoFix, any Error>) -> Void) {
            self.deliver = deliver
        }
    }

    /// `@convention(c)` callback shared by the one-shot and the watch.
    let winGeoTrampoline: @convention(c) (
        UnsafePointer<swiftpwa_geo_position>?,
        swiftpwa_wingeo_error_kind,
        UnsafePointer<wchar_t>?,
        UnsafeMutableRawPointer?
    ) -> Void = { position, kind, message, userData in
        guard let userData else { return }
        let box = Unmanaged<WinGeoBox>.fromOpaque(userData).takeUnretainedValue()

        guard let position else {
            let text = message.map { String(decodingCString: $0, as: UTF16.self) }
                ?? "location failed"
            let error: GeoError = switch kind {
            case SWIFTPWA_WINGEO_DENIED: .denied(text)
            case SWIFTPWA_WINGEO_TIMEOUT: .timedOut(text)
            default: .unavailable(text)
            }
            box.deliver(.failure(error.bridgeError))
            return
        }
        let fix = position.pointee
        box.deliver(.success(GeoFix(
            latitude: fix.latitude,
            longitude: fix.longitude,
            accuracy: fix.accuracy,
            altitude: fix.has_altitude != 0 ? fix.altitude : nil,
            altitudeAccuracy: fix.has_altitude_accuracy != 0 ? fix.altitude_accuracy : nil,
            heading: fix.has_heading != 0 ? fix.heading : nil,
            speed: fix.has_speed != 0 ? fix.speed : nil,
            timestamp: fix.timestamp
        )))
    }
#endif
