import Foundation
import SwiftPWACore
import SwiftPWAONNX
@testable import SwiftPWAStableDiffusion
import Testing

/// Verifies the Swift txt2img pipeline stage-by-stage against a diffusers
/// reference generated from the real SD-Turbo ONNX export (see
/// `docs/proposals/stable-diffusion.md`). **Opt-in**: runs only when
/// `SD_VERIFY_DIR` points at a directory holding `sd-turbo-onnx/` (the export)
/// and `ref/` (the reference bundle: raw little-endian `.bin`s + `manifest.json`,
/// produced by `Scripts`/the real-weights pass). CI has neither the ~5 GB model
/// nor the bundle, so it no-ops there.
///
/// The reference's raw initial-noise latent is **injected**, so the comparison
/// isolates the pipeline (tokenize → text-encode → Euler denoise → VAE) from
/// RNG differences between torch and our seeded generator.
struct StableDiffusionReferenceVerificationTests {
    @Test func matchesDiffusersReferenceOnSDTurbo() async throws {
        guard let dirPath = ProcessInfo.processInfo.environment["SD_VERIFY_DIR"] else { return }
        let env = ProcessInfo.processInfo.environment
        let base = URL(fileURLWithPath: dirPath)
        // Defaults target the fp32 optimum export; env overrides point at the
        // fp16 export (SD_VERIFY_MODEL=sd-turbo-fp16opt, SD_VERIFY_REF=ref_fp16,
        // SD_VERIFY_SPEC=fp16).
        let model = base.appendingPathComponent(env["SD_VERIFY_MODEL"] ?? "sd-turbo-onnx")
        let ref = base.appendingPathComponent(env["SD_VERIFY_REF"] ?? "ref")
        let spec: StableDiffusionModelSpec = env["SD_VERIFY_SPEC"] == "fp16" ? .sdTurboFp16 : .sdTurbo
        // fp16's reduced precision needs looser absolute bounds; correlation
        // gates stay tight (structure must still match).
        let fp16 = env["SD_VERIFY_SPEC"] == "fp16"

        let backend = StableDiffusionBackend(
            textEncoderPath: model.appendingPathComponent("text_encoder/model.onnx").path,
            unetPath: model.appendingPathComponent("unet/model.onnx").path,
            vaeDecoderPath: model.appendingPathComponent("vae_decoder/model.onnx").path,
            tokenizerVocabPath: model.appendingPathComponent("tokenizer/vocab.json").path,
            tokenizerMergesPath: model.appendingPathComponent("tokenizer/merges.txt").path,
            spec: spec
        )

        let initLatent = try floats(ref.appendingPathComponent("init_latent.bin"))
        let request = AIGenerateImageRequest(
            prompt: "a photograph of an astronaut riding a horse",
            width: 512, height: 512, steps: 1, seed: 42
        )
        let out = try await backend.runTxt2Img(request, injectedLatent: initLatent)

        // 1. Tokenizer — exact match against the real CLIP tokenizer's ids.
        let refIds = try int64s(ref.appendingPathComponent("input_ids.bin"))
        #expect(out.inputIds.map(Int64.init) == refIds)

        // 2. Text embedding — same ONNX graph; tiny cross-ORT-build drift only
        //    (fp16 rounding widens it).
        let refEmb = try floats(ref.appendingPathComponent("text_emb.bin"))
        report("text_emb", out.textEmbedding.values, refEmb)
        #expect(maxAbsDiff(out.textEmbedding.values, refEmb) < (fp16 ? 0.1 : 0.05))

        // 3. Final latent — after the UNet pass + Euler step. Cross-ORT drift
        //    compounds a little, so gate on correlation + a loose abs bound.
        let refLatent = try floats(ref.appendingPathComponent("final_latent.bin"))
        report("final_latent", out.latent, refLatent)
        #expect(correlation(out.latent, refLatent) > 0.99)
        #expect(maxAbsDiff(out.latent, refLatent) < (fp16 ? 0.5 : 0.15))

        // 4. VAE image — the decoded result. Correlation confirms the image
        //    structure matches the reference (the astronaut-on-horse).
        let refImage = try floats(ref.appendingPathComponent("vae_image.bin"))
        report("vae_image", out.image.values, refImage)
        #expect(correlation(out.image.values, refImage) > 0.98)

        // Dump the Swift-produced image as a PPM to eyeball against reference.png.
        try writePPM(out.image, to: base.appendingPathComponent("swift_out.ppm"))

        // End-to-end: the full public generateImage path (seeded latent + PNG
        // encode + write). Uses our seeded RNG, not the injected latent, so it
        // won't match the reference pixel-for-pixel — this confirms the return
        // path produces a valid written PNG.
        let genRequest = AIGenerateImageRequest(
            prompt: "a photograph of an astronaut riding a horse",
            width: 512, height: 512, steps: 1, seed: 42, outputDirectory: base.path
        )
        let result = try await backend.generateImage(genRequest)
        let path = try #require(result.images.first?.path)
        let png = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47])) // PNG magic
        #expect(png.count > 10000) // a real 512² image, not a blank
        print("[SD verify] generateImage wrote \(png.count) bytes to \(path)")
    }

    /// LCM (`LCM_Dreamshaper_v7`) counterpart. **Opt-in** via `SD_VERIFY_LCM_DIR`
    /// (holding `lcm-dreamshaper-fp16/` + `ref_lcm/`). Injects the reference's
    /// initial latent **and** the per-step re-noise vectors, so the comparison
    /// isolates the pipeline (LCM scheduler + guidance embedding + the four
    /// UNet passes) from RNG. Confirms the LCM path against the same
    /// stage-by-stage bar as SD-Turbo.
    @Test func matchesDiffusersReferenceOnLCM() async throws {
        guard let dirPath = ProcessInfo.processInfo.environment["SD_VERIFY_LCM_DIR"] else { return }
        let base = URL(fileURLWithPath: dirPath)
        let model = base.appendingPathComponent("lcm-dreamshaper-fp16")
        let ref = base.appendingPathComponent("ref_lcm")

        let backend = StableDiffusionBackend(
            textEncoderPath: model.appendingPathComponent("text_encoder/model.onnx").path,
            unetPath: model.appendingPathComponent("unet/model.onnx").path,
            vaeDecoderPath: model.appendingPathComponent("vae_decoder/model.onnx").path,
            tokenizerVocabPath: model.appendingPathComponent("tokenizer/vocab.json").path,
            tokenizerMergesPath: model.appendingPathComponent("tokenizer/merges.txt").path,
            spec: .lcmDreamshaperFp16
        )

        let initLatent = try floats(ref.appendingPathComponent("init_latent.bin"))
        // Per-step noise for the non-final steps (4 steps → 3 noise vectors).
        let stepNoise = try (0 ..< 3).map { try floats(ref.appendingPathComponent("step_noise_\($0).bin")) }
        let request = AIGenerateImageRequest(
            prompt: "a photograph of an astronaut riding a horse",
            width: 512, height: 512, steps: 4, seed: 42, guidanceScale: 8.0
        )
        let out = try await backend.runTxt2Img(request, injectedLatent: initLatent, injectedStepNoise: stepNoise)

        let refIds = try int64s(ref.appendingPathComponent("input_ids.bin"))
        #expect(out.inputIds.map(Int64.init) == refIds)

        let refEmb = try floats(ref.appendingPathComponent("text_emb.bin"))
        report("lcm text_emb", out.textEmbedding.values, refEmb)
        #expect(maxAbsDiff(out.textEmbedding.values, refEmb) < 0.1) // fp16

        let refLatent = try floats(ref.appendingPathComponent("final_latent.bin"))
        report("lcm final_latent", out.latent, refLatent)
        #expect(correlation(out.latent, refLatent) > 0.99)

        let refImage = try floats(ref.appendingPathComponent("vae_image.bin"))
        report("lcm vae_image", out.image.values, refImage)
        #expect(correlation(out.image.values, refImage) > 0.98)

        try writePPM(out.image, to: base.appendingPathComponent("swift_lcm_out.ppm"))
        print("[SD verify] LCM pipeline matched the diffusers reference")
    }

    // MARK: - Fixture readers

    private func floats(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func int64s(_ url: URL) throws -> [Int64] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int64.self)) }
    }

    // MARK: - Comparison

    private func maxAbsDiff(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        return zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    private func correlation(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let n = Double(a.count)
        let ma = a.reduce(0.0) { $0 + Double($1) } / n
        let mb = b.reduce(0.0) { $0 + Double($1) } / n
        var cov = 0.0, va = 0.0, vb = 0.0
        for i in 0 ..< a.count {
            let da = Double(a[i]) - ma, db = Double(b[i]) - mb
            cov += da * db; va += da * da; vb += db * db
        }
        return (va > 0 && vb > 0) ? cov / (va.squareRoot() * vb.squareRoot()) : 0
    }

    private func report(_ label: String, _ a: [Float], _ b: [Float]) {
        print("[SD verify] \(label): count \(a.count) vs \(b.count), "
            + "maxAbsDiff \(maxAbsDiff(a, b)), correlation \(correlation(a, b))")
    }

    /// Write a `[1,3,H,W]` `[-1,1]` VAE tensor as a binary PPM (P6) — a
    /// dependency-free way to eyeball the Swift output vs the reference PNG.
    private func writePPM(_ image: OrtModelSession.Tensor, to url: URL) throws {
        let h = Int(image.shape[2]), w = Int(image.shape[3]), plane = h * w
        var bytes = Array("P6\n\(w) \(h)\n255\n".utf8)
        bytes.reserveCapacity(bytes.count + plane * 3)
        for pixel in 0 ..< plane {
            for channel in 0 ..< 3 {
                let v = (image.values[channel * plane + pixel] / 2 + 0.5) * 255
                bytes.append(UInt8(max(0, min(255, v.rounded()))))
            }
        }
        try Data(bytes).write(to: url)
    }
}
