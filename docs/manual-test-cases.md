# Manual test cases

Things that need a human + real OS to confirm — install machinery,
on-device behaviour, network round-trips, visual smoothness — that the
unit suite can't cover. Run through the relevant module's cases before
tagging a release; file an issue against any case that doesn't pass.

This doc starts with the auto-updater (the v0.4 surface area most prone
to "compiles clean, fails on real install") and grows module-by-module
as we add features whose pass criteria need a real OS in the loop.

## How to use this doc

1. Pick the module(s) the release touches.
2. Walk every case in order — they're sequenced so earlier cases set
   up the artifacts later ones consume.
3. Tick the checklist at the end. If anything fails, fix and re-run
   from that case onward.
4. After release, update the **Last verified** column in the coverage
   table below with the tagged version + date.

When adding new cases:

- Cover only what the unit tests *can't*. If the unit suite already
  pins a behaviour, don't duplicate it here.
- Each case has a **What it covers** one-liner, **Setup**, **Steps**,
  and **Pass criteria** — keep that shape so a release engineer can
  scan the doc as a checklist rather than reading prose.
- Add a one-line **Why human-only** note if it's not obvious why we
  can't automate the case — helps future-you not "fix" the test by
  automating it incorrectly.

## Coverage

| Module       | Cases | Last verified  |
|--------------|-------|----------------|
| Updater      | 8     | **macOS ✓**¹   |

¹ **macOS cases 1 + 2 verified end-to-end 2026-07-14** against a real
bundled `Examples/HelloPWA` + the real `AppleUpdater` (ad-hoc and
codesigned builds; a v0.3.0→v0.4.0 cycle over a local signed manifest).
Verification hardened three cleanup gaps (self-deleting helper, no
unverified bytes left on failure, staging dir removed after install).

**Linux case 3 (AppImage) verified end-to-end 2026-07-14** on the GTK
box (GTK4 build, headless Xvfb): the full check→download→verify→atomic
`rename(2)` swap→`setsid` relaunch cycle (confirmed via a
self-perpetuating smoke loop + the on-disk hash flipping v1→v2), plus
the cross-filesystem **EXDEV** copy-then-rename fallback (staging on
tmpfs, AppImage on ext4). Surfaced a fourth cleanup gap now fixed across
Linux + Windows: the per-version staging dir is dropped after a
successful swap (parity with macOS).

**Windows portable verified end-to-end 2026-07-14** on the x64 box,
headlessly via a console harness driving the real `WindowsUpdater`
(`installMode: .portable`, `executablePath:` override): download
(streaming), Ed25519 verify, `Move-Item` swap, staging cleanup, and a
directly observed `Start-Process` relaunch. **Windows MSIX** is
compile-verified only — its `Add-AppxPackage` E2E needs a signed
package, a trusted cert, and sideloading (the box lacks `makeappx`), so
it's still to be walked. **iOS** (`itms-services://`) needs an enterprise cert.

---

## Updater

The runtime updaters (`AppleUpdater`, `LinuxAppImageUpdater`,
`WindowsUpdater`) all bottom out in OS-level install commands —
`/usr/bin/ditto`, `rename(2)`, `Move-Item`, `Add-AppxPackage`,
`itms-services://` — that no test process can usefully exercise. Most
of the real failures we've shipped have been there: helper scripts
that don't survive the parent exit, kernel mmap quirks, MSIX activation
contexts that hang silently. These cases pin those.

### Per-release setup (do once per release cycle)

Build two versions of an app you control — call them `vN-1` and `vN` —
both wired with the relevant `Updater` backend. Bump `pwa.json`'s
`version` between the two builds so `updater.check` will report `vN`
as newer.

```bash
# 1. Generate a release keypair (only the first time).
swift run swift-pwa updater keygen \
    --private-key ./release.priv --public-key ./release.pub
# Paste the printed `updater.public_key` block into pwa.json.

# 2. Sign each platform's artifact.
swift run swift-pwa updater sign \
    --private-key ./release.priv \
    ./build/MyApp-vN-arm64.app.tar.gz       # → .app.tar.gz.sig

# 3. Assemble the manifest the runtime's endpoint URL serves.
swift run swift-pwa updater manifest \
    --version <vN> \
    --private-key ./release.priv \
    --platform darwin-aarch64=./build/MyApp-vN-arm64.app.tar.gz=https://updates.example.com/MyApp-vN-arm64.app.tar.gz \
    --platform linux-x86_64-appimage=./build/MyApp-vN.AppImage=https://updates.example.com/MyApp-vN.AppImage \
    --platform windows-x86_64-portable=./build/MyApp-vN.exe=https://updates.example.com/MyApp-vN.exe \
    --platform windows-x86_64-msix=./build/MyApp-vN.msix=https://updates.example.com/MyApp-vN.msix \
    --output ./build/manifest.json

# 4. Upload the artifacts + manifest to the endpoint URL the
#    `vN-1` build's `AppleUpdater(endpoint:)` (etc.) points at.
```

