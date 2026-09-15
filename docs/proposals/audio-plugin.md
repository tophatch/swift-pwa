# Proposal: platform audio — fill three web APIs, don't build a plugin

> **Status: shipped.** All three gaps are resolved — two by building, one by
> deciding not to — plus the developer-facing half, which closed more than the
> code did.
>
> - **`navigator.audioSession`** on all five: the engine's own on Apple, a real
>   fill over `AudioManager` focus on Android, recorded-but-inert on Linux and
>   Windows where **the platform has nothing an embedder can drive** (see below).
> - **`navigator.mediaSession`** filled on Android, the only engine lacking it,
>   over a platform `MediaSession` plus a transport notification — **artwork
>   included**, fetched by the page and sent as bytes, because an artwork URL in
>   the app's own bundle sits on an origin no other process can resolve.
> - **`setSinkId` deliberately not filled** (see gap 3): per-element contract,
>   per-process mechanism, and `'setSinkId' in element` is how a page decides
>   whether to show a device picker — so a fill would lie rather than merely
>   under-deliver.
> - **A runtime warning and a `doctor` check** for an app that plays audio
>   without declaring a type, plus the tutorials and samples updated to declare
>   one. See "Telling the developer" below.
>
> Still open: a **game tutorial** exercising `ambient` / `transient`, pending
> input from a game author.

> **Status: proposed**, after a five-platform measurement pass. The README
> roadmap has "Platform audio (capture / playback)" at #3, described as
> *"native microphone capture and audio playback / device routing behind a
> plugin — lower-latency and more capable than the WebView's `getUserMedia` /
> `MediaRecorder`"*.
>
> **The measurements don't support that, and they point somewhere cheaper.**
> Capture and playback already work on all five engines. What's missing is
> three *web* APIs, each absent on some subset of platforms — and the honest
> fix is to make those APIs work everywhere, not to invent a parallel
> `audio.*` surface beside them.

## Why measure first

Audio is the case the "data-shaped → plugin, stream-shaped → keep the web API"
rule was written about, so whether a gap is real decides whether a plugin
exists at all. Bridging PCM across `invoke` would rebuild the platform's media
pipeline, worse, behind a per-message envelope.

Every claim below comes from a run against a real app on real hardware, on the
app's own origin — [`Scripts/audio-probe/index.html`](../../Scripts/audio-probe/index.html)
driven by [`Scripts/measure-audio-gaps.sh`](../../Scripts/measure-audio-gaps.sh).
Nothing is inferred from one platform to another; unmeasured cells say so.

## The use cases this has to serve

Read-aloud is not the only consumer, and designing for it alone produces the
wrong API. The bar is a **write-once audio system** that carries at least:

1. **Game audio** — many short sounds, low latency, mixing, foreground only.
2. **AI transcription** — microphone into a model, as raw frames.
3. **Ambient / background-noise** — a long loop that keeps playing when the
   app isn't in front, with lock-screen controls.
4. **Read-aloud / streaming TTS** — *generated* audio, which needs the app to
   keep running and to hand over chunks on time.

Against the measurements, **all four work today on all five platforms** — three
of them outright, and read-aloud once one line of web API is set on iOS. The
remaining gaps are policy surfaces, not pipelines.

## What the web stack already does, everywhere

| | macOS | iOS | Android | GTK3 | GTK4 | Windows |
| --- | --- | --- | --- | --- | --- | --- |
| Raw PCM capture into an `AudioWorklet` | ✅ 128-frame blocks | ✅ | ✅ | ✅ | ✅ | ✅ |
| `sampleRate` | 48 k | 48 k | 48 k | 44.1 k | 44.1 k | 48 k |
| `baseLatency` | 2.7 ms | 2.7 ms | 3.0 ms | 2.9 ms | 2.9 ms | 10 ms |
| Gapless chunk scheduling (4 × 250 ms) | ✅ | 2 ms max lag | 2 ms | 1.2 ms | 1.2 ms | 10 ms |
| `MediaRecorder` | ✅ | ✅ | ✅ | ✅ (+ogg) | ✅ (+ogg) | ✅ |
| `MediaSource` / `ManagedMediaSource` | — | ✅ / ✅ | — | ✅ / ✅ | ✅ / ✅ | — |

