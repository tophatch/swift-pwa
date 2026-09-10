# Proposal: a standard Edit menu, so text fields work

> **Status: implemented.** Shipped in the `Unreleased` section of
> [`CHANGELOG.md`](../../CHANGELOG.md). The problem statement below is the
> original one, from a shipping adopter app on macOS 15. Everything the
> implementation contradicted is **corrected in place** rather than left
> standing, and [What measuring changed](#what-measuring-changed) collects the
> findings that only came out of running it.

## The problem

**No swift-pwa app on macOS could select-all, copy, paste, cut, or undo in a
text field.** Not one. The keystrokes arrived at the app and produced a system
beep.

Measured in a focused `<input type="text">`:

| keystroke | result |
| --- | --- |
| unmodified character *(control)* | lands in the field |
| ⌘A — Select All | nothing, beep |
| ⌘C — Copy | nothing, beep |
| ⌘V — Paste | nothing, beep |
| ⌘X — Cut | nothing, beep |
| ⌘Z — Undo | nothing, beep |
| ⌘M — Minimize | nothing |
| ⌘W — Close Window | nothing |

The control matters: an unmodified keystroke through the identical path lands
in the field, so the app is frontmost, the field is focused, and the event
queue is working. Only the modified ones died.

Nothing in the adopter's web layer was involved. The app has no `keydown`
handler, no `preventDefault`, and no `user-select` rule anywhere.

> **Corrected.** The original text added "the page never sees these events to
> begin with". That is wrong: a ⌘-modified `keydown` *does* reach the page in
> `WKWebView` — it is how a web app intercepts ⌘S or ⌘K — and measuring this
> mattered, because it is what proves a page that handles ⌘A itself still wins
> after the fix. The adopter's actual point stands: no handler of theirs was
> suppressing anything.

### Why

`MacAppRuntime` assigns a main menu at
[`MacAppRuntime.swift:33`](../../Sources/SwiftPWAWebKit/Mac/MacAppRuntime.swift),
and `makeMainMenu()` built exactly one submenu: the app menu, with About /
Hide / Hide Others / Show All / Quit. There was no Edit menu and no Window
menu.

On macOS the editing shortcuts are not a property of the text field. They are
**main-menu key equivalents**, dispatched down the responder chain to
`selectAll:`, `copy:`, `paste:`, `cut:`, `undo:`. A key equivalent that matches
no menu item is never dispatched at all — it falls off the end of the responder
chain, and `NSBeep` is the sound of that happening. `NSTextView` inside
`WKWebView` implements every one of those actions and is sitting there ready to
receive them; nothing ever sent them.

This is the same mechanism the existing code already documented for ⌘Q:

> Minimal application menu so ⌘Q / ⌘H / About work out of the box. Without an
> `NSApp.mainMenu`, AppKit installs nothing — the app silently has no menu bar
> and ⌘Q is a no-op.

The fix went one submenu deep and stopped. ⌘Q worked; ⌘V did not.

### Why an adopter could not fix it themselves

`NSMenu` appears in exactly two files in the repo — `MacAppRuntime` and
`SystemTray` — and neither is reachable from `AppContext`. There was no
adopter-facing menu API, so an app that wanted a working paste had to reach
around the framework into `NSApp.mainMenu` from its own `configure(_:)`, after
the runtime had already set it. That is a workaround against a private
arrangement, and it would silently rot the moment `makeMainMenu` changed.

The default has to be right, because there is no other lever.

## Shape

`makeMainMenu(for:)` gains two submenus. All actions are responder-chain
selectors with a `nil` target, which is what makes them enable and disable
themselves against whatever is focused — WebKit answers
`validateUserInterfaceItem(_:)` for the editing actions, so Paste greys out
when the field is not editable without swift-pwa knowing anything about the
page.

- **Edit** — Undo, Redo, Cut, Copy, Paste, Paste and Match Style, Delete,
  Select All.
- **Window** — Minimize, Zoom, Close, with `NSApp.windowsMenu` set so AppKit
  keeps the window list and its checkmark current itself.
- **Services** in the app menu, via `NSApp.servicesMenu`.

Two selectors are worth a note. `undo:` and `redo:` are not declared on any
public AppKit class — they are `NSUndoManager` responder-chain messages — so
they have to be written as `Selector(("undo:"))`, the string form. And
`pasteAsPlainText(_:)` is `NSTextView`'s, not `NSText`'s.

> **Corrected.** The proposal's sketch set `app.windowsMenu` inside
> `makeMainMenu()`, which is a `static func` with no `app` in scope — it did
> not compile. The function now takes the `NSApplication`.

### Should it be configurable?

The menu itself: no. A text field that cannot paste is broken in every app, on
every kind of page, for every adopter — there is no app for which the right
answer is "no Edit menu". An adopter-facing menu API (custom titles, adopter
items, a `pwa.json` key) is a real feature and a genuinely harder design, and
it should not block this. Ship the correct default; let the customization
proposal argue its own case later. An app that wants more can still append to
`NSApp.mainMenu` in `configure(_:)`, which runs after the runtime sets it.

> **Added after review.** One thing here *did* need to be configurable, and the
> original proposal missed it entirely — see below.

### What ⌘W exposes

The original proposal treated the Window menu as a free ride on the Edit menu.
It is not. macOS is the only platform here where an app outlives its windows —
Linux and Windows exit when the last window closes, and
`MacWindow.windowShouldClose` returns `true` unconditionally with no
`applicationShouldHandleReopen` anywhere — so giving an app a working ⌘W
creates a state it could not previously reach: **a running app with a menu bar,
no window, and no way back.** A Dock click did nothing, because the runtime
cannot ask an app to build a window again after `configure` has returned.

The fix is for the runtime to remember the `WindowConfig` the last window was
created from (post-`WindowStateStore` restore, so a reopened window lands where
the closed one was) and rebuild from it on
`applicationShouldHandleReopen(_:hasVisibleWindows:)`. The description of the
window is what has to survive, not a factory closure.

That makes the behaviour a real choice, so `macos.last_window_closed` selects
it: `reopen` (default — Finder and Safari behaviour), `keep-running` (a
menu-bar app), `quit` (a single-window utility, and what Linux and Windows
already do). It seeds `ctx.lastWindowClosed` in the generated `App.swift` at
`init` time, the way the `window` block does, and `swift-pwa build` rejects an
unspelled value rather than ignoring it.

## Non-goals

- **An adopter-facing menu API.** Separate proposal. This one only fixes the
  default so apps stop shipping broken text fields.
- **Localization of menu titles.** The existing app menu is English-only; this
  matches it rather than solving a problem the file does not already have.
- **The other platforms.** GTK and WebView2 handle editing accelerators inside
  the web view without a menu bar, because neither routes them through one.
  Still unmeasured, and cheap to check with the probe below.
- **iOS.** UIKit key commands are a different mechanism entirely
  (`UIKeyCommand`, `buildMenu(with:)`). A hardware keyboard on iPad has the
  same class of problem, is the most likely of the four to actually be broken,
  and is not addressed here.

## What measuring changed

Five things, none of which were visible from reading the code.

**1. The driver could not have caught this, and now can.** Synthetic input is
delivered with `NSWindow.sendEvent`, one level *below* the
`NSApplication.sendEvent` step that dispatches menu key equivalents. A driven
⌘V could only ever do nothing, however right the menu was. An unhandled
injected event is now offered to the main menu where it falls off the responder
chain (`DriverWindow.noResponder`). `drive type` also gained `--modifiers`;
the wire and `InputModifiers` already carried modifiers, so only the CLI verb
was missing — the original proposal overstated that gap.

**2. Menu-first delivery would have been a lie.** Offering ⌘-keys to the menu
*before* the window is simpler and wrong: measured against a genuine keystroke,
a page that handles ⌘A and calls `preventDefault` keeps the key — its handler
runs and the field is not selected. Menu-first reversed that. Doing it at
`noResponder` reproduces AppKit's real order, and the driver now agrees with a
real keystroke on both cases.

**3. A shift-bearing synthetic keystroke carried the wrong character.** A real
⇧⌘Z sends `"Z"`; the driver sent `"z"`, and AppKit matches key equivalents on
that string, so ⇧⌘Z matched no item. It looked exactly like a broken Redo when
the menu item was correct and the event was wrong.

**4. Menu shortcuts need an active app, and that is not fixable.** A menu
item's action is sent with a `nil` target, and AppKit routes those through
`NSApp.keyWindow` — which an inactive app does not have. Measured:
backgrounded, `active=false key=nil` and ⌘A does nothing; activated, the same
keystroke selects the field. Dispatching down the driven window's own responder
chain gets past the routing but still fails WebKit's
`validateUserInterfaceItem`, and forcing past *that* would have the driver
report an editing capability a real user doesn't have. So `drive type
--activate` brings the app forward instead, opt-in per keystroke. A **locked
screen** has no active app either, which is worth knowing before concluding a
run has found a bug.

**5. Two instruments lied, and a control caught both.** Reading `AXEnabled` on
the menu items reported everything disabled — until the same query against
**TextEdit**, whose Edit menu unquestionably works, reported exactly the same.
The AX reading says nothing about menu validation. Separately, a batch of
"failures" against the bundled `.app` turned out to be a locked screen. Both
are the reason the acceptance list below no longer gates on Paste greying out.

## Verification

Everything except the greying-out observation is drivable, with no System
Events and no TCC grant:

```bash
swift-pwa drive eval "JSON.stringify(window.setup('hello world'))"
swift-pwa drive type --key a --modifiers command --activate
swift-pwa drive eval "window.probe().selected"     # → "hello world"
```

Acceptance, in a focused text field in a real app:

- [x] ⌘A selects the field's contents
- [x] ⌘C copies the selection to the **system** pasteboard (checked with
      `pbpaste`, so it isn't an app-local one)
- [x] ⌘V pastes the system pasteboard at the caret
- [x] ⌘X cuts
- [x] ⌘Z undoes, ⇧⌘Z redoes
- [x] A page that handles ⌘A itself still wins — its handler runs and
      `preventDefault` holds, matching a genuine keystroke
- [ ] ⌘M minimizes, ⌘W closes the window, and reopening from the Dock brings
      it back — **needs an unlocked screen**; not yet measured
- [ ] Paste greys out when focus is not in an editable field. An
      *observation*, not a gate: WebKit answers `validateUserInterfaceItem`
      from editor state it gets back from the web process asynchronously, and
      there is no cheap automated instrument for it (see finding 5).

A regression guard for the menu's shape lives in `MainMenuTests` — it cannot
prove a keystroke edits a field, but it catches the failure that produced this
proposal: the items quietly not being there.
