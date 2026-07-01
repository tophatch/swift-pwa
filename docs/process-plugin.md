# Subprocess plugin (`process.*`)

`ProcessPlugin` launches and manages an external child process from a swift-pwa
app: it streams the child's stdout/stderr to the page as bridge events, feeds
its stdin, and — crucially — tears the child down automatically when the page
that owns it goes away. It's the escape hatch that lets swift-pwa host a "thick"
local backend (a converter, an indexer, a local model server, an out-of-process
synthesizer) rather than only wrapping a thin PWA.

> **Desktop only.** Spawning is available on macOS, Linux, and Windows. iOS and
> Android sandboxes forbid it; `process.stream` there fails with
> `E_UNIMPLEMENTED`.

## Enabling it

`process.*` is opt-in. Register the plugin with a runner in your `configure`
closure:

```swift
import SwiftPWA

try runtime.run { ctx in
    ctx.use(ProcessPlugin(SystemProcess()))
    _ = try ctx.createWindow(...)
}
```

`SystemProcess` is the built-in runner backed by Foundation's `Process`. Tests
inject a fake by conforming to `ProcessRunner` / `ProcessChild` (see
[Testing](#testing)).

## JS API

### `process.stream` — spawn and stream

Spawning *is* subscribing: one streaming call launches the child and yields its
lifecycle. The first frame is always `spawned` (carrying the pid); then any
number of `stdout` / `stderr` frames (bytes are base64-encoded so they survive
the JSON bridge); then a terminal `exit` frame with the status code.

```js
let pid;
const off = __SWIFT_PWA__.subscribe('process.stream', {
    command: 'python3',          // path, or a bare name resolved against PATH
    args: ['synth.py', '--rate', '24000'],
    cwd: '/opt/app',             // optional; defaults to the parent's cwd
    env: { HF_HOME: '/models' }, // optional; merged into the inherited env
    clearEnv: false,             // optional; true → `env` is the *entire* env
}, (frame) => {
    switch (frame.type) {
        case 'spawned': pid = frame.pid; break;
        case 'stdout':  onPCM(base64ToBytes(frame.dataBase64)); break;
        case 'stderr':  console.warn(atob(frame.dataBase64)); break;
        case 'exit':    console.log('exited', frame.code); break;
    }
});
```

Spawn config fields (`ProcessSpawnConfig`):

| Field | Type | Notes |
| --- | --- | --- |
| `command` | `string` (required) | A path (contains a separator) is used verbatim; a bare name is resolved against `PATH` (via `/usr/bin/env` on POSIX, a `PATH`+`PATHEXT` search on Windows). |
| `args` | `string[]` | Defaults to `[]`. |
| `cwd` | `string` | Child working directory. Defaults to the parent's. |
| `env` | `{ [k]: string }` | Merged into the inherited environment by default. |
| `clearEnv` | `boolean` | When `true`, `env` becomes the child's entire environment. |

Frame shape (`ProcessStreamChunk`): `{ type, pid?, dataBase64?, code? }` where
`type` is `"spawned"` | `"stdout"` | `"stderr"` | `"exit"`.

### `process.write` — feed stdin

```js
await __SWIFT_PWA__.invoke('process.write', {
    pid,
    dataBase64: btoa('speak this line\n'),
    closeStdin: false,   // set true to close stdin (EOF) after writing
});
```

`closeStdin: true` with no `dataBase64` just closes stdin — the way to signal
end-of-input to a filter like `cat` or a streaming model that reads to EOF.

### `process.kill` — terminate

```js
await __SWIFT_PWA__.invoke('process.kill', { pid });   // SIGTERM on POSIX
```

`process.write` / `process.kill` on an unknown (or already-exited) pid fail with
`E_NOT_FOUND`.

## Lifetime & teardown

The whole design centers on one guarantee: **a child cannot outlive the page
that spawned it.** Orphaned children are the classic failure mode of hand-rolled
`Process` usage, so the plugin makes it structural.

A child's lifetime is bound to its `process.stream` subscription:

- **The child exits on its own** → the stream emits `exit` and finishes.
- **JS calls the unsubscribe function** (`off()`) → `BridgeRuntime` cancels the
  subscription, whose `onTermination` terminates the child.
- **The owning window closes** → `BridgeRuntime.stop()` cancels all of that
  window's subscriptions, terminating the child the same way.

You never have to track pids for cleanup — killing is only needed when you want
to stop a child *early* while keeping the page open.

## Security

- **Page JS chooses the command.** There is no allow-list; if untrusted content
  can run in your webview, it can spawn anything the plugin permits. Only
  register `ProcessPlugin` in apps that fully trust their bundled web content,
  and treat it like any other native-capability grant.
- Prefer absolute paths for `command` when you control the target, so a hostile
  `PATH` can't shadow it.
- `stdout` / `stderr` are surfaced as raw bytes (base64); the page is
  responsible for decoding/framing them.

## Interim TTS (until a native audio backend ships)

A common case: in-app text-to-speech that currently shells out to an
external (e.g. Python) synthesizer. Wrap it in a `process.stream` and pipe
stdout PCM into an `AudioWorklet` ring buffer:

```js
let pid;
__SWIFT_PWA__.subscribe('process.stream',
    { command: 'python3', args: ['tts_streaming.py'] },
    (f) => {
        if (f.type === 'spawned') pid = f.pid;
        else if (f.type === 'stdout') audioRing.push(base64ToPCM(f.dataBase64));
    });

// Send text to synthesize on stdin.
await __SWIFT_PWA__.invoke('process.write',
    { pid, dataBase64: btoa(JSON.stringify({ text }) + '\n') });
```

When a native `AIBackend` implementing `generateAudioStream` exists, the same
page-side ring-buffer code moves onto `ai.generateAudioStream` unchanged — see
[docs/ai-plugin.md § implementing an audio backend](ai-plugin.md#worked-example-a-custom-on-device-audio-tts-backend).

## Testing

`ProcessPlugin(runner)` takes any `ProcessRunner`, so tests inject a fake:

```swift
final class MockProcessRunner: ProcessRunner, @unchecked Sendable {
    let child: MockProcessChild
    func spawn(_ config: ProcessSpawnConfig) throws -> any ProcessChild { child }
}
```

`MockProcessChild` conforms to `ProcessChild` and drives its own `events`
stream, so tests can assert the `spawned → stdout → exit` sequence, that
`process.write` reaches the child, and that cancelling the subscription calls
`terminate()`. See `Tests/SwiftPWACoreTests/ProcessPluginTests.swift`, which
also runs `SystemProcess` against real `/bin/echo` and `/bin/cat`.
