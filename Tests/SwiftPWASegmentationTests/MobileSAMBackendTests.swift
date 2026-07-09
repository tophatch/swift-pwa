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