Keep the resulting artifacts around — every case below references
them.

> **Driving it with `Examples/HelloPWA`.** HelloPWA's `Updater` backend is
> env-selectable, so you don't have to write a throwaway app: set
> `SWIFT_PWA_UPDATER_ENDPOINT` (+ `SWIFT_PWA_UPDATER_PUBKEY` = the
> `updater keygen` public key) and it wires the *real* platform backend
> instead of its `DemoUpdater`. `SWIFT_PWA_UPDATER_SMOKE=1` then drives
> check→download→install on launch and logs `UPDATER_SMOKE` markers to
> stderr (and to `$SWIFT_PWA_UPDATER_SMOKE_LOG` if set) — a headless
> alternative to clicking the demo card. Launch the built app's binary
> **directly** (`…/HelloPWA.app/Contents/MacOS/HelloPWA`), not via `open`,
> so it inherits the env. Notes: re-running `updater manifest` over an
> existing file needs **`--force`**; and a **local `http://` endpoint**
> (vs. a real `https://` one) needs an ATS opt-in —
> `"macos": { "info_plist": { "NSAppTransportSecurity": { "NSAllowsLocalNetworking": true } } }`.

### 1. macOS `.app` auto-update end-to-end

**What it covers:** signed-tarball download, Ed25519 verify against
the configured public key, `ditto`-based bundle swap, helper
process surviving parent exit, re-launch as the new version.

**Setup:**

- Install `vN-1` of the app to `/Applications/MyApp.app`. Code-signed
  with a Developer ID so Gatekeeper accepts it.
- Manifest at `https://updates.example.com/manifest.json` advertises
  `vN`, signature signed with the matching private key.

**Steps:**

1. Launch `vN-1` from `/Applications`.
2. Click **Check for updates** → invokes `updater.check`.
3. Click **Run full flow** → invokes `updater.run` and watch the
   progress bar in the demo card / your app's UI.
4. Click **Install and relaunch** once the **Ready to install** event
   arrives.

**Pass criteria:**

- Step 2 logs the new version + a `pub_date`. Reject the case if it
  reports `up to date` or throws.
- Step 3's progress bar ticks smoothly (multiple updates over the
  lifetime of the download) — not a single jump from 0 → 100 %.
- Step 4 closes the v`N-1` window, then a new window opens within ~2 s
  showing v`N` (verify via the app's About panel or
  `mdls -name kMDItemVersion /Applications/MyApp.app`).
- `/Applications/MyApp.app` is the new bundle (different
  `CFBundleShortVersionString`, codesign still valid:
  `codesign --verify --deep --strict /Applications/MyApp.app`).
- No leftover `swift-pwa-update-*.sh` in `$TMPDIR` (the helper deletes
  itself when it finishes).

**Why human-only:** The `ditto` swap happens after `exit(0)`, in a
`nohup`-detached helper re-parented to launchd. No test process can
observe both sides of that handoff in one run.

### 2. macOS — wrong-key signature is rejected

**What it covers:** the verifier's failure path, with a clear UI signal.

**Setup:**

- Same `vN` artifact as case 1, but re-sign the manifest with a
  *different* private key (or hand-edit one byte of the signature).

**Steps:**

1. Launch `vN-1`, click **Run full flow**.

**Pass criteria:**

- The flow reaches `available`, then errors during download with a
  `signature verification failed` message visible in the UI.
- No staged file is left in
  `~/Library/Caches/<bundle-id>/SwiftPWAUpdates/<version>/` — the
  bundle in `/Applications` is untouched.

### 3. Linux AppImage auto-update end-to-end

**What it covers:** atomic `rename(2)` swap on the running AppImage,
mmap durability across the swap, `setsid`-detached re-launch.

**Setup:**

- Build `vN-1` AppImage with `swift run swift-pwa build --target linux`,
  put it in `~/Apps/MyApp.AppImage`, `chmod +x`. Run it from a real
  AppImage launch (so the `APPIMAGE` env var is set) — *not* from
  `swift run`, which leaves `APPIMAGE` unset and `installAndRelaunch`
  reports it.
- Manifest as in the per-release setup, signed with a matching key.

**Steps:**