A page can already capture microphone audio as float PCM, process it on the
render thread, and play generated buffers back sample-accurately with no
audible seam. **A native capture/playback plugin would not beat this.**

## Staying alive when the app isn't in front

This is where the platforms actually differ, and where the one-line fix lives.

Measured by arming a `setInterval(50)` *and* the audio clock before an
excursion and reading both after — plus the **largest gap between ticks**,
because "n ticks short" reads identically whether JS was frozen solid or ran
throttled throughout, and those are opposite answers for a chunk-fed stream.

| window hidden / app backgrounded | JS | longest JS gap | WebAudio | `<audio>` |
| --- | --- | --- | --- | --- |
| Android, backgrounded | full rate (608/608) | 50 ms | alive (40 ms lost/30 s) | alive |
| Android, screen off, **6 minutes** | full rate (7369/7370) | **53 ms** | alive (2.1 s/368 s) | alive |
| Windows, minimized | full rate (466/467) | — | alive | alive |
| GTK4, minimized | **~1 Hz** (579/1026) | **1000 ms** | alive (0 ms/51 s) | alive |
| GTK3, minimized | full rate (1177/1225) | 53 ms | alive (1 ms/61 s) | alive |
| macOS, hidden | **2 Hz** (42 Hz visible) | — | alive (ratio 1.000) | alive |
| **iOS, no `audioSession`** | stalled for the excursion | ≈ excursion | **suspended 15–20 s** | alive |
| **iOS, `audioSession.type = "playback"`** | **alive, ~1 Hz** | **1001 ms** | **alive (1 ms/33 s)** | alive |

**Android holds up over minutes, not just seconds.** Backgrounded with the
screen off for **six minutes** with no foreground service, JS ran at full rate
throughout (7369 of 7370 ticks, longest gap 53 ms) and WebAudio lost 2.1 s of
368 s. That matters because the alternative — a foreground service — would mean
a user-visible notification and a manifest change rather than an enum.

Most of that sorts by engine family — the WebKit ports throttle JS when the
window isn't visible (macOS 2 Hz, iOS ~1 Hz backgrounded, GTK4 ~1 Hz minimized)
while the Chromium ports don't (Android and Windows both full rate). **GTK3 is
the exception, and for a reason worth knowing:** it doesn't throttle because it
never tells the page anything happened. A `visibilitychange` recorder armed
across the excursion saw `["visible"]` and nothing else — WebKitGTK 4.1 does not
propagate the minimized window state to the page, so `document.visibilityState`
stays `"visible"` while the window is iconified.

That is a correctness difference beyond audio: a page that pauses work, a game
that pauses itself, or anything keyed on `visibilitychange` simply never fires
on GTK3. (The GTK4 row's visibility was not recorded — the recorder post-dates
that run — but its throttling indicates the page *was* marked hidden there.)

The useful conclusion for audio is the same everywhere: in none of the six cells
is JS actually *frozen* — every longest-gap reading is a second or less — so a
chunk handed over once a second rides through all of them.

### The iOS finding, and the wrong turn before it

Without `navigator.audioSession`, an iOS app looks suspended in the background:
WebAudio stops and JS stops with it. Two plausible fixes were tried and **both
did nothing** — `UIBackgroundModes: ["audio"]` in the manifest, and then an
app-activated `AVAudioSession(.playback)` in Swift. Three rungs, same result.

The answer was a **web** API. Setting `navigator.audioSession.type = "playback"`
— with no manifest key and no Swift at all — keeps the AudioContext running
(`audioLostMs: 1` over 33 s) and keeps JS running, throttled to about 1 Hz with
a longest gap of **1001 ms**, never frozen.

That is workable for every use case above: the app keeps executing, so a TTS
backend keeps generating, and JS gets a turn every second — enough to hand over
one-second chunks scheduled ahead on the audio clock.

> The wrong turn is worth recording. An earlier draft of this document
> concluded "on iOS a backgrounded app stops running, only queued media plays
> on", and reasoned from there that owning the sink natively might be the only
> way out — a large native playback path. That conclusion was drawn from three
> runs that all happened to leave `audioSession` unset. **The measurement was
> right and the generalisation was wrong**, and it would have justified
> building the most expensive thing in this document.

