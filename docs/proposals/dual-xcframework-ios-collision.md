# Proposal: fix the two-AI-xcframework iOS build collision (framework-style xcframeworks)

> **Status: implemented.** Both vendor scripts now emit framework-style
> xcframeworks; the artifacts are re-hosted and the `Package.swift` checksums
> re-pinned. An app that enables **both** `ai.local_llama` **and**
> `ai.local_onnx_runtime` (e.g. `Examples/CritterFacts` — on-device text *and*
> image) previously **could not build for iOS**; it now does. Kept as the design
> record.

## Symptom

```
error: Multiple commands produce
  '…/Build/Products/Release-iphoneos/include/module.modulemap'
  note: Command: ProcessXCFramework …/CLlama/llama.xcframework …/libllama.a
  note: Command: ProcessXCFramework …/ONNXRuntime/onnxruntime.xcframework …/libonnxruntime.a
```

`swift-pwa build --target ios` (device *or* simulator) fails at
`ProcessXCFramework`. Only surfaces with **both** AI xcframeworks in one build —
each alone is fine, which is why it went unnoticed (CritterFacts had only ever
been device-verified on Android).

## Root cause (confirmed at the file level)

Both `llama.xcframework` and `onnxruntime.xcframework` are **`-library -headers`**
xcframeworks (a static `.a` + a `Headers/` dir), and each `Headers/` contains a
`module.modulemap`:

- `llama.xcframework/<slice>/Headers/module.modulemap` → `module CLlama { header "llama.h" … }`
- `onnxruntime.xcframework/<slice>/Headers/module.modulemap` → `module ONNXRuntime { header "onnxruntime_c_api.h" … }`

When xcodebuild consumes a `-library -headers` xcframework it copies that slice's
`Headers/` into a **single shared** `Build/Products/<config>/include/`. With two
such xcframeworks, both copy a file literally named `module.modulemap` to
`include/module.modulemap` — the same output path from two tasks → the "Multiple
commands produce" error. (Only `module.modulemap` collides; the `.h` names
differ.) `swift build` doesn't hit this because it doesn't flatten headers into a
shared `include/`; **only the xcodebuild path (which iOS requires) does.**

## Fix (validated)

Ship both as **framework-style** xcframeworks — `<Module>.framework` slices, each
carrying its own `Modules/module.modulemap` **inside the bundle**. Framework
xcframeworks are linked/embedded per-framework and are **never flattened into a
shared `include/`**, so two of them can't collide.

Validated in a throwaway SwiftPM package that `binaryTarget`s both converted
framework xcframeworks and `import`s both for iOS Simulator:

- With framework-style xcframeworks the **collision is gone** (no "Multiple
  commands produce").
- The **module map must list the C-API headers explicitly** (as the originals
  did) — an `umbrella "."` map wrongly pulls the **C++** headers
  (`ggml-cpp.h` → `<memory>`, `onnxruntime_float16.h` → `<cmath>`) into the C
  module and fails. The working maps:
  ```
  framework module CLlama { header "llama.h" export * }
  framework module ONNXRuntime {
      header "onnxruntime_c_api.h"
      header "cpu_provider_factory.h"
      header "coreml_provider_factory.h"
      export *
  }
  ```
- Result: **`BUILD SUCCEEDED`** — both modules compile, import, and link
  together on iOS. `import CLlama` / `import ONNXRuntime` in Swift are unchanged.

## Implementation

1. **`Scripts/build-llama-xcframework.sh`** — assemble each slice as
   `CLlama.framework` (binary + `Headers/*.h` + `Modules/module.modulemap` +
   `Info.plist`) and `xcodebuild -create-xcframework -framework …` instead of
   `-library … -headers …`.
2. **`Scripts/vendor-onnxruntime-apple.sh`** — same, `ONNXRuntime.framework`
   with the three C-API headers above.
3. **Re-host**: run `.github/workflows/llama-xcframework.yml` +
   `onnxruntime-xcframework.yml` (workflow_dispatch) to rebuild and re-upload the
   `.xcframework.zip` release assets.
4. **Re-pin** the two `.binaryTarget(url:…, checksum:…)` in `Package.swift` to
   the new assets.
5. Regenerate the local `Vendor/{llama,onnxruntime}/*.xcframework` (framework
   style) for swift-pwa's own local/CI builds.
6. **Verify**: `swift-pwa build --target ios` of a both-tiers app, then a
   `deploy` of `Examples/CritterFacts` to a device.

Additive and backward-compatible — the module names (`CLlama`, `ONNXRuntime`)
and every Swift `import` stay the same; only the artifact packaging changes.

## Why it's not a one-line sample fix

The collision is in the **shipped, checksum-pinned** xcframework artifacts, not
in CritterFacts' config — so the fix is a vendoring/packaging change that has to
be re-hosted and re-pinned (steps 3–4), not an example tweak. CritterFacts
downloads the pinned release artifacts (its `path: "../.."` dependency still
resolves the *binary* targets from the release URL), so it can't be fixed by
editing local `Vendor/` alone.
