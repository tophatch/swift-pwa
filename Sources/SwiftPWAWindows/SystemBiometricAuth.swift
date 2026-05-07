#if os(Windows)
    import CWebView2Shim
    import Foundation
    import SwiftPWACore

    /// Windows `BiometricAuth` backed by
    /// `Windows.Security.Credentials.UI.UserConsentVerifier`. The
    /// WinRT call surface is wrapped in a C++/WinRT shim
    /// (`swiftpwa_biometric_*`) that bridges
    /// `IAsyncOperation<...>` into a callback; we resume a Swift
    /// continuation from the callback the same way the GTK4 dialog
    /// adapter does.
    ///
    /// **Interop interface.** Verification goes through the
    /// `IUserConsentVerifierInterop` desktop-app variant
    /// (`RequestVerificationForWindowAsync`) rather than the static
    /// WinRT entry point. The static method assumes package identity;
    /// from an unpackaged Win32 EXE it kicks off the verification
    /// (camera indicator turns on) but never shows its prompt UI, so
    /// the async operation hangs forever and the JS side never gets
    /// a reply. The interop variant takes an explicit HWND parent —
    /// the shim picks `GetForegroundWindow()` so the prompt anchors
    /// to whatever the user is looking at — and brings up the dialog
    /// as a modal. With this in place the plugin works equally well
    /// from packaged (MSIX) and unpackaged builds.
    public final class SystemBiometricAuth: BiometricAuth, @unchecked Sendable {
        public init() {}

        public func canAuthenticate() async throws -> BiometricAvailability {
            let raw = await withCheckedContinuation { (cont: CheckedContinuation<
                swiftpwa_biometric_availability,
                Never
            >) in
                let box = AvailabilityContinuation(cont: cont)
                let opaque = Unmanaged.passRetained(box).toOpaque()
                swiftpwa_biometric_check_availability(availabilityCallback, opaque)
            }
            switch raw {
            case SWIFTPWA_BIO_AVAILABLE:
                return BiometricAvailability(available: true, kind: .windowsHello)
            case SWIFTPWA_BIO_DEVICE_NOT_PRESENT:
                return BiometricAvailability(available: false, kind: .none, reason: "no Windows Hello device")
            case SWIFTPWA_BIO_NOT_CONFIGURED:
                return BiometricAvailability(
                    available: false,
                    kind: .none,
                    reason: "Windows Hello not configured for this user"
                )
            case SWIFTPWA_BIO_DISABLED_BY_POLICY:
                return BiometricAvailability(available: false, kind: .none, reason: "Windows Hello disabled by policy")
            case SWIFTPWA_BIO_DEVICE_BUSY:
                return BiometricAvailability(available: false, kind: .none, reason: "Windows Hello device busy")
            default:
                return BiometricAvailability(
                    available: false,
                    kind: .none,
                    reason: "Windows Hello availability check failed"
                )
            }
        }

        public func authenticate(_ args: BiometricAuthArgs) async throws -> BiometricAuthResult {
            let raw = await withCheckedContinuation { (cont: CheckedContinuation<
                swiftpwa_biometric_verify_result,
                Never
            >) in
                let box = VerifyContinuation(cont: cont)
                let opaque = Unmanaged.passRetained(box).toOpaque()
                args.reason.withCString(encodedAs: UTF16.self) { msgW in
                    swiftpwa_biometric_request_verification(msgW, verifyCallback, opaque)
                }
            }
            switch raw {
            case SWIFTPWA_BIO_VERIFIED:
                return BiometricAuthResult(authenticated: true)
            case SWIFTPWA_BIO_VERIFY_CANCELED:
                return BiometricAuthResult(authenticated: false, error: "cancelled")
            case SWIFTPWA_BIO_VERIFY_RETRIES_EXHAUSTED:
                return BiometricAuthResult(authenticated: false, error: "retries exhausted")
            case SWIFTPWA_BIO_VERIFY_DEVICE_NOT_PRESENT:
                throw BridgeError(code: BridgeError.handler, message: "Windows Hello device not present")
            case SWIFTPWA_BIO_VERIFY_NOT_CONFIGURED:
                throw BridgeError(code: BridgeError.handler, message: "Windows Hello not configured for this user")
            case SWIFTPWA_BIO_VERIFY_DISABLED_BY_POLICY:
                throw BridgeError(code: BridgeError.handler, message: "Windows Hello disabled by policy")
            case SWIFTPWA_BIO_VERIFY_DEVICE_BUSY:
                throw BridgeError(code: BridgeError.handler, message: "Windows Hello device busy")
            default:
                throw BridgeError(code: BridgeError.handler, message: "Windows Hello verification failed")
            }
        }
    }

    // MARK: - Continuation boxes

    /// Heap-boxed continuation handed to the C shim as user_data.
    /// Reconstituted in the trampoline via `Unmanaged.fromOpaque`,
    /// resumed exactly once.
    private final class AvailabilityContinuation: @unchecked Sendable {
        let cont: CheckedContinuation<swiftpwa_biometric_availability, Never>
        init(cont: CheckedContinuation<swiftpwa_biometric_availability, Never>) {
            self.cont = cont
        }
    }

    private final class VerifyContinuation: @unchecked Sendable {
        let cont: CheckedContinuation<swiftpwa_biometric_verify_result, Never>
        init(cont: CheckedContinuation<swiftpwa_biometric_verify_result, Never>) {
            self.cont = cont
        }
    }

    /// `@convention(c)` trampoline. The WinRT thread the callback
    /// fires on is whatever pool the OS picked — Swift's continuation
    /// is `Sendable`, so resuming from it is fine.
    private let availabilityCallback: @convention(c) (
        swiftpwa_biometric_availability, UnsafeMutableRawPointer?
    ) -> Void = { result, userData in
        guard let userData else { return }
        let raw = UInt(bitPattern: userData)
        guard let opaque = UnsafeMutableRawPointer(bitPattern: raw) else { return }
        let box = Unmanaged<AvailabilityContinuation>.fromOpaque(opaque).takeRetainedValue()
        box.cont.resume(returning: result)
    }

    private let verifyCallback: @convention(c) (
        swiftpwa_biometric_verify_result, UnsafeMutableRawPointer?
    ) -> Void = { result, userData in
        guard let userData else { return }
        let raw = UInt(bitPattern: userData)
        guard let opaque = UnsafeMutableRawPointer(bitPattern: raw) else { return }
        let box = Unmanaged<VerifyContinuation>.fromOpaque(opaque).takeRetainedValue()
        box.cont.resume(returning: result)
    }
#endif
