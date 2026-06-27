#if os(Android)
    import Foundation
    import SwiftPWACore

    /// An `AIBackend` backed by **Android's on-device Gemini Nano** — the
    /// platform built-in model exposed through **ML Kit GenAI's Prompt API**
    /// (`com.google.mlkit:genai-prompt`, backed by AICore). The Android
    /// counterpart to Apple's `FoundationModelsBackend`: no app-shipped
    /// weights, free, private, on-device.
    ///
    /// Opt in like any backend:
    /// ```swift
    /// import SwiftPWA
    /// ctx.use(AIPlugin(GeminiNanoBackend()))
    /// ```
    ///
    /// The Swift side is a thin client: every call funnels through the generic
    /// Swift→Kotlin RPC (`AndroidRPC`) into the generated `SwiftPWASystemPlugins`
    /// dispatch, which drives the ML Kit `GenerativeModel`. That Kotlin (and the
    /// Gradle dependency it needs) is only generated when `pwa.json` sets
    /// `ai.gemini_nano: true` — without it, the RPCs resolve to "unknown method"
    /// and the backend reports `available: false`, so the app falls back to its
    /// own tier exactly like an unsupported device.
    ///
    /// Reports `available: true` whenever AICore can serve the model — including
    /// the **`DOWNLOADABLE`** state, before the one-time on-demand fetch — so a
    /// page can route on `available` and trigger the download via
    /// `ai.ensureModel` rather than dead-ending (the same stance as the
    /// downloadable-llama tier). Only an outright `UNAVAILABLE` (device without
    /// AICore / Gemini Nano) reports `false`.
    ///
    /// Provides text (`generate`), token streaming (`generateStream`, true
    /// incremental decoding via `generateContentStream`), and on-demand model
    /// download (`ensureModel`). Structured output uses the shared
    /// prompt-and-validate fallback (`structuredOutput: false`) for now; the
    /// base model is text-only, so vision / image / audio stay unsupported.
    public struct GeminiNanoBackend: AIBackend {
        public init() {}

        // MARK: - info

        public func info() async -> AICapabilities {
            guard let probe = try? await AndroidRPC.call("ai.gemini.info", EmptyArgs(), as: InfoResult.self)
            else {
                return AICapabilities(available: false, backend: AIBackendID.geminiNano)
            }
            return AICapabilities(
                available: probe.available,
                backend: AIBackendID.geminiNano,
                model: probe.model ?? "gemini-nano",
                streaming: true,
                structuredOutput: false
            )
        }

        // MARK: - generate (unary)

        public func generate(_ request: AIGenerateRequest) async throws -> AIGenerateResult {
            do {
                let result = try await AndroidRPC.call(
                    "ai.gemini.generate",
                    GenerateArgs(request),
                    as: GenerateResult.self
                )
                return AIGenerateResult(text: result.text, backend: AIBackendID.geminiNano)
            } catch let error as BridgeError {
                throw Self.mapError(error)
            }
        }

        // MARK: - generateStream (true incremental)

        public func generateStream(_ request: AIGenerateRequest) -> AsyncThrowingStream<AIChunk, any Error> {
            AsyncThrowingStream { continuation in
                let channel = Self.nextStreamChannel(prefix: "ai.gemini.stream")
                let sink = StreamSink(continuation: continuation, channel: channel)

                AndroidHostEventRouter.subscribe(channel: channel) { data in
                    sink.handle(data)
                }

                let task = Task {
                    do {
                        // The kickoff RPC resolves when the Kotlin Flow completes
                        // (or fails). Per-token `delta`s + the terminal `done` /
                        // `error` arrive as host events on `channel` and drive the
                        // stream; this is the backstop for a kickoff that throws
                        // before any host event (e.g. unknown method on a build
                        // without the Gemini Nano Kotlin).
                        _ = try await AndroidRPC.call(
                            "ai.gemini.generateStream",
                            GenerateArgs(request, channel: channel),
                            as: NoResult.self
                        )
                        sink.finishIfPending()
                    } catch let error as BridgeError {
                        sink.fail(Self.mapError(error))
                    } catch {
                        sink.fail(error)
                    }
                }

                continuation.onTermination = { _ in
                    task.cancel()
                    AndroidHostEventRouter.unsubscribe(channel: channel)
                }
            }
        }

        // MARK: - ensureModel (AICore on-demand download)

        public func ensureModel(_: AIEnsureModelRequest) -> AsyncThrowingStream<AIDownloadEvent, any Error> {
            AsyncThrowingStream { continuation in
                let channel = Self.nextStreamChannel(prefix: "ai.gemini.download")
                let sink = DownloadSink(continuation: continuation, channel: channel)

                AndroidHostEventRouter.subscribe(channel: channel) { data in
                    sink.handle(data)
                }

                let task = Task {
                    do {
                        _ = try await AndroidRPC.call(
                            "ai.gemini.ensureModel",
                            ChannelArgs(channel: channel),
                            as: NoResult.self
                        )
                        sink.finishIfPending()
                    } catch let error as BridgeError {
                        sink.fail(AIError.modelDownloadFailed(error.message))
                    } catch {
                        sink.fail(AIError.modelDownloadFailed("\(error)"))
                    }
                }

                continuation.onTermination = { _ in
                    task.cancel()
                    AndroidHostEventRouter.unsubscribe(channel: channel)
                }
            }
        }

        // MARK: - Helpers

        /// Map a Kotlin-side `BridgeError` to a stable `AIError`. The Kotlin
        /// dispatch prefixes an unavailable-model failure so the page can route;
        /// everything else is a generation failure.
        private static func mapError(_ error: BridgeError) -> AIError {
            if error.message.localizedCaseInsensitiveContains("unavailable")
                || error.message.localizedCaseInsensitiveContains("unknown rpc method")
            {
                return .unavailable(error.message)
            }
            return .generationFailed(error.message)
        }

        /// A process-unique host-event channel for one stream. Concurrent
        /// streams must not share a channel (the router is single-slot per
        /// channel), so each gets a monotonic suffix.
        private static func nextStreamChannel(prefix: String) -> String {
            let n = streamCounter.next()
            return "\(prefix).\(n)"
        }

        private static let streamCounter = StreamCounter()
    }

    // MARK: - Stream plumbing

    /// Monotonic counter for unique per-stream channel names.
    private final class StreamCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        func next() -> UInt64 {
            lock.withLock {
                value &+= 1
                return value
            }
        }
    }

    /// Bridges host-event `delta` / `done` / `error` frames for a text stream
    /// into the `AIChunk` continuation, guarding against a double-finish when
    /// both a terminal host event and the kickoff RPC completion race.
    private final class StreamSink: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let continuation: AsyncThrowingStream<AIChunk, any Error>.Continuation
        private let channel: String

        init(
            continuation: AsyncThrowingStream<AIChunk, any Error>.Continuation,
            channel: String
        ) {
            self.continuation = continuation
            self.channel = channel
        }

        struct Frame: Decodable {
            let type: String
            let text: String?
            let message: String?
        }

        func handle(_ data: Data) {
            guard let frame = try? JSONDecoder().decode(Frame.self, from: data) else { return }
            switch frame.type {
            case "delta":
                if let text = frame.text, !text.isEmpty {
                    lock.withLock { if !finished { continuation.yield(.delta(text)) } }
                }
            case "done":
                finish(throwing: nil)
            case "error":
                finish(throwing: AIError.generationFailed(frame.message ?? "Gemini Nano generation failed"))
            default:
                break
            }
        }

        /// Called when the kickoff RPC returns without a terminal host event
        /// having arrived — closes the stream cleanly as a backstop.
        func finishIfPending() { finish(throwing: nil) }

        func fail(_ error: any Error) { finish(throwing: error) }

        private func finish(throwing error: (any Error)?) {
            let shouldFinish: Bool = lock.withLock {
                if finished { return false }
                finished = true
                return true
            }
            guard shouldFinish else { return }
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.yield(.done)
                continuation.finish()
            }
            AndroidHostEventRouter.unsubscribe(channel: channel)
        }
    }

    /// Bridges host-event `progress` / `done` / `error` frames for an
    /// `ensureModel` download into the `AIDownloadEvent` continuation.
    private final class DownloadSink: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let continuation: AsyncThrowingStream<AIDownloadEvent, any Error>.Continuation
        private let channel: String

        init(
            continuation: AsyncThrowingStream<AIDownloadEvent, any Error>.Continuation,
            channel: String
        ) {
            self.continuation = continuation
            self.channel = channel
        }

        struct Frame: Decodable {
            let type: String
            let bytesDone: Int64?
            let totalBytes: Int64?
            let message: String?
        }

        func handle(_ data: Data) {
            guard let frame = try? JSONDecoder().decode(Frame.self, from: data) else { return }
            switch frame.type {
            case "progress":
                lock.withLock {
                    if !finished {
                        continuation.yield(.progress(bytesDone: frame.bytesDone ?? 0, totalBytes: frame.totalBytes))
                    }
                }
            case "done":
                finish(throwing: nil)
            case "error":
                finish(throwing: AIError.modelDownloadFailed(frame.message ?? "Gemini Nano model download failed"))
            default:
                break
            }
        }

        func finishIfPending() { finish(throwing: nil) }

        func fail(_ error: any Error) { finish(throwing: error) }

        private func finish(throwing error: (any Error)?) {
            let shouldFinish: Bool = lock.withLock {
                if finished { return false }
                finished = true
                return true
            }
            guard shouldFinish else { return }
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.yield(.done)
                continuation.finish()
            }
            AndroidHostEventRouter.unsubscribe(channel: channel)
        }
    }

    // MARK: - RPC wire types

    private struct InfoResult: Decodable {
        let available: Bool
        let model: String?
    }

    private struct GenerateResult: Decodable {
        let text: String
    }

    private struct ChannelArgs: Encodable {
        let channel: String
    }

    /// Args for `ai.gemini.generate` / `ai.gemini.generateStream`. The
    /// streaming form carries the host-event `channel`; the unary form omits
    /// it (encoded as `null`, ignored by Kotlin).
    private struct GenerateArgs: Encodable {
        let channel: String?
        let system: String?
        let prompt: String
        let maxTokens: Int?
        let temperature: Double?

        init(_ request: AIGenerateRequest, channel: String? = nil) {
            self.channel = channel
            system = request.system
            prompt = request.prompt
            maxTokens = request.maxTokens
            temperature = request.temperature
        }
    }
#endif
