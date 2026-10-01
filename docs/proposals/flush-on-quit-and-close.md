# Proposal: a chance to flush on quit and close

> **Status: decided, not implemented** (#281). Decisions from 2026-10-01 are
> under [Decisions](#decisions).

## The problem

Between "the app is going away" and the process exiting, nothing in an app
gets to run, on any backend:

- **Quit** never closes a window. `quit` stops the platform loop and calls
  `exit()`: no `willClose`, no `bridge.stop()`, no `pagehide`, and the page's
  last invoke is cut off. macOS goes through `NSApp.terminate` with no
  `applicationShouldTerminate`, and exits about 50ms later (measured in #281).
- **Closing a window** lets the close through unconditionally
  (`windowShouldClose` → `true`, GTK `delete-event` / `close-request` →
  `FALSE`, Win32 `WM_CLOSE` → `DestroyWindow`) and stops the window's bridge
  in the same main-thread turn (GTK3, GTK4, Windows, iOS) or one hop later
  (macOS). `willClose` is emitted, but it can't reach the page: delivery takes
  several async hops, and by then the subscription is cancelled and the
  webview detached.
- **Navigation works**: an invoke posted from `pagehide` reaches Swift before
  the next document's `hello` cancels the old document's work (4 of 4 in #281).

So anything an app batches is lost at quit, on both sides: a debounced save in
the page, and a timer-batched write in Swift. An adopter can observe
`NSApplication.willTerminateNotification` for the Swift half on macOS, but
nothing covers the other four backends, and nothing covers the page.

### Why an adopter can't fix it themselves

The hooks that would let them (`applicationShouldTerminate`, a vetoable
close, `WM_ENDSESSION`, `onStop`) are all inside the runtime. Shortening a
debounce only narrows the window.

## Shape

Two halves, one sequence. When a window is about to go, whether closed or
because the app is quitting:

1. **The page gets the web platform's own teardown**: `visibilitychange` to
   `hidden`, then `pagehide`. No new JS API. A page that already flushes on
   `visibilitychange`, which is the standard advice for page lifecycle, is
   covered without changing a line. This follows the repo's rule: make the
   existing web API work everywhere rather than adding `swiftpwa.onQuit()`
   beside it.
2. **The bridge stays up until that document's in-flight invokes finish**,
   bounded by a deadline, and only then stops.
3. **Swift handlers run** once the window, or on quit every window, has been
   through steps 1–2, also bounded. Then the window closes or the process
   exits.

```swift
ctx.beforeClose { reason in
    await sync.flushPending()
}
```

`reason` says why: `.window(id)` (one window closing, the app staying up),
`.quit` (Cmd-Q / Ctrl+Q / `app.quit` / last window), `.system` (logout,
shutdown, SIGTERM), or `.backgrounded` on mobile, where there is no quit and
a suspended app can be killed without being told. Handlers
run concurrently. Missing the deadline logs which handler was still running,
and the app quits anyway. An app that never registers one gets steps 1–2 for
free.

### How the page gets a real `pagehide`

**Recommended: navigate the closing window to `about:blank`.** Every engine
then runs its genuine unload steps, `visibilitychange` → `hidden` and then
`pagehide`, which is the row #281 measured working. The bridge change this
needs: while a window is closing, the next document's `hello` must **not**
cancel the old document's invokes. Today `adoptDocument` → `cancelDocumentWork`
does exactly that, and an async handler started from `pagehide` would be cut
off. Instead `stop()` waits for `invocations` to drain, or for the deadline.

Rejected alternative: dispatch synthetic events with `evaluateJavaScript`. It
needs `visibilityState` faked with `defineProperty`, `persisted` faked on a
synthetic `PageTransitionEvent`, and it diverges from what a browser does in
ways a page can observe. The real unload is cheaper to get right.

### The window doesn't wait on screen

The window is **hidden first** (`orderOut`, `gtk_widget_hide`,
`ShowWindow(SW_HIDE)`), then flushed, then destroyed, so a close still looks
instant. Hidden pages are throttled, and macOS stops rAF, but the unload events
and the invoke that follows them don't depend on rendering. This needs
measuring per engine before it is relied on.

### Per backend

| Backend | Quit hook | Window close | OS-initiated |
| --- | --- | --- | --- |
| macOS | `applicationShouldTerminate` → `.terminateLater`, then `reply(toApplicationShouldTerminate: true)`; covers ⌘Q, `app.quit`, last window | `windowShouldClose` → `false`, hide, flush, `close()` | logout / restart come through `applicationShouldTerminate` |
| GTK3 / GTK4 | inside `quit()`, before `gtk_main_quit` / `g_main_loop_quit` | `delete-event` / `close-request` → `TRUE`, hide, flush, destroy | SIGTERM via `g_unix_signal_add` |
| Windows | inside `quit()`, before `PostQuitMessage` | `WM_CLOSE` → hide, flush, `DestroyWindow` | `WM_QUERYENDSESSION` / `WM_ENDSESSION` (OS allows ~5s) |
| iOS | no quit; `sceneDidEnterBackground` + `beginBackgroundTask`, reason `.backgrounded` | scene destruction | — |
| Android | `onStop`, reason `.backgrounded`; `app.quit` / primary close → `.quit` | `AndroidWindow.close()` | — |

Mobile is the honest mapping, not a stretch: there, backgrounding *is* the last
guaranteed chance, and `visibilitychange` → `hidden` is what the page already
gets. The Swift hook is the missing half.

## Found while mapping this (separate from the proposal)

Each of these is a bug or a stale doc on its own; worth an issue each:

- **Android: `nativeQuit` is declared and never called.** An Activity finish
  never reaches Swift, and the runtime thread stays blocked until the OS kills
  the process. Three comments say otherwise (`AndroidAppRuntime.swift`,
  `swiftpwa_android.h`). Verified by grep.
- **Android: `app.quit` doesn't `finish()` the Activity**, despite the comment
  saying it does; it `exit()`s the process directly. Verified by reading.
- **macOS: `app.quit`'s `exitCode` is probably ignored.** `NSApp.terminate`
  calls `exit()` itself, so `runForever`'s `exit(pendingExitCode ?? 0)` is never
  reached. Inferred from AppKit's documented behaviour, **not measured**.
- **`docs/tutorials/making-it-feel-native.md`'s minimize-to-tray recipe can't
  be done**: it says to cancel the close on `willClose`, and nothing can cancel
  a close. Not made possible here: cancelling a close is out of scope (see
  [Decisions](#decisions)). The recipe needs rewriting or removing.
- **`docs/swift-api.md` shows `main.subscribe { }`**, which doesn't exist; the
  method is `eventStream()`.

## Non-goals

- **Cancelling a close**, including a `beforeunload`-style "save changes?"
  prompt. See [Decisions](#decisions).
- **Guaranteeing a write survives a crash or a force-quit.** Nothing can.
  This covers every orderly way out.

## Decisions

Settled 2026-10-01:

1. **Fixed deadlines, no override**: 1s for a window close, 3s for quit. An
   override couldn't be honoured everywhere. The OS sets the real ceiling on
   the paths that matter most: iOS cuts a background task short when it
   wants, Windows gives session end about 5s, and Android promises nothing
   after `onStop`. A knob that works on three platforms is the kind of gap
   the repo's parity rule exists to avoid.
2. **Named `beforeClose`**, not `beforeQuit`. It reads right for a window
   closing, the app quitting and a mobile app being backgrounded alike, which
   is why `.window(id)` is one of its reasons.
3. **No cancelling a close.** The one plausible exception is a "save
   changes?" confirmation. That is a separate feature with its own HIG on
   each platform (a document-modal sheet and `.terminateCancel` on macOS, a
   dialog on GTK and Windows, nothing on mobile), and it isn't built here.
4. **One PR** for all five platforms. OS-initiated paths (SIGTERM,
   `WM_ENDSESSION`, logout) go in it only if they measure cleanly; otherwise
   they're documented under each platform's Known limitations.

## Verification

#281's probe, made a persistent script per platform: a page that writes a
marker through a synchronous command in `willClose`, `visibilitychange`, and
`pagehide`; plus an async command that sleeps 300ms before writing, which
proves the bridge waits; and a Swift `beforeClose` that writes its own. The
database is read afterwards. Rows: `window.close`, the native close button or
shortcut, `app.quit`, ⌘Q / Ctrl+Q, the last window closing, SIGTERM (Linux),
logoff (Windows), and backgrounding (iOS, Android). Control: navigation, which
already writes 4 of 4. A handler that never returns must still let the app
quit within the deadline. Run on the Mac, both Linux boxes, Windows x64, the
iPhone and the Tab S10+.
