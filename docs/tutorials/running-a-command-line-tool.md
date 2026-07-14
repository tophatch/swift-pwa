# Running a command-line tool

**Who this is for:** your app needs to drive an external program — transcode with `ffmpeg`, run a Python script, shell out to `git`, pipe through a CLI. `process.*` lets your web code spawn a subprocess, stream its output live, feed it input, and kill it — with the child's lifetime tied to your subscription so nothing is left running.

This is a **desktop-only** feature (macOS, Linux, Windows) — the iOS and Android sandboxes forbid spawning processes.

New to the bridge? Read [Talking to the native side](talking-to-the-native-side.md) first.

> Uses swift-pwa **0.8+**.

---

## The big picture

```
  process.stream  ──▶ spawn the child, stream stdout/stderr back live
  process.write   ──▶ send bytes to its stdin
  process.kill    ──▶ terminate it
       │
       └─ unsubscribe (or close the window) ──▶ child is killed automatically
```

---

## Step 1 — Turn on the plugin (Swift)

In `configure` (`Sources/MyApp/App.swift`):

```swift
#if os(macOS) || os(Linux) || os(Windows)
    ctx.use(ProcessPlugin(SystemProcess()))
#endif
```

On iOS/Android the plugin isn't available, so guard the registration (or just leave it off for those targets); calling `process.*` there returns `E_UNIMPLEMENTED`.

---

## Step 2 — Spawn and stream

`process.stream` is a **subscribe** — it spawns the command and streams frames back. The first frame is always `spawned` (with the `pid` you'll need for `write`/`kill`), then `stdout`/`stderr` chunks, then a final `exit` with the code:

```js
let pid;
const stop = __SWIFT_PWA__.subscribe('process.stream', {
  command: 'ffmpeg',                       // path, or a bare name found on PATH
  args: ['-i', 'in.mov', '-y', 'out.mp4'], // optional
  cwd: '/work',                            // optional
  env: { LANG: 'C' },                      // optional, merged into inherited env
}, (frame) => {
  switch (frame.type) {
    case 'spawned': pid = frame.pid; break;
    case 'stdout':  console.log(decode(frame.dataBase64)); break;
    case 'stderr':  console.warn(decode(frame.dataBase64)); break;   // ffmpeg logs here
    case 'exit':    console.log('done, code', frame.code); break;
  }
});

// stdout/stderr arrive base64-encoded (so binary output works too):
function decode(b64) { return atob(b64); }              // text
// for binary: Uint8Array.from(atob(b64), c => c.charCodeAt(0))
```

Output is base64 in both directions — decode `dataBase64` with `atob` for text, or to a `Uint8Array` for binary.

---

## Step 3 — Send input, or stop it

Feed stdin (base64) using the `pid` from the `spawned` frame — handy for a REPL or a filter:

```js
await __SWIFT_PWA__.invoke('process.write', {
  pid,
  dataBase64: btoa('print("hello")\n'),
});

// Close stdin (EOF) when you're done writing — lets a filter finish:
await __SWIFT_PWA__.invoke('process.write', { pid, closeStdin: true });

// Or terminate outright:
await __SWIFT_PWA__.invoke('process.kill', { pid });
```

---

## Step 4 — Cleanup is automatic

This is the part that makes `process.*` safe: **the child is bound to your subscription.** When you call the `stop()` function returned by `subscribe` — or the window closes, or the app quits — swift-pwa terminates the child for you. No orphaned `ffmpeg` chewing CPU after the user navigates away.

```js
const stop = __SWIFT_PWA__.subscribe('process.stream', { command: 'ffmpeg', args }, onFrame);
// …later, or on window close — the child dies either way:
stop();
```

You still get a clean `exit` frame when a process finishes on its own; the automatic kill only kicks in when the subscription ends *before* the process does.

---

## Errors & gotchas

- **A missing/misspelled `command`** surfaces as a stream error with code `E_HANDLER` (not `E_NOT_FOUND`) — the message has the detail. `process.write`/`process.kill` against an unknown or already-exited `pid` reject with `E_NOT_FOUND`.
- **Ship or locate the binary yourself.** `command` is resolved against `PATH` (or an absolute path). If your app depends on a tool being present, check for it (spawn `--version`) and guide the user, or bundle the binary alongside your app and pass its absolute path.
- **Desktop only.** Feature-detect before showing subprocess UI: `const { commands } = await __SWIFT_PWA__.invoke('__platform.info'); if (!commands.includes('process.stream')) { /* hide it */ }`.
- **Testing:** `ProcessPlugin` takes any `ProcessRunner`, so you can inject a mock in tests instead of spawning real processes — see [docs/process-plugin.md](../process-plugin.md).

---

## Where to go next

- [docs/process-plugin.md](../process-plugin.md) — the full reference, including the injectable `ProcessRunner`/`ProcessChild` seam.
- [Talking to the native side](talking-to-the-native-side.md) — the bridge these commands ride on.
- [Shipping your app](shipping-your-app.md) — when you're ready to release (and to think about bundling any tools you depend on).
