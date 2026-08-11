# Saving and loading files (Export / Import)

**Who this is for:** you built something in HTML/CSS/JavaScript — a game, a tool, a notebook — and you're wrapping it with [swift-pwa](https://github.com/tophatch/swift-pwa) to ship it as a real desktop (or mobile) app. Now you want a proper **Save** and **Open** experience: the native file picker your players already know, writing to a real file on disk.

You don't need to know Swift. This tutorial has you paste **two short JavaScript files** and **two lines of Swift** into the project that `swift-pwa` generates for you. That's it.

The neat part: the same code keeps working in a plain web browser. When your app runs inside the native shell, it uses the real OS file dialogs; when it runs in a browser tab (like during development), it quietly falls back to the browser's own download / file-picker. **One codebase, no forks.**

> **Game saves work exactly the same way.** Our example saves a little notes app to a `.json` file, but "save the player's progress to a file" and "load it back" is the identical pattern — swap "notes" for "your save data."

> Needs swift-pwa **0.5.1 or newer**.

---

## The big picture

Here's the whole flow. Don't worry about the details yet — it's just two round-trips between your web code and the native shell:

```
Your web app (JavaScript)                 The native shell (Swift)
  ┌─ user clicks "Export" ─────────────────────────────────────────┐
  │   ask the shell to show a Save dialog  ──▶  native Save panel    │
  │   shell hands back the chosen file path ◀──  (user picks a spot) │
  │   ask the shell to write your text there ──▶  file saved ✅      │
  └─────────────────────────────────────────────────────────────────┘
  ┌─ user clicks "Import" ─────────────────────────────────────────┐
  │   ask the shell to show an Open dialog  ──▶  native Open panel   │
  │   shell hands back the chosen file path ◀──  (user picks a file) │
  │   ask the shell to read the text back   ──▶  your data, restored │
  └─────────────────────────────────────────────────────────────────┘
```

The "ask the shell to…" part is a single function call: `__SWIFT_PWA__.invoke("some.command", { ...options })`. It returns a Promise. That's the entire bridge.

---

## Before you start

You'll need:

- **Your existing web app** — at minimum an `index.html` that loads your JavaScript. In our example, the app keeps its notes in the browser's `localStorage` under one key, as JSON text.
- **The `swift-pwa` CLI** installed, plus a Swift toolchain. For a Mac build that means macOS 15+ and Xcode; other platforms are covered in the [platform setup docs](../). If you just want to follow along, the macOS path is the quickest.

---

## Step 1 — Turn your web app into a swift-pwa project

From the folder that holds your web app, run `init`. Because there's already a web app there, swift-pwa **adopts it in place**: it adds the small native "shell" around your app and *leaves your existing files alone*.

```sh
swift-pwa init "Field Notes" --bundle-id com.example.fieldnotes
```

(If for some reason it doesn't auto-detect your app, add `--in-place` to force it.)

You'll end up with this — note that your `web/` folder is untouched:

```
your-app/
  pwa.json                 ← settings for your app (name, window size, …)
  Package.swift            ← the Swift build file (you won't edit this)
  Sources/FieldNotes/
    App.swift              ← the shell's entry point — we edit this once, in Step 2
    AndroidEntry.swift     ← only matters if you ship to Android
  web/                     ← YOUR app, exactly as it was
    index.html
    …
```

### A quick word on the app name

In `pwa.json`, **`name`** is the friendly label people see — the window title, the dock, the Finder. It can have spaces: `"Field Notes"`. You don't have to do anything special for that; swift-pwa figures out the internal program name from your project automatically. (There's an optional `executable_name` field, but you only need it in the unusual case of a project that builds more than one app — ignore it otherwise.)

---

## Step 2 — Switch on the "files" and "dialogs" features

swift-pwa keeps things lean: the file-reading and file-dialog features are **off by default**, so apps that never touch files don't carry that baggage. You turn them on with two lines.

Open `Sources/FieldNotes/App.swift`. The scaffold already created a function called `configure` — that's where your app gets set up. Add the two `ctx.use(...)` lines inside it:

```swift
import SwiftPWA

// (the scaffold generated this part for you)
@MainActor
func configure(_ ctx: any AppContext) throws {
    // 👇 Add these two lines. They expose file + dialog features to your web code.
    ctx.use(FsPlugin(SystemFs()))         // fs.*     → read/write files
    ctx.use(DialogPlugin(SystemDialog())) // dialog.* → native Open/Save panels

    // … the createWindow(…) line the scaffold already wrote stays here …
}
```

