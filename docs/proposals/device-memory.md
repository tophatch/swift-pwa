# Proposal: device memory to JS (`__platform.info` fields + `system.memory` + a memory-pressure event)

> **Status: proposal / RFC.** Nothing here is implemented. Written to unblock
> a consumer feature (device-scaled in-memory caches in Sprites/pixelart) that
> today can only read `navigator.deviceMemory` — which is quantized, capped at
> 8 GB, and **not implemented in WebKit/WKWebView at all**, so on iOS the app
> can't size anything and falls back to a conservative floor. API names/shapes
> are the decision under review — see **Open questions**.

## Motivation

Thin-client PWAs that manage a large in-memory working set — image/canvas
editors, tiled renderers, anything with an LRU cache sized to the device —
need to know how much RAM the device has, ideally how much is free, and want
to be told *before* the OS kills them under pressure.

The only signal the web platform gives is `navigator.deviceMemory`, and it's
the wrong tool:

- **Quantized** to powers of two and **capped at 8** — an 8 GB and a 16 GB
  device report the same `8`, so you can't spend the extra headroom.
- **Absent in WebKit/WKWebView** (never implemented). On iOS the value is
  `undefined`, so an app has no device signal at all and must hard-code a
  conservative floor — wasting headroom on 8–16 GB iPads, which is exactly
  the platform where a canvas app is most memory-constrained by the per-app
  jetsam limit.
- **No "available" and no "pressure."** It's a static hint about the device,
  never about the current moment, so caches can't react to real pressure.

Every platform swift-pwa targets exposes far better numbers natively; the
runtime just doesn't bridge them. `ProcessInfo.physicalMemory` alone already
beats `deviceMemory` on four of five backends (exact, uncapped, **and present
on iOS**). This is a generic thin-client capability, not a Sprites-specific
one — it belongs next to the other `__platform.info` device facts.

## Concrete consumer

Sprites (pixelart) just landed two device-scaled caches:

- a flat-tile composite LRU (`FLAT_TILE_BUDGET`, native/GPU canvas memory), and
- compressed-in-RAM layer-tile residency (`RESIDENT_BUDGET`, JS-heap side).

Both currently key off `navigator.deviceMemory` (128/256/512 MB by the 4/8
buckets) and are **pinned at the 128 MB floor on iOS** because the value is
absent there. With `physicalMemoryBytes` they'd scale to the real device; with
a pressure event they'd shed the flat-tile cache to LOD-only and force-drain
the residency LRU on `warning` — the honest fix for "we can't validate the
WKWebView canvas-memory cap, so we guess low."

## JS surface

Three pieces; the first two are the minimum, the third is the higher-value add.

### 1. Static facts on `__platform.info` (cached, once at init)

Total RAM and the per-app ceiling are effectively constant for a session, so
they fit the existing cached `__platform.info` call — no new round-trip:

```js
const info = await __SWIFT_PWA__.invoke('__platform.info', {});
// existing: { os, commands, tempDir }
// added:    physicalMemoryBytes: number,          // total device RAM
//           appMemoryLimitBytes: number | null    // per-app ceiling where the
//                                                  // OS defines one (see below)
```

`appMemoryLimitBytes` is the number that actually matters on the constrained
platforms: iOS's jetsam headroom and Android's large-heap class. `null` where
the OS has no per-app cap (desktop).

### 2. `system.memory` — a live read (dynamic)

Available RAM changes moment to moment, so it does **not** belong in the
cached `__platform.info`. A small command for a point-in-time read:

```js
const m = await __SWIFT_PWA__.invoke('system.memory', {});
// → { physicalBytes, availableBytes, appLimitBytes: number | null, lowMemory: bool }
```

### 3. `system.memoryPressure` — an event on the existing `events.*` bus

The most valuable piece: let the OS tell the app to shed caches before it
kills the process. Rides the runtime event bus that already exists
(`ctx.emit` / `__SWIFT_PWA__.on`):

```js
__SWIFT_PWA__.on('system.memoryPressure', ({ level }) => {
  // level ∈ 'warning' | 'critical'
  shrinkCaches(level);   // drop to LOD-only, force-drain LRUs, etc.
});
```

## Swift surface — per-platform sources