### Buffering ahead is not an alternative

Worth stating because it looks like one: MSE is available, so a page could try
to run far enough ahead that a freeze doesn't matter. It can't. On-device TTS
generates **slower than real time** — `QwenTTSBackend` measures **RTF 2.52**
after the v0.10.2 work ([`on-device-ai-performance.md`](../on-device-ai-performance.md))
— so the buffer drains about 1.5 s for every 1 s played. There is no lead to
accumulate, only a head start bought by making the user wait. Keeping the app
*running* is the only thing that works, which is what the line above does.

## The three gaps, all of them missing web APIs

| | `navigator.audioSession` | `navigator.mediaSession` | `setSinkId` + output devices |
| --- | --- | --- | --- |
| macOS | ✅ all types accepted | ✅ | ✅ 2 devices, routing accepted |
| iOS | ✅ all types accepted | ✅ | ✅ 2 devices, routing accepted |
| Windows | ❌ | ✅ | ✅ 3 devices, routing accepted |
| GTK3 | ❌ | ✅ | ❌ no `setSinkId` |
| GTK4 | ❌ | ✅ | ❌ no `setSinkId` |
| Android | ❌ | ❌ **absent entirely** | ❌ no `setSinkId` |

**Android is missing all three.** Linux is missing two, Windows one, Apple none.

### 1. Session policy — `navigator.audioSession`, Apple only

The standards-track way to say "this is playback" / "this is a game, duck the
music" / "this is transient". On Apple it exists and every type is accepted.
Nowhere else. This is what use cases 1 and 3 need to behave correctly against
other audio on the device, and what use case 4 needs on iOS.

#### What building it settled

**Desktop has no audio session to drive, and that is a platform fact.** The
proposal assumed Linux would map to PipeWire/PulseAudio stream roles and
Windows to "the Windows session APIs". Measured, both are unreachable from the
shell:

- The playing stream belongs to the **webview's own process** —
  `application.process.binary: WebKitWebProcess` in `pw-dump` on Linux, three
  `msedgewebview2.exe` processes on Windows — and both platforms set audio
  policy *per stream, by its creator*. There is no app-level focus to take.
- WebKit already tags its Linux stream `media.role: Music`, and a stock
  GNOME/PipeWire session loads **no** role-ducking or role-cork module, so the
  role is inert regardless of who sets it.
- Android is the exception, and the reason the fill works there at all: its
  focus is per-**uid**, so the shell can hold it on the webview's behalf.

The cost is small, which is why a uniform API is still the right answer: the
behaviours the type buys — background continuation, not being frozen — were
measured to be *already true* on desktop. So Linux and Windows get the same API
with a documented null effect, rather than a feature-detect an adopter has to
write.

#### What building the Android fill settled

- **Audio focus is the whole mechanism, and it is enough.** The WebView plays
  through its own audio track whose attributes the app can't rewrite, so for a
  while it looked like the type might be unimplementable there. It isn't: what
  the type actually governs is whether *other* audio stops, ducks or continues,
  and that is exactly what holding or declining focus decides. `ambient` is
  implemented as *not requesting focus at all*.
- **`Build.VERSION_CODES.O` splits the API.** `AudioFocusRequest` exists from
  API 26; below that the deprecated `requestAudioFocus(listener, stream, gain)`
  is the only route, and the scaffold's `min_sdk` is 28 — so the old path is
  reachable only for apps that lower it, and is kept for them.
- **Android 16 will mute background playback**, and the log says so out loud:
  `AudioHardening background playback would be muted for <app>, level: partial`
  appeared in `dumpsys audio` during every background excursion. It did not
  actually mute anything at `targetSdk` 34 — the six-minute run above played
  through — but "would be" is a warning about enforcement this app hasn't opted
  into yet. Holding the right focus is the plausible exemption, which makes
  this work more load-bearing over time rather than less. **Unmeasured:** what
  happens at a higher `targetSdk`.

### 2. Transport and now-playing — `navigator.mediaSession`, missing on Android