**That's the entire Swift part of this tutorial.** You won't touch Swift again. These two features automatically use the right native pieces on each platform (Mac panels, Linux choosers, Windows dialogs, Android's file system) — you don't choose; swift-pwa does. (One wrinkle on **iOS**, covered below: the save *dialog* this tutorial uses doesn't exist there, so iOS saves go through `dialog.exportFile` instead — same idea, one call.)

---

## Step 3 — Add a tiny "bridge" helper to your web code

The shell hands your JavaScript a global object, `__SWIFT_PWA__`, with one method you care about: `invoke(command, options)`, which returns a Promise.

Rather than call it all over your app, we'll wrap the two things we need — *save to a file* and *open a file* — in a small helper. Crucially, the helper also tells the caller **when there's no native shell at all** (i.e. you're in a plain browser), so we can fall back gracefully.

Create `web/bridge.js`:

```js
// bridge.js — a small wrapper around the swift-pwa native bridge.
//
// Each helper returns one of three things, so the caller knows what happened:
//   false   → no native shell (you're in a browser → use the browser fallback)
//   null    → the shell is here, but the user clicked Cancel
//   a value → success
//
// (Note: "no shell → false" vs "cancelled → null" is the one bit of cleverness
//  here. It lets your app fall back in a browser, but do nothing on Cancel.)

// What file types the dialogs should show. Change "json" to your own extension.
const FILTER = [{ name: "Field Notes", extensions: ["json"] }];

// Is the native shell present? (false when running in a normal browser tab.)
export function hasNativeBridge() {
  return typeof globalThis !== "undefined" && !!globalThis.__SWIFT_PWA__;
}

function bridge() {
  return (typeof globalThis !== "undefined" && globalThis.__SWIFT_PWA__) || null;
}

// Show a native Save dialog, then write `contents` to the file the user picks.
export async function nativeSaveFile({ defaultName, contents, title } = {}) {
  const b = bridge();
  if (!b) return false; // no shell — caller should fall back to a browser download

  const res = await b.invoke("dialog.saveFile", {
    title: title || "Export",
    defaultName: defaultName || "field-notes.json",
    filters: FILTER,
  });

  const path = res && res.path;
  if (!path) return null; // user cancelled the dialog

  await b.invoke("fs.writeText", { path, contents });
  return path; // success — the file path we wrote to
}

// Show a native Open dialog, then read back the text of the file the user picks.
export async function nativeOpenFile({ title } = {}) {
  const b = bridge();
  if (!b) return false; // no shell — caller should fall back to a file input

  const res = await b.invoke("dialog.openFile", {
    title: title || "Import",
    filters: FILTER,
    multiple: false,
  });

  const path = res && res.paths && res.paths[0];
  if (!path) return null; // user cancelled the dialog

  const out = await b.invoke("fs.readText", { path });
  return { path, contents: out && out.contents }; // success
}
```

Two ideas worth remembering from this file:

- **A dialog gives you a path; the file feature reads/writes it.** You always pair them: `dialog.saveFile` picks *where*, then `fs.writeText` does the writing. (On locked-down platforms like the Mac App Store, picking the file in a dialog is also what *grants* your app permission to touch it — another reason to always go through the dialog.)
- **"No shell" and "Cancelled" are different.** No shell (`false`) means fall back to browser behavior. Cancelled (`null`) means the user changed their mind — just do nothing.
- **On iOS, save through `dialog.exportFile` instead.** iOS has no "pick a location, then write to it" panel, so `dialog.saveFile` returns `null` there. `dialog.exportFile` is the content-first version — you hand it the bytes, it shows the export picker and does the write for you — and it works on every platform, so it's a fine single code path if you ship iOS. Swap the two calls above for one:

  ```js
  // Portable "save this content" — works on desktop, Android, and iOS.
  const res = await b.invoke("dialog.exportFile", {
    title: title || "Export",
    defaultName: defaultName || "field-notes.json",
    dataBase64: btoa(contents),        // or: path: "<a file you already wrote>"
    filters: FILTER,
  });
  return (res && res.path) || null;    // destination, or null if cancelled
  ```

---

## Step 4 — Hook up your Export and Import buttons

Now the app code. It tries the native dialogs first; if there's no shell (you're testing in a browser), it falls back to the browser's built-in download and file-picker. Same file, both worlds.

```js
import * as Bridge from "./bridge.js";

const NOTES_KEY = "field-notes";

// However your app already reads/writes its state, plug it in here.
// (For a game, this would be "serialize the save" / "load the save".)
function currentNotesJson() {
  return localStorage.getItem(NOTES_KEY) || "[]";
}
function loadNotesJson(text) {
  JSON.parse(text);                  // make sure it's valid before we keep it
  localStorage.setItem(NOTES_KEY, text);
  renderNotes();                     // your existing redraw function
}

// ---- EXPORT ----------------------------------------------------------------
export async function exportNotes() {
  const json = currentNotesJson();

  // Native path: real Save dialog.
  if (Bridge.hasNativeBridge()) {
    try {
      const path = await Bridge.nativeSaveFile({
        defaultName: "field-notes.json",
        contents: json,
      });
      if (path) toast("Exported.");  // null means the user cancelled — do nothing
    } catch (e) {
      toast("Export failed.");
    }
    return;
  }

  // Browser fallback: trigger a normal download.
  const url = URL.createObjectURL(new Blob([json], { type: "application/json" }));
  const a = Object.assign(document.createElement("a"), {
    href: url,
    download: "field-notes.json",
  });
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

// ---- IMPORT ----------------------------------------------------------------
export async function importNotes() {
  // Native path: real Open dialog.
  if (Bridge.hasNativeBridge()) {
    try {
      const res = await Bridge.nativeOpenFile();
      if (res && res.contents) loadNotesJson(res.contents); // null = cancelled
    } catch (e) {
      toast("Import failed.");
    }
    return;
  }

  // Browser fallback: a hidden <input type="file">.
  const input = Object.assign(document.createElement("input"), {
    type: "file",
    accept: ".json,application/json",
  });
  input.onchange = () => {
    const file = input.files && input.files[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      try {
        loadNotesJson(String(reader.result));
      } catch (e) {
        toast("Import failed.");
      }
    };
    reader.readAsText(file);
  };
  input.click();
}
```

Wire `exportNotes` and `importNotes` to your buttons (e.g. `document.getElementById("export").onclick = exportNotes;`). That's the whole feature.

> `toast(...)` is just a stand-in for "show the user a little message." Use whatever you already have, or delete those lines.

---

## Step 5 — Build it and try it

```sh
swift-pwa build --target macos      # builds for your current machine
open "build/Field Notes.app"
```

Click **Export** — a real macOS Save panel appears, and your JSON lands wherever you choose. Click **Import** — a real Open panel, and the file's contents flow back into your app.

Now open the *same* `web/` folder in a browser (for example, run `python3 -m http.server` in that folder and visit the page). The buttons still work — they just use the browser's download and file-picker instead. You didn't change a line.

---

## A cheat-sheet of the commands used here

Every call is `await __SWIFT_PWA__.invoke(command, options)`. It returns a Promise that resolves with the result, or rejects if something goes wrong.

| Command | Options you pass | What you get back |
|---|---|---|
| `dialog.saveFile` | `{ title?, defaultName?, defaultPath?, filters? }` | `{ path }` — `path` is `null` if cancelled (no-op on iOS — see `exportFile`) |
| `dialog.exportFile` | `{ title?, defaultName?, filters?, dataBase64? / path? }` | `{ path }` — writes the content to the chosen location; `null` if cancelled. Works on iOS too |
| `dialog.openFile` | `{ title?, defaultPath?, filters?, multiple? }` | `{ paths }` — empty array if cancelled |
| `dialog.openDirectory` | `{ title?, defaultPath?, multiple? }` | `{ paths, path, bookmarks, bookmark }` — `paths` empty (and `path` `null`) if cancelled; `path` is the first selection |
| `dialog.resolveBookmark` | `{ bookmark }` | `{ path, stale, bookmark }` — `path` is `null` if the remembered location is no longer reachable |
| `fs.writeText` | `{ path, contents }` | `{}` |
| `fs.readText` | `{ path }` | `{ contents }` |
| `fs.writeBinary` | `{ path, dataBase64 }` | `{}` |
| `fs.readBinary` | `{ path }` | `{ dataBase64 }` |

`filters` is a list of file-type groups: `[{ name: "Field Notes", extensions: ["json"] }]` (extensions have no leading dot).

There's more in both features — `fs.exists`, `mkdir`, `remove`, `readDir`, `copy`, `rename`, `metadata`, and `dialog.message` / `dialog.confirm` — all called the same `invoke` way. The full list lives in the [JavaScript API reference](../javascript-api.md).

---

## Things that trip people up

- **The bridge is ready before your code runs.** swift-pwa injects `__SWIFT_PWA__` at the very start, so it's there by the time your scripts execute. Still, *check for it* with `hasNativeBridge()` rather than assuming — that's what makes the browser fallback possible.
- **Cancel is not an error.** If the user closes the Save/Open dialog, you get back `path: null` (or an empty `paths`), *not* a thrown error. Treat it as "never mind" and move on — the helpers above already return `null` for this.
- **Big files? Don't use base64.** Text files go across as-is. Binary files (`fs.readBinary` / `fs.writeBinary`) travel as base64-encoded text, which is fine for save files but wasteful for, say, large images or audio. For big media, prefer loading it through a URL in your page instead of round-tripping base64.
- **App sandbox (Mac App Store / iOS).** On those platforms your app can only touch its own private folder *plus* whatever the user explicitly picks in a dialog. That's the deeper reason to always pair a `dialog.*` pick with `fs.*` — the dialog is what unlocks access to that file.
- **Remembering a location needs the bookmark, not the path.** If your app wants to come back to a folder or file on the next launch — a library folder, a recent-files list — store the `bookmark` the pick returned and redeem it with `dialog.resolveBookmark`. A path string is enough on Linux, Windows, and unsandboxed macOS; on iOS and Android it isn't, because the permission the user granted lives on the token rather than the path. `resolveBookmark` gives you back a path that's live again, or `null` if the user has since moved, deleted, or revoked it. The full contract is in the [JavaScript API reference](../javascript-api.md#dialog).
- **One codebase is the whole point.** Because everything falls back to plain browser APIs, you can build and test your game in a browser tab all day and only produce the native app when you actually want to ship it. No special "native-only" branches in your code.