All standard platform APIs; the Android ones go through JNI exactly like the
existing `AndroidContentResolver` / `AndroidArchiveExtractor` plugins.

| OS | `physicalMemoryBytes` | `availableBytes` | `appMemoryLimitBytes` | pressure |
| --- | --- | --- | --- | --- |
| iOS | `ProcessInfo.physicalMemory` | `os_proc_available_memory()` | `os_proc_available_memory()` (bytes before jetsam) | `DispatchSource.makeMemoryPressureSource(.warning \| .critical)` |
| macOS | `ProcessInfo.physicalMemory` | `host_statistics64(VM_STATISTICS64)` free+inactive | `null` | same `DispatchSource` |
| Android | `ActivityManager.MemoryInfo.totalMem` | `MemoryInfo.availMem` | `getLargeMemoryClass() × 1 MiB` | `ComponentCallbacks2.onTrimMemory` → map `RUNNING_LOW`/`RUNNING_CRITICAL` |
| Linux | `ProcessInfo.physicalMemory` | `/proc/meminfo` `MemAvailable` | `null` | — (no portable signal) |
| Windows | `GlobalMemoryStatusEx.ullTotalPhys` | `.ullAvailPhys` | `null` | `CreateMemoryResourceNotification` (optional) |

Notes:
- `os_proc_available_memory()` is iOS 13+; `#if os(iOS)`-gate it and fall back
  to `physicalMemory` elsewhere.
- On Android, a WebView canvas app's real pressure is **native/GPU** memory,
  not the Java heap — so `getLargeMemoryClass()` is a device-tier proxy, not a
  hard budget, and `onTrimMemory` is the signal that matters. Worth a doc note.
- Suggested shape: a small **`SystemPlugin`** (`system.*`) registered eagerly
  like `AppPlugin` / `PlatformInfoPlugin`, plus the two extra `PlatformInfo`
  fields. Pressure emission is wired per-backend into the event bus at startup.

All added fields optional/defaulted (`UInt64?`, `Bool` defaulting false) so
existing adopters stay source-compatible; a plain browser without the native
shell keeps falling back to `navigator.deviceMemory`.

## Cross-platform parity

Static total-RAM + a live `system.memory` read land on all five backends in
one change (the sources above are all one-liners bar Android's JNI). The
**pressure event** has a real signal on iOS/macOS/Android and none on Linux
(and only a coarse notification object on Windows) — so parity there is
"emit where the OS provides a signal, document the gap" rather than a
synthetic poller. That matches how `window.position` etc. document
best-effort per-backend behavior.

## Perf / memory notes

- `__platform.info` is called once at init and cached; adding two integer
  fields is free.
- `system.memory` is a cheap syscall — fine to call on a debounce (e.g. before
  growing a cache), not per frame.
- The pressure event is push, not poll — zero steady-state cost.

## Open questions (for the team)

1. **Split vs. combine.** Put the static fields on `__platform.info` and the
   live read in a new `system.memory` (this proposal), or a single
   `system.memory` that returns everything and skip touching `__platform.info`?
   The split keeps the static/dynamic distinction honest and avoids a
   round-trip for the common "size a cache at startup" case.
2. **Namespace.** `system.*` (proposed) vs. folding into `app.*`
   (`app.memory`)? `system.*` reads as "the device/OS," `app.*` as "this
   application's identity/lifecycle," and memory is more the former — but
   there's no `system.*` plugin today, so this introduces one.
3. **Pressure levels.** Two levels (`warning`/`critical`) map cleanly to iOS
   `DispatchSource` and Android `onTrimMemory`'s bands. Expose the raw
   platform level too, or keep it normalized to the two?
4. **Units.** Bytes (`UInt64`) throughout for precision, vs. MiB numbers to
   dodge JS `number` precision worries (bytes are safe well past any device
   RAM within `Number.MAX_SAFE_INTEGER`, so bytes seem fine).
5. **iOS `appMemoryLimitBytes` semantics.** `os_proc_available_memory()`
   returns *remaining* headroom, which shrinks as the app allocates — so it's
   really an "available now" number, not a fixed cap. Report it as
   `availableBytes` on iOS and leave `appLimitBytes` null, or surface it as the
   limit? (Consumer wants "how much can I safely use" — the remaining-headroom
   reading answers that directly.)
