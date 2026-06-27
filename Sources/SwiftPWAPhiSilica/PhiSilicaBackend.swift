#if os(Windows)
    import CPhiSilica
    import Foundation
    import SwiftPWACore

    /// An `AIBackend` backed by **Windows Phi Silica** — the platform built-in
    /// on-device model exposed by the Windows AI APIs in the **Windows App
    /// SDK**. The Windows counterpart to Apple Foundation Models / Android
    /// Gemini Nano: no app-shipped weights (system-managed; pre-installed on
    /// Copilot+ NPU PCs, downloaded on demand on supported GPUs), free,
    /// private, on-device.
    ///
    /// Opt in like any backend:
    /// ```swift
    /// import SwiftPWAPhiSilica
    /// ctx.use(AIPlugin(PhiSilicaBackend()))
    /// ```
    ///
    /// The Swift side is a thin client over the `CPhiSilica` C++/WinRT shim
    /// (`swiftpwa_phi_silica_*`): each call bridges the shim's async callback
    /// back to a continuation / `AsyncThrowingStream`, the same shape as
    /// `SystemBiometricAuth`. Reports `available: true` whenever the model is
    /// `Ready` **or** merely `EnsureNeeded` (download pending) — so a page
    /// routes on `available` and triggers the fetch via `ai.ensureModel`, the
    /// same stance as the downloadable-llama / Gemini Nano tiers. Only
    /// `NotSupportedOnCurrentSystem` / an error (e.g. the runtime is absent or
    /// the Limited Access Feature is locked) reports `false`.
    ///
    /// Provides text (`generate`), token streaming (`generateStream`), and
    /// on-demand model download (`ensureModel`). Structured output uses the
    /// shared prompt-and-validate fallback for now (`structuredOutput: false`);
    /// the base model is text-only.
    public struct PhiSilicaBackend: AIBackend {
        /// Microsoft-issued **Limited Access Feature** unlock token for
        /// `com.microsoft.windows.ai.languagemodel`, obtained per app (tied to
        /// the MSIX package family name) from the LAF Access Token Request Form.
        /// Required for generation: without it the model reports `Ready` but
        /// `generate` throws "Limited Access Feature is not available". Pass it
        /// from your own config/secret store (don't hard-code). `nil` skips the
        /// unlock — fine for probing `info()` or on a build that already has the
        /// feature available without a token.
        private let unlockToken: String?

        public init(unlockToken: String? = nil) {
            self.unlockToken = unlockToken
        }

        /// Unlock the LAF (idempotent, process-wide) before any model call. The
        /// shim builds the attestation from the running package's identity, so
        /// only the token is needed here.
        private func ensureUnlocked() {
            guard let token = unlockToken, !token.isEmpty else { return }
            token.withCString(encodedAs: UTF16.self) { _ = swiftpwa_phi_silica_unlock($0) }
        }

        // MARK: - info

        public func info() async -> AICapabilities {
            ensureUnlocked()
            let state = swiftpwa_phi_silica_ready_state_query()
            let available = switch state {
            case SWIFTPWA_PHI_READY, SWIFTPWA_PHI_NOT_READY:
                // Ready, or present-but-needs-ensure → route + trigger ensureModel.
                true
            default: // SWIFTPWA_PHI_NOT_SUPPORTED, SWIFTPWA_PHI_ERROR
                false
            }
            return AICapabilities(
                available: available,
                backend: AIBackendID.phiSilica,
                model: "phi-silica",
                streaming: true,
                structuredOutput: false
            )
        }

        // MARK: - generate (unary)

        public func generate(_ request: AIGenerateRequest) async throws -> AIGenerateResult {
            ensureUnlocked()
            let prompt = Self.foldedPrompt(request)
            let text = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, any Error>) in
                let box = DoneBox(cont: cont)
                let opaque = Unmanaged.passRetained(box).toOpaque()
                prompt.withCString(encodedAs: UTF16.self) { p in
                    swiftpwa_phi_silica_generate(p, phiDoneCallback, opaque)
                }
            }
            return AIGenerateResult(text: text, backend: AIBackendID.phiSilica)
        }

        // MARK: - generateStream

        public func generateStream(_ request: AIGenerateRequest) -> AsyncThrowingStream<AIChunk, any Error> {
            ensureUnlocked()
            let prompt = Self.foldedPrompt(request)
            return AsyncThrowingStream { continuation in
                let sink = StreamSink(continuation: continuation)
                let opaque = Unmanaged.passRetained(sink).toOpaque()
                // The shim retains nothing; keep the sink alive for the call's
                // duration via the box passed as user_data (released in the
                // done trampoline).
                prompt.withCString(encodedAs: UTF16.self) { p in
                    swiftpwa_phi_silica_generate_stream(p, phiDeltaCallback, phiStreamDoneCallback, opaque)
                }
                continuation.onTermination = { _ in /* shim has no cancel; sink finishes on done */ }
            }
        }

        // MARK: - ensureModel

        public func ensureModel(_: AIEnsureModelRequest) -> AsyncThrowingStream<AIDownloadEvent, any Error> {
            ensureUnlocked()
            return AsyncThrowingStream { continuation in
                let box = EnsureBox(continuation: continuation)
                let opaque = Unmanaged.passRetained(box).toOpaque()
                swiftpwa_phi_silica_ensure_ready(phiEnsureCallback, opaque)
            }
        }

        // MARK: - Helpers

        /// Phi Silica has no separate system-prompt role; fold any `system`
        /// into the prompt text (same approach as the Gemini Nano backend).
        private static func foldedPrompt(_ request: AIGenerateRequest) -> String {
            if let system = request.system, !system.isEmpty {
                return "\(system)\n\n\(request.prompt)"
            }
            return request.prompt
        }
    }

    // MARK: - Continuation / stream boxes

    private final class DoneBox: @unchecked Sendable {
        let cont: CheckedContinuation<String, any Error>
        init(cont: CheckedContinuation<String, any Error>) { self.cont = cont }
    }

    private final class EnsureBox: @unchecked Sendable {
        let continuation: AsyncThrowingStream<AIDownloadEvent, any Error>.Continuation
        init(continuation: AsyncThrowingStream<AIDownloadEvent, any Error>.Continuation) {
            self.continuation = continuation
        }
    }

    /// Holds the stream continuation plus the accumulated text so the delta
    /// trampoline can emit a true incremental suffix regardless of whether the
    /// shim delivers cumulative snapshots or per-token deltas (confirmed on the
    /// Copilot+ box — see the shim's TODO).
    private final class StreamSink: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: AsyncThrowingStream<AIChunk, any Error>.Continuation
        private var emitted = ""
        init(continuation: AsyncThrowingStream<AIChunk, any Error>.Continuation) {
            self.continuation = continuation
        }

        func handleDelta(_ partial: String) {
            lock.withLock {
                if partial.hasPrefix(emitted), partial.count > emitted.count {
                    // Cumulative snapshot → emit the new suffix.
                    continuation.yield(.delta(String(partial.dropFirst(emitted.count))))
                    emitted = partial
                } else if !partial.isEmpty {
                    // Per-token incremental delta.
                    continuation.yield(.delta(partial))
                    emitted += partial
                }
            }
        }

        func finish(error: String?) {
            if let error {
                continuation.finish(throwing: AIError.generationFailed(error))
            } else {
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    // MARK: - C trampolines

    private let phiDoneCallback: @convention(c) (
        UnsafePointer<wchar_t>?, UnsafePointer<wchar_t>?, UnsafeMutableRawPointer?
    ) -> Void = { textPtr, errorPtr, userData in
        guard let userData else { return }
        let box = Unmanaged<DoneBox>.fromOpaque(userData).takeRetainedValue()
        if let errorPtr {
            box.cont.resume(throwing: AIError.generationFailed(String(decodingWCString: errorPtr)))
        } else {
            box.cont.resume(returning: textPtr.map { String(decodingWCString: $0) } ?? "")
        }
    }

    private let phiDeltaCallback: @convention(c) (
        UnsafePointer<wchar_t>?, UnsafeMutableRawPointer?
    ) -> Void = { deltaPtr, userData in
        guard let userData, let deltaPtr else { return }
        // Borrow (not consume) the sink — the done trampoline releases it.
        let sink = Unmanaged<StreamSink>.fromOpaque(userData).takeUnretainedValue()
        sink.handleDelta(String(decodingWCString: deltaPtr))
    }

    private let phiStreamDoneCallback: @convention(c) (
        UnsafePointer<wchar_t>?, UnsafePointer<wchar_t>?, UnsafeMutableRawPointer?
    ) -> Void = { _, errorPtr, userData in
        guard let userData else { return }
        let sink = Unmanaged<StreamSink>.fromOpaque(userData).takeRetainedValue()
        sink.finish(error: errorPtr.map { String(decodingWCString: $0) })
    }

    private let phiEnsureCallback: @convention(c) (
        UnsafePointer<wchar_t>?, UnsafePointer<wchar_t>?, UnsafeMutableRawPointer?
    ) -> Void = { _, errorPtr, userData in
        guard let userData else { return }
        let box = Unmanaged<EnsureBox>.fromOpaque(userData).takeRetainedValue()
        if let errorPtr {
            box.continuation.finish(throwing: AIError.modelDownloadFailed(String(decodingWCString: errorPtr)))
        } else {
            box.continuation.yield(.done)
            box.continuation.finish()
        }
    }

    // MARK: - wchar_t (UTF-16 on Windows) → String

    private extension String {
        /// Decode a null-terminated `wchar_t*` (UTF-16 on Windows) into a
        /// Swift `String`.
        init(decodingWCString ptr: UnsafePointer<wchar_t>) {
            var units: [UInt16] = []
            var p = ptr
            while p.pointee != 0 {
                // `wchar_t` is 16-bit on Windows; `truncatingIfNeeded` is a
                // no-op there and stays correct whichever width Swift imports.
                units.append(UInt16(truncatingIfNeeded: p.pointee))
                p = p.advanced(by: 1)
            }
            self = String(decoding: units, as: UTF16.self)
        }
    }
#endif