Absent from Android's embedded WebView — not inert, absent. No metadata, no
lock-screen controls, and the OS never learns audio is playing (confirmed on
device: no media notification while a tone played).

Everywhere else it reaches the OS end-to-end, verified by driving the *real*
control rather than checking for the property:

| | how it was verified | result |
| --- | --- | --- |
| macOS | posted a real `NX_KEYTYPE_PLAY` | `pause` handler ran |
| iOS | tapped pause on the **lock screen** | `pause` handler ran |
| GTK3 / GTK4 | `busctl call … MediaPlayer2.Player Pause` | `pause` handler ran |
| Windows | posted a real `VK_MEDIA_PLAY_PAUSE` | `pause` handler ran |

WebKitGTK even publishes the page's metadata onto MPRIS
(`xesam:title: "swift-pwa probe"`); WebView2 wires SMTC.

#### What building the mediaSession fill settled

Both bugs it turned up failed *silently*, and neither is specific to audio:

- **A `Task {}` in a `@MainActor` function never ran on Android.** It inherits
  the isolation, and Android's main thread runs a Java looper that never drained
  libdispatch's main queue — so the task was created and never scheduled. The OS
  delivered the action, Kotlin forwarded it, Swift yielded it, and nothing was
  at the other end. `Task.detached` was the fix here, and anything else pumping
  an `AsyncStream` from a plugin's `register` had it too.

  This turned out to be **one instance of #216**, which an adopter hit from the
  other direction on Windows: the whole main actor was unreachable off Apple,
  not just from a plugin. Every backend now drains libdispatch's main queue from
  its own event loop (`PlatformMainQueue`), so the hazard is gone — but the
  `Task.detached` spellings are left in place, since they were never wrong.
- **A notification with an unusable small icon is refused, and `notify()` logs
  the exception rather than throwing it.** An app that sets no icon in
  `pwa.json` has an `applicationInfo.icon` that isn't a valid small icon, so the
  call looked successful and nothing ever appeared.

Both were found by bisecting with temporary logging on each side of the bridge,
because every layer reported success. Worth remembering as a shape: when a
capability spans Kotlin → JNI → Swift → bus → JS, "no error anywhere" is the
expected symptom of a break, not evidence against one.

### 3. Output routing — missing on Linux and Android

Device labels and ids are gated behind a media grant on every engine, so this
must be measured **after** one. Measured before, every platform reports zero
outputs and the uniform answer looks like a finding — an earlier draft of this
document said exactly that, and it was wrong.

`setSinkId` is simply absent from WebKitGTK and Android's WebView.

**Decision: don't fill this one** — which reverses this section's first draft,
where it read as "we haven't, not the platform can't". The reason is in the
API's shape rather than in either platform:

**`setSinkId` is per-element.** It is a method on an `HTMLMediaElement` (and on
an `AudioContext`), so a page may legitimately route one element to the speakers
and another to a headset. Everything a *shell* can reach is per-process: on
Linux, PipeWire can move a stream between sinks — that is what `pavucontrol`
does — but the node is the whole `WebKitWebProcess`; and on Android there is no
route-another-process's-media API at all (`setCommunicationDevice` is
communication-only, and `AudioTrack.setPreferredDevice` belongs to whoever
created the track, i.e. the WebView). The contract is therefore
unrepresentable: two elements with different sinks cannot both be honoured, and
the failure would be silent.

**And unlike `audioSession`, an inert fill here would be actively harmful.** A
recorded-but-inert session type costs nothing, because the behaviour it buys on
a phone is already true on desktop. A recorded-but-inert `setSinkId` would tell
a page its audio had been routed when it had not — and `'setSinkId' in element`
is precisely how a page decides whether to offer the user a device picker. Left
absent, an app hides a picker it cannot honour; filled, it shows one that lies.

**So absence is the honest interface here, and that is the line between the two
cases:** fill a web API when a no-op is harmless and the outcome is already
true; leave it absent when a no-op would make the page believe something false.

Linux would additionally need PipeWire client integration, or shelling out to
`wpctl` — a dependency, for an API still implemented incorrectly.

## What to build

