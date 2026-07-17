#!/usr/bin/env bash
# Assemble the Qwen3-TTS on-device model as flat swift-pwa release assets, so
# SwiftPWAQwenTTS's QwenTTSBackend fetches them (at runtime, via ModelDownloader
# / ai.ensureModel) from a URL we control — the audio analogue of
# Scripts/vendor-lama.sh / vendor-sd.sh.
#
# Source: elbruno/Qwen3-TTS-12Hz-0.6B-CustomVoice-ONNX (HF, Apache-2.0), the ONNX
# export of Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice. This script downloads it and
# derives the SHIPPING precision (fp16 talker + fp32 code-predictor + fp32
# vocoder + fp16 text-embedding, ~2.5 GB) by:
#   1. converting talker_decode to uniform fp16 (onnxconverter_common), and
#   2. converting the text_embedding table to fp16,
# then collecting every file under a FLAT name (release assets can't contain
# "/"). The backend's QwenTTSModelSource maps each flat asset back to its
# subdir-qualified local path.
#
# Deterministic given the tool versions below, so re-running reproduces the
# byte-identical assets QwenTTSModelSource pins. After publishing, pin the
# sha256 + size this prints into QwenTTSModelSource.customVoice0_6B.
#
# Usage: bash Scripts/vendor-qwen-tts.sh [OUT_DIR]
#   OUT_DIR defaults to Vendor/qwen-tts.
set -euo pipefail

REPO="elbruno/Qwen3-TTS-12Hz-0.6B-CustomVoice-ONNX"
OUT="${1:-Vendor/qwen-tts}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== Qwen3-TTS vendor: source=$REPO out=$OUT" >&2

# 1. Fetch the ONNX export (needs the huggingface_hub CLI + onnx toolchain).
python3 -m pip install --quiet --upgrade "huggingface_hub[cli]" onnx onnxconverter_common numpy >&2
python3 - "$REPO" "$WORK/src" <<'PY' >&2
import sys
from huggingface_hub import snapshot_download
repo, dest = sys.argv[1], sys.argv[2]
snapshot_download(repo_id=repo, local_dir=dest, local_dir_use_symlinks=False)
print("downloaded", repo, "->", dest)
PY

SRC="$WORK/src"

# 2a. Convert talker_decode to uniform fp16 (keep_io_types=False so there are no
#     mixed-precision boundaries; strip stale value_info; retarget the one baked
#     .to(float32) RoPE Cast to fp16 — see docs/proposals/v0.9-plan.md B.1).
python3 - "$SRC" <<'PY' >&2
import os, sys, onnx
from onnxconverter_common import float16
src = sys.argv[1]
inp = os.path.join(src, "talker_decode.onnx")
outp = os.path.join(src, "talker_decode.fp16.onnx")
m = onnx.load(inp, load_external_data=True)
m16 = float16.convert_float_to_float16(m, keep_io_types=False, op_block_list=[], disable_shape_infer=False)
del m16.graph.value_info[:]
for n in m16.graph.node:
    if n.op_type == "Cast":
        for a in n.attribute:
            if a.name == "to" and a.i == 1:  # FLOAT -> FLOAT16
                a.i = 10
onnx.save_model(m16, outp, save_as_external_data=True, all_tensors_to_one_file=True,
                location="talker_decode.fp16.onnx.data", size_threshold=1024, convert_attribute=False)
print("fp16 talker ->", outp)
PY

# 2b. Convert the text_embedding table to fp16 (1.2 GB -> 622 MB).
python3 - "$SRC" <<'PY' >&2
import os, sys, numpy as np
src = sys.argv[1]
p = os.path.join(src, "embeddings", "text_embedding.npy")
a = np.load(p).astype(np.float16)
np.save(p + ".tmp", a)  # np.save appends .npy
os.replace(p + ".tmp.npy", p)
print("fp16 text_embedding", a.shape)
PY

# 3. Collect every file under a FLAT asset name.
rm -rf "$OUT"; mkdir -p "$OUT"
copy() { cp "$SRC/$1" "$OUT/$(basename "$1")"; }
copy talker_decode.fp16.onnx
copy talker_decode.fp16.onnx.data
copy code_predictor.onnx
copy vocoder.onnx
copy vocoder.onnx.data
copy embeddings/text_embedding.npy
copy embeddings/talker_codec_embedding.npy
for i in $(seq 0 14); do copy "embeddings/cp_codec_embedding_$i.npy"; done
copy embeddings/text_projection_fc1_weight.npy
copy embeddings/text_projection_fc1_bias.npy
copy embeddings/text_projection_fc2_weight.npy
copy embeddings/text_projection_fc2_bias.npy
copy embeddings/config.json
copy embeddings/speaker_ids.json
copy tokenizer/vocab.json
copy tokenizer/merges.txt

# 4. Print checksums + sizes to pin into QwenTTSModelSource.customVoice0_6B.
echo "== assets in $OUT (pin these into QwenTTSModelSource.customVoice0_6B):" >&2
( cd "$OUT" && for f in *; do
    printf '%s  %s  %s\n' "$f" "$(shasum -a 256 "$f" | awk '{print $1}')" "$(wc -c < "$f" | tr -d '[:space:]')"
done )
echo "== done" >&2
