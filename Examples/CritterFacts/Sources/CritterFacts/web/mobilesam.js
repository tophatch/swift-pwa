// Gets the bundled MobileSAM ONNX weights onto a real filesystem path so the
// native `ai.vision.*` backend (MobileSAMBackend) can open them — there's no
// downloadable-model tier yet, so this app ships the weights itself under
// `models/mobilesam/` and this file is the one-time "make sure they're
// actually reachable" step. See CritterFacts.swift's `configure(_:)` for the
// matching Swift-side path resolution (this file's target paths must agree
// with it).
//
// Apple points MobileSAMBackend straight at the bundled resource — no work
// needed here. **Android only**: ONNX Runtime needs a real file, and an APK
// asset isn't one, so the weights get copied out to `app.dataDir()/mobilesam/`
// via `fs.writeBinary` the first time this runs; later runs see the files
// already there and skip the copy.
//
// Wrapped in an IIFE (rather than top-level `const`/`function`) so this file
// can sit alongside other page scripts without colliding on shared names in
// the global scope.
(() => {
    const bridge = window.__SWIFT_PWA__;
    const MOBILESAM_FILES = ["encoder.onnx", "decoder_single.onnx", "decoder_multi.onnx"];

    async function ensureMobileSAMWeights(onProgress) {
        const platform = await bridge.invoke("__platform.info", {});
        if (platform.os !== "android") return; // Apple already reads the bundle directly.

        const dataDir = (await bridge.invoke("app.dataDir", {})).value;
        const destDir = `${dataDir}/mobilesam`;
        await bridge.invoke("fs.mkdir", { path: destDir, recursive: true });

        for (let i = 0; i < MOBILESAM_FILES.length; i++) {
            const name = MOBILESAM_FILES[i];
            const destPath = `${destDir}/${name}`;
            const { exists } = await bridge.invoke("fs.exists", { path: destPath });
            if (exists) continue;

            onProgress?.(i, MOBILESAM_FILES.length, name);
            const resp = await fetch(`models/mobilesam/${name}`);
            const buf = await resp.arrayBuffer();
            const b64 = arrayBufferToBase64(buf);
            await bridge.invoke("fs.writeBinary", { path: destPath, dataBase64: b64 });
        }
        onProgress?.(MOBILESAM_FILES.length, MOBILESAM_FILES.length, null);
    }

    function arrayBufferToBase64(buf) {
        const bytes = new Uint8Array(buf);
        let binary = "";
        const chunkSize = 0x8000; // avoid a call-stack blowout on String.fromCharCode.apply
        for (let i = 0; i < bytes.length; i += chunkSize) {
            binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
        }
        return btoa(binary);
    }

    window.ensureMobileSAMWeights = ensureMobileSAMWeights;
})();