The goal is that an adopter writes **ordinary web audio code, once**, and it
behaves the same on five platforms — without owning five devices to find out
where it doesn't. That rules out a parallel namespace: `audio.setSession(...)`
beside `navigator.audioSession` means every app carries a branch, and the
branch only breaks on the platform the developer doesn't have.

So: **native backing for the web APIs that are missing**, installed by the
runtime, feature-detected, never shadowing a real implementation.

| | needs filling on | backed by |
| --- | --- | --- |
| `navigator.audioSession` | Android, GTK3, GTK4, Windows | `AudioManager` focus + attributes; PipeWire/PulseAudio stream roles; the Windows session APIs |
| `navigator.mediaSession` | Android | a native `MediaSession` + media notification |
| `setSinkId` + output enumeration | Android, GTK3, GTK4 | `AudioManager` / `setCommunicationDevice`; PipeWire/PulseAudio sinks |

Each is data-shaped — an enum, a metadata record, a device list — which is the
side of the split that belongs behind native code, with the stream staying on
the web API.

**No manifest key and no Swift call, by default.** The developer's whole
requirement becomes the line the web platform already defines:

```js
navigator.audioSession.type = 'playback';   // or 'ambient' for a game
```

That works on Apple today and would work everywhere with this change. The
polyfill costs nothing when unused — the native side only engages when the page
actually sets a type, names a sink, or publishes metadata — so it can be
installed unconditionally rather than behind an opt-in plugin, which is the
difference between a capability an adopter *finds* and one they have to know to
ask for.

Two consequences worth naming:

- **A default type is the wrong idea, and the API already solves it.** Setting
  `"playback"` for everyone would be right for read-aloud and ambient apps and
  wrong for games — `playback` ignores the mute switch and interrupts the
  user's music, where a game wants `ambient` and should duck instead. The web
  API has both; the runtime should not pick.
- **Android's `MediaSession` needs a notification**, and the scaffold already
  declares `POST_NOTIFICATIONS`. The six-minute measurement says no *foreground
  service* is required for playback itself, so this stays an enum-sized change.

What **doesn't** get built: native capture, native playback, a bridged PCM
path, or an `audio.*` namespace duplicating any of the above.

### Telling the developer, which closes more than the code does

The one line an app needs is invisible by omission: an app that never sets
`audioSession.type` passes every foreground test on every platform and fails
only on a backgrounded iPhone. Someone without that device cannot find it. So
the fix is as much about surfacing it as implementing it.

- **A runtime diagnostic — built.** The first media element that plays, or
  `AudioContext` that reaches `running`, with the type still `auto` produces one
  `console.warn` naming the consequence and the remedy. Media elements need no
  patching (`play` doesn't bubble, but a capturing listener on `document` sees
  it); Web Audio has no equivalent hook, so the global is subclassed —
  transparently, verified for `name`, `instanceof`, the prototype chain and a
  page's own `extends AudioContext`. `OfflineAudioContext` is left alone:
  rendering to a buffer isn't playback.
- **A `doctor` check — built**, and see open question 4 for how its cry-wolf
  problem turned out to be avoidable without a declaration mechanism.
