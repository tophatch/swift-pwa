# Auto-updates

> **This tutorial is coming in swift-pwa 0.9.** 🚧

swift-pwa has an auto-update system — you publish a signed manifest, and the app checks it and updates itself in place. The **publishing** side is complete and fully tested today (`swift-pwa updater keygen` / `sign` / `manifest`, Ed25519-signed, Tauri-v1-compatible manifests).

The **runtime** side — each desktop backend actually downloading, verifying, swapping, and relaunching — currently ships as **preview**: it's unit-tested but hasn't been walked end-to-end against real bundled artifacts on macOS / Windows / Linux, so it's marked *Untested* in the [feature matrix](../../README.md#feature-matrix). (Android's `PackageInstaller` path is the one that's been exercised for real.) Verifying and hardening that path is the top item on the [roadmap](../../README.md#roadmap), targeted for **0.9** — and this step-by-step tutorial will land alongside it, once the flow is something we can wholeheartedly recommend for production.

## In the meantime

The full reference already exists and is accurate — start there if you want to set up publishing now or experiment with the preview runtime:

- **[docs/auto-updates.md](../auto-updates.md)** — the complete reference: keypair generation, per-artifact signing, the manifest format, and per-platform runtime wiring (`AppleUpdater`, `LinuxAppImageUpdater`, `WindowsUpdater`, `AndroidUpdater`).
- **[Shipping your app](shipping-your-app.md)** — how releases are built and distributed, which is the foundation auto-updates build on.

Before relying on desktop auto-updates in production, walk the Updater cases in [docs/manual-test-cases.md](../manual-test-cases.md).

## Where to go next

- [Shipping your app](shipping-your-app.md) — build, sign, and distribute on every platform.
- [docs/auto-updates.md](../auto-updates.md) — the current reference.