1. Launch `vN-1`. Confirm `APPIMAGE=$HOME/Apps/MyApp.AppImage` in
   the process's environment (e.g. `cat /proc/$(pgrep MyApp)/environ
   | tr '\0' '\n' | grep ^APPIMAGE`).
2. Trigger **Run full flow**, watch the progress bar tick.
3. Trigger **Install and relaunch** on `readyToInstall`.

**Pass criteria:**

- Progress bar ticks smoothly (same criterion as case 1).
- App exits, the AppImage's mtime updates, and a new window opens
  within ~2 s showing `vN`.
- `~/Apps/MyApp.AppImage` is the new file (compare SHA-256 against
  the published artifact). Old inode is gone (find it with
  `lsof | grep MyApp.AppImage` *during* the swap window — should
  show two distinct inodes briefly).
- Cross-filesystem path: stage the update on a different filesystem
  by setting `XDG_CACHE_HOME` to a `tmpfs` mount, repeat the case.
  Should succeed via the `EXDEV` copy-then-rename fallback (no
  errors logged).

**Why human-only:** Atomic-rename behaviour under a running mmap is
a kernel guarantee that's only meaningful when a real process is
holding the inode open across the rename.

### 4. Windows portable `.exe` auto-update end-to-end

**What it covers:** PowerShell helper script surviving parent exit,
`Move-Item` swap of the running EXE, `Start-Process` re-launch.

**Setup:**

- Install `vN-1` portable bundle to `%LOCALAPPDATA%\MyApp\`. Run from
  there (so the helper has write permission to the EXE's directory).
- Configure `WindowsUpdater(installMode: .portable, publicKey: …)`.

**Steps:**

1. Launch `vN-1` from the install dir.
2. Trigger **Run full flow** → watch the progress bar.
3. Trigger **Install and relaunch** on `readyToInstall`.

**Pass criteria:**

- Progress bar ticks smoothly.
- Window closes; new window opens within ~3 s showing `vN`.
- `%LOCALAPPDATA%\MyApp\MyApp.exe` is the new EXE
  (`Get-FileHash MyApp.exe -Algorithm SHA256` matches the published
  artifact).
- No PowerShell window flashes up — `-WindowStyle Hidden` is
  honoured by the helper.

**Permission failure sub-case:** install `vN-1` to
`C:\Program Files\MyApp\` (with admin), launch as a normal user.
**Run full flow** + **Install and relaunch** should still complete
the download but the swap fails — the app exits and **does not**
re-launch. No corruption (the EXE on disk is still `vN-1`,
verifiable by re-launching by hand).

### 5. Windows MSIX auto-update with post-install relaunch (NEW in v0.4)

**What it covers:** the v0.4 MSIX relaunch path —
`Get-AppxPackage -Name <identity>` resolves the family name from the
*new* package on disk, `Start-Process shell:AppsFolder\…` launches
the updated AUMID. Replaces the v0.3 behaviour where MSIX updated
silently and the user had to re-launch from Start.

**Setup:**

- Sign and install `vN-1` MSIX (`swift run swift-pwa build --target
  windows --package-format msix --sign <thumbprint>` to produce it,
  `Add-AppxPackage` to install). Note the `Identity.Name` from the
  generated `AppxManifest.xml`.
- Configure `WindowsUpdater(installMode: .msix, msixIdentityName:
  "<identity>", publicKey: …)`.

**Steps:**

1. Launch `vN-1` via Start menu (so it runs under the MSIX
   activation context).
2. Trigger **Run full flow**.
3. Trigger **Install and relaunch** on `readyToInstall`.

**Pass criteria:**

- App exits.
- Within ~3 s, a new window opens showing `vN` — without the user
  manually finding it in Start. **This is the v0.4 behaviour;
  v0.3 stopped after `Add-AppxPackage` and the user had to re-launch.**
- `Get-AppxPackage -Name <identity>` shows the new version on the
  command line.
- The relaunched process's PID is different from the pre-install one
  (confirm via Task Manager).

**Identity-not-set sub-case:** Repeat with
`msixIdentityName: nil`. Step 3 should still update the package on
disk — `Get-AppxPackage -Name <identity>` shows `vN` — but **no
auto-relaunch** happens; the user has to find it in Start. Same
v0.3 behaviour, preserved as the documented opt-out.

**Why human-only:** AUMID resolution requires the OS package
registry to have committed the new MSIX, and the relaunch is a
~500 ms `Start-Sleep` race that's only meaningful in real time.

### 6. iOS enterprise / ad-hoc update

**What it covers:** the `itms-services://` system-installer hand-off,
which is the only iOS update path swift-pwa supports (App Store apps
update through Apple's machinery, outside the runtime's control).

**Setup:**

- `vN-1` distributed via Apple Developer Enterprise Program profile or
  ad-hoc provisioning profile that lists the test device. Install via
  `itms-services://` link or a manual Safari install on the device.