- **The existing tutorials and examples — done.** The on-device AI tutorial
  gained a "speaking it" step, `docs/ai-plugin.md` tells a backend author the
  same, and `CritterFacts` declares a type in both places it plays speech —
  `speak.html` taking the full treatment (metadata, artwork, transport handlers,
  `playbackState` from the element's own events). `HelloPWA` needed nothing: its
  only `audio` is a `getUserMedia` permission demo that neither records nor
  plays.
- **A game tutorial** would exercise the other half of the API — `ambient` or
  `transient` rather than `playback`, so a game doesn't stop the player's music
  — and would be the natural home for the scheduling guidance below. Still open,
  pending input from a game author.

The pattern guidance that goes with it: **schedule on the audio clock, never on
a timer.** Hidden, macOS timers fall to 2 Hz and backgrounded iOS to ~1 Hz,
while the AudioWorklet keeps its full 375 Hz and a buffer scheduled 2000 ms
ahead still fires at 2050 ms. Chunks of a second or more, scheduled ahead, ride
through every cell measured here.

## Found on the way: Android capture is refused in silence

Not part of this work, and worth its own fix — the measurement pass walked
straight into it, which is how an adopter would meet it too.

`getUserMedia` on Android failed with a plain `NotAllowedError` until the probe
added **`ctx.permissions.declare(.microphone)`** in Swift. `pwa.json`'s
`permissions.web.microphone` was already present and did its job — the manifest
carried `RECORD_AUDIO` and `MODIFY_AUDIO_SETTINGS`. The missing piece was the
*runtime* ceiling, and the policy refuses before the OS is consulted.

Three things make it invisible:

1. **The build-time drift check doesn't run.** `swift-pwa build` compares
   `pwa.json` against the live catalog and fails on disagreement — but not for
   a cross-compiled target, and it says so: *"pwa.json permissions not checked
   against the app for --target android"*. The app builds, installs and runs
   with the mismatch intact. This is the case the check exists to catch, on the
   one platform where it's skipped.
2. **The diagnostic never arrived.** [`permissions.md`](../permissions.md)
   documents a console line naming the exact call to add, precisely because the
   refusal is indistinguishable from a user denial by the time it reaches JS.
   Nothing appeared in logcat — only Chromium's own `cr_media: Requires
   MODIFY_AUDIO_SETTINGS and RECORD_AUDIO`. v0.10.0 routed Core diagnostics
   through an installable sink for this reason; the scaffold appears not to
   install one.
3. **Apple hides it.** There the page's own `getUserMedia` never consults the
   embedder (the documented `WKUIDelegate`-never-called limit), so the same app
   works on Apple and fails only on Android — reading as an Android bug rather
   than a missing declaration.

Suggested: make the skipped cross-compile check a **hard error** when
`pwa.json` declares a permission (the compiled declaration can be compared
without running the app), and have the scaffold install a diagnostic sink.

## Open questions

1. **Polyfill mechanics — settled by building it.** Feature-detect
   (`!("audioSession" in navigator)`), define on `Navigator.prototype` where the
   real one lives, and match WebIDL enum semantics by *measuring the engine that
   has the API* rather than reading the spec: an unrecognised value is ignored,
   not thrown, and a non-string is stringified first. Validating in JS rather
   than round-tripping matters — a round trip could only answer after the
   assignment had already returned.
2. **Is GTK3's missing `visibilitychange` worth its own fix?** It is not an
   audio bug — audio is fine there — but a page cannot tell it has been
   minimized, which breaks the ordinary "pause when hidden" pattern and is the
   kind of thing an adopter without a GTK3 box would never find. Worth an issue
   on its own terms.
3. **Does Android hold up over hours, not minutes?** Six minutes is measured
   (below) and clean, on one device. Doze proper engages only after far longer
   device inactivity, and vendor battery management varies. If it turns out a
   long session does get killed, `audioSession` on Android grows a foreground
   service — a user-visible notification and a manifest change.
4. **What exactly should `doctor` look at? — answered, and not the way this
   expected.** The fear was that inferring "uses audio" from web source is a
   heuristic that cries wolf, and that the fix was a declaration mechanism to
   check against. Neither turned out to be needed. Two things removed the
   problem. First, the check fires on a **pairing** — audio signals present
   *and* no mention of `audioSession` anywhere — so it is silent for every app
   that has already dealt with this, which is the population a false positive
   would annoy. Second, it **names the file it matched**, which converts the one
   unavoidable false positive (a bundled framework containing the string
   `AudioContext` for code the app never reaches) from an investigation into a
   glance. Advisory, never a build failure. `.play()` is deliberately not a
   signal: it matches a video element, a Web Animations call and half the game
   loops in existence.

## Alternatives considered

- **The roadmap's plugin (native capture + playback), as written.** Rejected on
  its own terms: "lower-latency and more capable" is not true of any of the five
  engines measured, and bridging PCM would replace a working low-latency path
  with a worse one.
- **A native playback sink to win background execution on iOS.** Seriously
  considered, and it would have been a large build. Ruled out by measurement:
  one line of web API does it.
- **A parallel `audio.*` namespace instead of polyfills.** Honest and duller,
  but it leaves adopters writing two code paths forever and makes Apple — where
  everything already works — the odd one out.
