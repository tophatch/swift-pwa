// Makes sure the on-device MobileSAM segmentation model is present before the
// first `ai.vision.openSession`. The three ONNX files (~60 MB, Apache-2.0)
// aren't shipped with the app — they're fetched on first use from the
// `mobilesam-vendor` release by the native downloadable-model tier
// (`MobileSAMBackend(cacheDirectory:)` in CritterFacts.swift), resumable and
// checksum-pinned, exactly like the llama GGUF the fact generator uses.
//
// This helper just drives `ai.vision.ensureModel` and reports aggregate
// progress (a single 0→100% sweep across all three files) — the same shape as
// `ai.ensureModel` for the llama model. Identical on Apple and Android: the
// downloader writes straight to a real filesystem path, so there's no
// APK-asset materialization step to special-case anymore.
//
// Wrapped in an IIFE (rather than top-level `const`/`function`) so this file
// can sit alongside other page scripts without colliding on shared names in
// the global scope.
(() => {
    const bridge = window.__SWIFT_PWA__;

    // Resolves once the model is on disk. First run streams download progress
    // via `onProgress(bytesDone, totalBytes)`; later runs return ~immediately
    // (the native side sees the checksummed files already present and skips
    // the fetch). Rejects with the `E_VISION_MODEL` error on network/checksum
    // failure.
    function ensureSegmentationModel(onProgress) {
        return new Promise((resolve, reject) => {
            const unsub = bridge.subscribe("ai.vision.ensureModel", {}, (e) => {
                if (e.type === "progress") {
                    onProgress?.(e.bytesDone ?? 0, e.totalBytes ?? null);
                } else if (e.type === "done") {
                    unsub();
                    resolve();
                } else if (e.type === "error") {
                    unsub();
                    reject(new Error(e.message || "segmentation model download failed"));
                }
            });
        });
    }

    window.ensureSegmentationModel = ensureSegmentationModel;
})();