- Manifest's `ios-aarch64-enterprise` platform entry's `url` points at
  the `manifest.plist` file (the install plist Apple defines), *not* at
  the `.ipa`. The `signature` field is empty — Apple's signing chain
  validates the .ipa, not our Ed25519 key.

**Steps:**

1. Launch `vN-1` on the device.
2. Trigger **Check for updates** → expect new-version reply.
3. Trigger **Install and relaunch**.

**Pass criteria:**

- Step 3 brings up the iOS system "Install <App>?" prompt.
- Tapping **Install** dismisses the prompt; the app icon on the home
  screen briefly shows a download progress ring, then the new version
  installs.
- Re-launching from the home screen runs `vN`.

**Why human-only:** `itms-services://` is a system intent — the system
installer takes over completely. No `URLSession` involvement to mock.

### 7. minisign(1) interop

**What it covers:** keys + signatures produced by the upstream
`minisign(1)` CLI are accepted by the runtime verifier with no
preprocessing.

**Setup:**

- Install `minisign(1)` via Homebrew (`brew install minisign`) or
  apt (`apt install minisign`).

**Steps:**

```bash
# Generate a minisign keypair. The -W flag skips the password
# prompt for unattended use; -W keys are still legacy 'Ed' mode.
minisign -G -W -p ./mini.pub -s ./mini.priv

# Sign with -Sl (legacy 'Ed', not the prehashed 'ED' default).
minisign -Sl -s ./mini.priv -m ./build/MyApp-vN-arm64.app.tar.gz \
    -t "swift-pwa minisign interop test"
# → produces ./build/MyApp-vN-arm64.app.tar.gz.minisig
```

1. Paste the *contents* of `./mini.pub` (full two-line file) into
   `pwa.json`'s `updater.public_key`. Escape the `\n` between the
   two lines so the JSON parses.
2. In the manifest, paste the contents of `…minisig` as the
   `signature` field for the matching platform target. Multiline
   string — escape newlines as `\n`.
3. Run case 1 (macOS auto-update) end-to-end against this
   manifest + key combo.

**Pass criteria:**

- Case 1's pass criteria all hold — `updater.run` reaches
  `readyToInstall`, install + relaunch succeed.
- No "minisign uses unsupported algorithm" or "wrong byte length"
  errors in the log.

**Prehashed-rejection sub-case:** sign without `-l`
(`minisign -S -s ./mini.priv -m …`). Re-paste the resulting
`.minisig` into the manifest. **Run full flow** should error during
download with a message containing `prehashed 'ED' algorithm` and
pointing at `minisign -Sl`. No staged file left behind.

### 8. CLI `swift-pwa updater` end-to-end on a real artifact

**What it covers:** the publishing CLI produces output the runtime
accepts, on every host the CLI can run on.

**Steps (run on each of macOS, Linux, Windows):**

```bash
swift run swift-pwa updater keygen \
    --private-key ./tmp.priv --public-key ./tmp.pub --force
swift run swift-pwa updater keygen \
    --private-key ./tmp.priv --public-key ./tmp.pub --force --minisign

# Both forms should sign cleanly:
swift run swift-pwa updater sign \
    --private-key ./tmp.priv ./some-artifact.bin
swift run swift-pwa updater sign \
    --private-key ./tmp.priv --minisign ./some-artifact.bin
```

**Pass criteria:**

- `keygen` produces a private key file with `0600` perms on macOS /
  Linux (Windows doesn't enforce, expected).
- `keygen --minisign` produces a public-key file whose first line is
  `untrusted comment: minisign public key (swift-pwa)`.
- `sign --minisign` produces a four-line file matching minisign's
  shape (untrusted comment, base64, trusted comment, base64).
- A signature produced on host A is accepted by a verifier running
  on host B (cross-platform sanity — pick any pair).

**Why human-only:** File-permission check and cross-platform
signature handoff aren't covered by per-host unit tests.

---

## Checklist (copy into the release PR)

- [x] **Updater 1.** macOS `.app` auto-update end-to-end ✓ 2026-07-14
- [x] **Updater 2.** macOS wrong-key rejection ✓ 2026-07-14
- [x] **Updater 3.** Linux AppImage auto-update end-to-end (+ EXDEV
      sub-case) ✓ 2026-07-14
- [x] **Updater 4.** Windows portable EXE auto-update ✓ 2026-07-14
      (happy path via console harness; the Program Files
      permission-failure sub-case is not yet walked)
- [ ] **Updater 5.** Windows MSIX auto-update with post-install
      relaunch (+ no-identity sub-case)
- [ ] **Updater 6.** iOS enterprise / ad-hoc update
- [ ] **Updater 7.** minisign(1) interop (+ prehashed rejection
      sub-case)
- [ ] **Updater 8.** CLI publishing pipeline on each host
