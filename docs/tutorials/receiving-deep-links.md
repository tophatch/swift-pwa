# Receiving deep links (`myapp://…`)

**Who this is for:** you want a link — in an email, a chat message, a
notification, a QR code, another app — to open *your* app at a particular
place. Two halves: **declare** the scheme you handle (so the OS routes it to
you), and **receive** the arriving URL in your web code.

Assumes you've met the bridge — see [Talking to the native side](talking-to-the-native-side.md).

> Uses swift-pwa **0.11+**. One `url_schemes` declaration generates the
> registration on all five platforms.

---

## The receiving half — one event, everywhere

Whenever the OS routes a URL in your scheme to your app, swift-pwa emits it on
the `app.openURL` channel. Subscribe once, at startup:

```js
__SWIFT_PWA__.on('app.openURL', ({ url }) => {
  const target = new URL(url);            // myapp://note/42?focus=title
  router.go(target.host + target.pathname, target.searchParams);
});
```

The payload is `{ url, urls }` — `urls` is the full list (one OS event can
carry several links) and `url` is the first, which is the case you almost
always have.

**Subscribe early, not behind a click.** The event is emitted *retained*, so a
link that **launched** your app is replayed to your listener the moment you
subscribe — but only to whoever subscribes. A link is far more likely to arrive
at a cold app than a running one, so a subscription deferred until some later
interaction misses the main case. (One consequence of retention: a manual page
reload re-subscribes and re-receives the launch link.)

Nothing about parsing is special: the URL is a string, and `new URL(…)` works
on a custom scheme. Note that `myapp://note/42` puts `note` in `host` and
`/42` in `pathname` — if you'd rather have the whole thing as a path, use a
single slash (`myapp:/note/42`) or just parse the string yourself.

---

## The declaring half — one key

```json
"url_schemes": ["myapp"]
```

That's it, for every platform. Unlike file types — MIME types on Linux and
Android, extensions on Windows — a URL scheme is the same string everywhere, so
there's one list rather than one per platform. `swift-pwa build` turns it into
whatever each OS needs:

| platform | what's generated |
| --- | --- |
| macOS / iOS | `CFBundleURLTypes` in the `Info.plist` (role `Viewer`) |
| Android | an `ACTION_VIEW` intent-filter with `DEFAULT` + **`BROWSABLE`** and one `<data android:scheme>` per scheme |
| Linux | `MimeType=x-scheme-handler/myapp;` in the `.desktop` entry, plus the `%U` field code on `Exec=` |
| Windows (MSIX) | a `windows.protocol` extension (`<uap:Protocol Name="myapp"/>`) |
| Windows (portable) | `register-url-schemes.cmd` / `unregister-url-schemes.cmd` next to the exe |

Schemes are accepted however you write them — `"MyApp"`, `"myapp:"`,
`"myapp://"` all mean `myapp`. Pick something unlikely to collide: schemes are
first-come, first-served on most platforms, and there's no registry.

### Opening your own links is a second declaration

`url_schemes` says what your app *handles*. What it may *open* is
`external_urls.schemes`, and the two don't imply each other:

```json
"url_schemes":    ["myapp"],
"external_urls": { "schemes": ["myapp"] }
```

You need both only if your own page calls `system.openURL('myapp://…')` — a
notification that re-enters the app, or a link in your own content. Most apps
want just the first. They're separate because handling a scheme and being
allowed to launch one are different permissions, and silently granting the
second would mean an app could open URLs it never asked to.

### `https://` links are a different mechanism

Declaring `https` in `url_schemes` is refused at build time. Making
`https://example.com/note/42` open your app is **universal links** (Apple) /
**App Links** (Android): the same intent-filter shape, plus a signed
`apple-app-site-association` / `assetlinks.json` file served from the domain
you're claiming, so the OS can verify you own it. That server-side half is
outside what a build tool can generate, and it isn't covered here.

---

## Try it

Deep links need a real installed bundle — `swift-pwa dev` runs the bare
executable, which the OS has no registration for.

- **macOS:** `swift-pwa build --target macos`, then `open "myapp://hello"`.
  A freshly built `.app` may not be the registered handler until the OS has
  seen it; open the app once, or
  `lsregister -f build/macos/MyApp.app`
  (in `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/`).
  Both cold launch and warm delivery route to `app.openURL`.
- **iOS:** build and install, then `xcrun simctl openurl booted "myapp://hello"`
  on the simulator. iOS shows an **"Open in 'MyApp'?"** confirmation for a link
  arriving from an unverified source — that's the OS, not your app, and it
  doesn't appear when your own app opens its own scheme.
- **Android:** build/install, then
  `adb shell am start -a android.intent.action.VIEW -d "myapp://hello"`.
- **Linux:** build the AppImage and install its `.desktop` entry (or
  `xdg-mime default myapp.desktop x-scheme-handler/myapp`), then
  `xdg-open "myapp://hello"`.
- **Windows:** install the MSIX, or run `register-url-schemes.cmd` from the
  portable folder, then `start myapp://hello`.

---

## Where to go next

- [Opening files with your app](opening-files-with-your-app.md) — the same
  shape for documents, on the `app.openFile` channel.
- [JavaScript API](../javascript-api.md#appopenurl--inbound-deep-links) — the
  `app.openURL` and `system.openURL` references.
- [Shipping your app](shipping-your-app.md) — bundling, which deep links
  require.
