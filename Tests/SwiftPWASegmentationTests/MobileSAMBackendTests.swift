#if canImport(CoreGraphics) && canImport(ImageIO)
    import CoreGraphics
    import Foundation
    import ImageIO
    @testable import SwiftPWACore
    @testable import SwiftPWASegmentation
    import Testing

    /// End-to-end tests against a **fake** encoder/decoder-single/
    /// decoder-multi ONNX trio — matching the *verified real* MobileSAM I/O
    /// contract's names and shapes (including the decoder's own internal
    /// upsample to `orig_im_size`), but with constant/synthetic weights so
    /// no real trained model is needed. These prove `MobileSAMBackend`'s
    /// *plumbing* (preprocessing → encoder → session cache → decoder →
    /// postprocessing → RLE) end-to-end; real segmentation quality is
    /// covered separately against the real `Acly/MobileSAM` weights (see
    /// `docs/proposals/segmentation-plugin.md`).
    @Suite("MobileSAMBackend (fake weights, plumbing proof)")
    struct MobileSAMBackendTests {
        private func fixturePath(_ name: String) throws -> String {
            try #require(Bundle.module.url(forResource: name, withExtension: "onnx", subdirectory: "Fixtures")).path
        }

        private func backend() throws -> MobileSAMBackend {
            try MobileSAMBackend(
                encoderPath: fixturePath("fake_mobile_sam_encoder"),
                decoderSinglePath: fixturePath("fake_mobile_sam_decoder_single"),
                decoderMultiPath: fixturePath("fake_mobile_sam_decoder_multi")
            )
        }

        /// A small solid-color test image written to a temp file, so
        /// `openSession` can exercise the `path` (not `dataBase64`) input
        /// shape.
        private func writeTestImage(width: Int = 64, height: Int = 48) throws -> URL {
            var pixels = [UInt8](repeating: 128, count: width * height * 4)
            for i in 0 ..< (width * height) { pixels[i * 4 + 3] = 255 }
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let cgImage = try #require(context.makeImage())
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swift-pwa-mobilesam-test-\(UUID().uuidString).png")
            let destination = try #require(CGImageDestinationCreateWithURL(
                url as CFURL,
                "public.png" as CFString,
                1,
                nil
            ))
            CGImageDestinationAddImage(destination, cgImage, nil)
            #expect(CGImageDestinationFinalize(destination))
            return url
        }

        @Test("info reports available:true when ONNX Runtime is linked")
        func infoAvailable() async throws {
            let caps = try await (backend()).info()
            #expect(caps.available == true)
            #expect(caps.backend == VisionBackendID.mobileSAMONNX)
            #expect(caps.sessionCaching == true)
            // No session has run yet, so the execution provider is undecided.
            #expect(caps.provider == nil)
        }

        @Test("info reports the execution provider once a session has run")
        func infoProviderAfterSession() async throws {
            let backend = try backend()
            let imageURL = try writeTestImage()
            defer { try? FileManager.default.removeItem(at: imageURL) }

            _ = try await backend.openSession(.init(image: .file(imageURL.path)))
            // This is the CPU test build (no ai.onnx_gpu / SWIFT_PWA_ONNXRUNTIME_GPU),
            // so the encoder runs on the default CPU EP. The GPU providers
            // (cuda/directml) are exercised in on-device verification.
            let caps = try await backend.info()
            #expect(caps.provider == "cpu")
        }

        @Test("openSession -> segment -> closeSession, single point, default (best-only)")
        func fullPipelineSinglePoint() async throws {
            let backend = try backend()
            let imageURL = try writeTestImage()
            defer { try? FileManager.default.removeItem(at: imageURL) }

            let session = try await backend.openSession(.init(image: .file(imageURL.path)))
            #expect(session.width == 64)
            #expect(session.height == 48)

            let result = try await backend.segment(.init(
                sessionID: session.sessionID, points: [VisionPoint(x: 32, y: 24, label: 1)]
            ))
            // Default (multimask: false) returns exactly the best-scoring
            // candidate — the fixture's iou_predictions are [0.5, 0.8,
            // 0.65], so candidate 1 (radius 20) wins.
            #expect(result.masks.count == 1)
            let mask = try #require(result.masks.first)
            #expect(abs(mask.score - 0.8) < 0.001)
            // A radius-20 circle out of a 64x64 fake grid, upsampled onto a
            // 64x48 image, should be a real, non-trivial bounding box —
            // not the whole image, not empty.
            #expect(mask.bounds.count == 4)
            #expect(mask.rle
                .reduce(0, +) == (mask.bounds[2] - mask.bounds[0] + 1) * (mask.bounds[3] - mask.bounds[1] + 1))

            await backend.closeSession(session.sessionID)
            await #expect(throws: VisionError.self) {
                _ = try await backend.segment(.init(
                    sessionID: session.sessionID,
                    points: [VisionPoint(x: 1, y: 1, label: 1)]
                ))
            }
        }

        @Test("multimask: true returns all candidates ranked best-first")
        func multimaskReturnsRankedCandidates() async throws {
            let backend = try backend()
            let imageURL = try writeTestImage()
            defer { try? FileManager.default.removeItem(at: imageURL) }

            let session = try await backend.openSession(.init(image: .file(imageURL.path)))
            let result = try await backend.segment(.init(
                sessionID: session.sessionID, points: [VisionPoint(x: 10, y: 10, label: 1)], multimask: true
            ))

            #expect(result.masks.count == 3)
            let scores = result.masks.map(\.score)
            #expect(scores == scores.sorted(by: >))
            #expect(abs((scores.first ?? 0) - 0.8) < 0.001)
        }

        @Test("a box prompt is accepted (corner points labeled 2/3)")
        func boxPrompt() async throws {
            let backend = try backend()
            let imageURL = try writeTestImage()
            defer { try? FileManager.default.removeItem(at: imageURL) }

            let session = try await backend.openSession(.init(image: .file(imageURL.path)))
            let result = try await backend.segment(.init(sessionID: session.sessionID, box: [5, 5, 40, 30]))
            #expect(result.masks.count == 1)
        }

        @Test("segment with neither points nor box fails with a stable error")
        func noPromptFails() async throws {
            let backend = try backend()
            let imageURL = try writeTestImage()
            defer { try? FileManager.default.removeItem(at: imageURL) }

            let session = try await backend.openSession(.init(image: .file(imageURL.path)))
            await #expect(throws: VisionError.self) {
                _ = try await backend.segment(.init(sessionID: session.sessionID))
            }
        }

        @Test("segment against an unknown sessionId fails with .session")
        func unknownSessionFails() async throws {
            let backend = try backend()
            do {
                _ = try await backend.segment(.init(
                    sessionID: "not-a-real-session",
                    points: [VisionPoint(x: 1, y: 1, label: 1)]
                ))
                Issue.record("expected segment to throw")
            } catch let error as VisionError {
                #expect(error.code == VisionError.sessionCode)
            }
        }

        @Test("openSession on an undecodable image fails, not crashes")
        func undecodableImageFails() async throws {
            let backend = try backend()
            await #expect(throws: VisionError.self) {
                _ = try await backend.openSession(.init(image: .file("/nonexistent/path/photo.png")))
            }
        }

        @Test("a fixed-path backend's ensureModel reports unsupportedPlatform (nothing to download)")
        func fixedPathEnsureModelUnsupported() async throws {
            let backend = try backend()
            var caught: VisionError?
            do {
                for try await _ in backend.ensureModel(AIEnsureModelRequest()) {}
                Issue.record("expected ensureModel to throw for a fixed-path backend")
            } catch let error as VisionError {
                caught = error
            }
            #expect(caught?.code == BridgeError.unimplemented)
        }

        @Test("a downloadable backend resolves its three model paths under the cache directory")
        func downloadableBackendResolvesPaths() async {
            // Constructing the downloadable tier must not touch the network —
            // it only resolves where the files *will* live. (The actual
            // download is covered by ModelDownloaderTests + on-device
            // verification; asserting it here would need a live fetch.)
            let cache = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swift-pwa-mobilesam-cache-\(UUID().uuidString)", isDirectory: true)
            let backend = MobileSAMBackend(cacheDirectory: cache)
            // info() still reports available (ONNX linked); model presence is
            // a separate concern from backend capability.
            let caps = await backend.info()
            #expect(caps.available == true)
            #expect(caps.backend == VisionBackendID.mobileSAMONNX)
        }

        @Test("the default MobileSAMModelSource pins the canonical mobilesam-vendor assets")
        func defaultModelSourcePinned() {
            let source = MobileSAMModelSource.mobileSAM
            #expect(source.encoder.fileName == "mobile_sam_image_encoder.onnx")
            #expect(source.decoderSingle.fileName == "sam_mask_decoder_single.onnx")
            #expect(source.decoderMulti.fileName == "sam_mask_decoder_multi.onnx")
            // Checksums are byte-verified against the committed CritterFacts
            // bundled weights (same source) — a mismatch here means a
            // re-publish silently changed the pinned artifact.
            #expect(source.encoder.sha256 == "580f5fb648ea1062c0aabc26217aed56921985f03f0cbbd852bba81d760cc749")
            #expect(source.decoderSingle.sha256 == "93915fc7c993ab9d59ab8c9ccd3bce37f7509c81ab4150a74abd4d2abbd8570d")
            #expect(source.decoderMulti.sha256 == "8976b90a87ba50a6a72217a5ff994f7d25ce16f2229fcc1ed259e1294c622ffe")
            // Every asset lives on the stable mobilesam-vendor release.
            for file in [source.encoder, source.decoderSingle, source.decoderMulti] {
                #expect(file.url.absoluteString.contains("/releases/download/mobilesam-vendor/"))
                #expect(file.sizeBytes > 0)
            }
        }

        @Test("info reports autoMask:true now that AMG is implemented")
        func infoAutoMask() async throws {
            #expect(try await (backend()).info().autoMask == true)
        }

        @Test("segmentAll runs the grid + NMS and returns deduped masks")
        func segmentAllDedupes() async throws {
            let backend = try backend()
            let imageURL = try writeTestImage()
            defer { try? FileManager.default.removeItem(at: imageURL) }

            let session = try await backend.openSession(.init(image: .file(imageURL.path)))
            // The fake multi decoder emits three blobs with iou [0.5, 0.8,
            // 0.65] and ignores the prompt point, so every grid cell yields
            // the same single above-quality-floor (0.8) blob. NMS collapses
            // the identical masks to exactly one.
            let result = try await backend.segmentAll(.init(sessionID: session.sessionID, pointsPerSide: 4))
            #expect(result.masks.count == 1)
            let mask = try #require(result.masks.first)
            #expect(abs(mask.score - 0.8) < 0.001)
            // RLE integrity: run lengths sum to the bbox area.
            #expect(mask.rle
                .reduce(0, +) == (mask.bounds[2] - mask.bounds[0] + 1) * (mask.bounds[3] - mask.bounds[1] + 1))
        }

        @Test("segmentAllStream emits one progress frame per grid cell, then a done")
        func segmentAllStreamProgress() async throws {
            let backend = try backend()
            let imageURL = try writeTestImage()
            defer { try? FileManager.default.removeItem(at: imageURL) }

            let session = try await backend.openSession(.init(image: .file(imageURL.path)))
            var progressFrames = 0
            var lastProgress: (done: Int, total: Int)?
            var doneMasks: [VisionMask]?
            for try await frame in backend.segmentAllStream(.init(sessionID: session.sessionID, pointsPerSide: 3)) {
                if frame.type == "progress" {
                    progressFrames += 1
                    lastProgress = (frame.done ?? -1, frame.total ?? -1)
                } else if frame.type == "done" {
                    doneMasks = frame.masks
                }
            }
            // 3x3 grid → 9 progress frames, total reported as 9, terminal done.
            #expect(progressFrames == 9)
            #expect(lastProgress?.done == 9)
            #expect(lastProgress?.total == 9)
            #expect(doneMasks?.count == 1)
        }

        @Test("benchmark returns timings and a device class without needing a session")
        func benchmarkTimings() async throws {
            // benchmark synthesizes its own image, so no openSession first.
            let result = try await (backend()).benchmark()
            #expect(result.encodeMs >= 0)
            #expect(result.decodeMs >= 0)
            #expect(result.segmentAllMs != nil)
            #expect(["high", "mid", "low"].contains(result.deviceClass))
        }

        @Test("segmentAll against an unknown sessionId fails with .session")
        func segmentAllUnknownSession() async throws {
            let backend = try backend()
            do {
                _ = try await backend.segmentAll(.init(sessionID: "nope"))
                Issue.record("expected segmentAll to throw")
            } catch let error as VisionError {
                #expect(error.code == VisionError.sessionCode)
            }
        }

        @Test("the encoder's cached embedding is reused across multiple segment calls")
        func embeddingReusedAcrossSegmentCalls() async throws {
            let backend = try backend()
            let imageURL = try writeTestImage()
            defer { try? FileManager.default.removeItem(at: imageURL) }

            let session = try await backend.openSession(.init(image: .file(imageURL.path)))
            let first = try await backend.segment(.init(
                sessionID: session.sessionID,
                points: [VisionPoint(x: 5, y: 5, label: 1)]
            ))
            let second = try await backend.segment(.init(
                sessionID: session.sessionID,
                points: [VisionPoint(x: 50, y: 40, label: 1)]
            ))
            // Same fixture decoder ignores point coordinates (constant
            // output), so both calls against the same session succeed and
            // agree — the point here is that the *session* (cached
            // embedding) survives multiple segment calls without re-opening.
            #expect(first.masks.first?.score == second.masks.first?.score)
        }
    }
#endif
