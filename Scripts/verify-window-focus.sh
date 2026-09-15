#!/usr/bin/env bash
#
# Check that `WindowEvent.didFocus` / `.didBlur` follow the *desktop* on a GTK
# backend, rather than only an explicit `Window.focus()` call (#214).
#
# Both backends used to emit either event only from `focus()` — the app talking
# to itself — so an app could not tell that focus had left it, which is when a
# lock re-engages or watched state is re-read. They are wired to
# `notify::is-active` now, and a compile proves nothing about whether a GObject
# signal actually fires.
#
# **This needs a real, unlocked desktop session on the box.** Under Xvfb a
# scaffolded app maps no window at all (#222), and nothing unmapped can become
# active, so the run would pass vacuously for a backend that emits nothing.
#
# The trigger is a **second window mapping**, not `focus()` or `wmctrl`: a
# Wayland compositor refuses to let an app raise itself (focus-stealing
# prevention), but it does give a newly mapped window focus. So the assertion
# lands on window A, which nothing called anything on — only the signal can
# report that focus left it.
#
# Usage:
#   Scripts/verify-window-focus.sh --host <ssh-host> [--gtk4] [--toolchain <ver>]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${SWIFT_PWA_LINUX_HOST:-}"
GTK4=0
TOOLCHAIN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --gtk4) GTK4=1; shift ;;
        --toolchain) TOOLCHAIN="$2"; shift 2 ;;
        *) echo "usage: $0 --host <ssh-host> [--gtk4] [--toolchain <ver>]" >&2; exit 2 ;;
    esac
done
[ -n "$HOST" ] || { echo "--host (or \$SWIFT_PWA_LINUX_HOST) is required" >&2; exit 2; }

SYNC_ARGS=(--host "$HOST")
[ "$GTK4" -eq 1 ] && SYNC_ARGS+=(--gtk4)
[ -n "$TOOLCHAIN" ] && SYNC_ARGS+=(--toolchain "$TOOLCHAIN")

echo "== syncing the checkout to $HOST =="
"$REPO/Scripts/remote-linux.sh" "${SYNC_ARGS[@]}" sync

# The probe declares `package: "swift-pwa"`, and SwiftPM takes a path
# dependency's package name from its *directory* — so it resolves against the
# default checkout and nowhere else.
ssh "$HOST" "cat > /tmp/focus-probe.swift" <<'SWIFT'
import Foundation
import SwiftPWA

// stderr, and one write per line: the run is killed rather than exiting
// cleanly, so anything still sitting in a buffer would be lost.
func say(_ line: String) {
    FileHandle.standardError.write(Data(("FOCUSPROBE " + line + "\n").utf8))
}

@MainActor
func watch(_ window: any Window, _ name: String) {
    let events = window.eventStream()
    Task.detached {
        for await event in events {
            switch event {
            case .didFocus: say("\(name) didFocus")
            case .didBlur: say("\(name) didBlur")
            default: break
            }
        }
    }
}

@MainActor
func makeWindow(_ ctx: any AppContext, _ title: String) throws -> any Window {
    try ctx.createWindow(WindowConfig(
        title: title, size: Size(width: 500, height: 360),
        content: .remote(URL(string: "about:blank")!)
    ))
}

@main
enum FocusProbe {
    static func main() throws {
        let runtime = try SwiftPWA.runtime()
        try runtime.run { ctx in
            let a = try makeWindow(ctx, "FocusProbeA")
            watch(a, "A")
            say("mapped A")

            Task.detached {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                say("-- mapping B --")
                await MainThread.run {
                    guard let b = try? makeWindow(ctx, "FocusProbeB") else {
                        say("could not create B")
                        return
                    }
                    watch(b, "B")
                    // Closing B hands focus back, so the reverse direction is
                    // measured too rather than inferred from the first.
                    Task.detached {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        say("-- closing B --")
                        await MainThread.run { b.close() }
                    }
                }
                try? await Task.sleep(nanoseconds: 14_000_000_000)
                say("done")
                await MainThread.run { ctx.quit(exitCode: 0) }
            }
        }
    }
}
SWIFT

echo "== building and running the probe in the desktop session =="
GTK4_ENV=""
[ "$GTK4" -eq 1 ] && GTK4_ENV="SWIFT_PWA_GTK4=1"
SWIFTLY=""
[ -n "$TOOLCHAIN" ] && SWIFTLY="swiftly run +$TOOLCHAIN"

ssh "$HOST" "bash -s" <<REMOTE > /tmp/focus-probe-out.txt 2>&1 || true
export PATH="\$HOME/.local/share/swiftly/bin:\$PATH"
export $GTK4_ENV

# Join the logged-in session rather than inventing a display. Which variables
# matter depends on the session type, so they are read off the running
# compositor instead of guessed: an X11 session needs DISPLAY + XAUTHORITY, a
# Wayland one WAYLAND_DISPLAY, and both need the session bus.
COMPOSITOR=\$(pgrep -x "gnome-shell" || pgrep -x "kwin_wayland" || pgrep -x "kwin_x11" \
             || pgrep -x "sway" || pgrep -x "xfwm4" || pgrep -x "mutter" || true)
if [ -n "\$COMPOSITOR" ]; then
    while IFS= read -r line; do
        case "\$line" in
            DISPLAY=*|WAYLAND_DISPLAY=*|XDG_RUNTIME_DIR=*|DBUS_SESSION_BUS_ADDRESS=*|XAUTHORITY=*|XDG_SESSION_TYPE=*)
                export "\$line" ;;
        esac
    done < <(tr '\\0' '\\n' < /proc/\$COMPOSITOR/environ 2>/dev/null)
fi
# A Wayland session's compositor may not carry these itself.
[ -n "\${XDG_RUNTIME_DIR:-}" ] || export XDG_RUNTIME_DIR=/run/user/\$(id -u)
[ -n "\${DBUS_SESSION_BUS_ADDRESS:-}" ] && : || export DBUS_SESSION_BUS_ADDRESS=unix:path=\$XDG_RUNTIME_DIR/bus
[ -n "\${WAYLAND_DISPLAY:-}" ] || { [ -S "\$XDG_RUNTIME_DIR/wayland-0" ] && export WAYLAND_DISPLAY=wayland-0; }

echo "FOCUSPROBE session type=\${XDG_SESSION_TYPE:-?} wayland=\${WAYLAND_DISPLAY:-none} display=\${DISPLAY:-none}"
# The control on the session itself: a locked screen takes focus, so a window
# mapping behind it never becomes active and every check below would pass
# vacuously by being absent.
LOCKED=\$(loginctl show-session \$(loginctl show-seat seat0 -p ActiveSession --value) -p LockedHint --value 2>/dev/null || echo unknown)
echo "FOCUSPROBE session locked=\$LOCKED"

rm -rf /tmp/focus-probe
mkdir -p /tmp/focus-probe/Sources/FocusProbe
cp /tmp/focus-probe.swift /tmp/focus-probe/Sources/FocusProbe/main.swift
cat > /tmp/focus-probe/Package.swift <<'PKG'
// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "FocusProbe",
    dependencies: [.package(path: "REMOTE_CHECKOUT")],
    targets: [.executableTarget(name: "FocusProbe",
        dependencies: [.product(name: "SwiftPWA", package: "swift-pwa")])]
)
PKG
sed -i "s|REMOTE_CHECKOUT|\$HOME/swift-pwa|" /tmp/focus-probe/Package.swift

cd /tmp/focus-probe
$SWIFTLY swift build 2>&1 | grep -E "error:|Build complete" | tail -3
BIN=\$($SWIFTLY swift build --show-bin-path 2>/dev/null | tail -1)
# Built first, so the budget below is the app running rather than compiling.
timeout 45 "\$BIN/FocusProbe" > /tmp/focus-probe.log 2>&1 || true
grep FOCUSPROBE /tmp/focus-probe.log || echo "FOCUSPROBE (no output from the app)"
REMOTE

echo
echo "-- what the run saw --"
grep -o 'FOCUSPROBE .*' /tmp/focus-probe-out.txt | sed 's/^/   /' || echo "   (nothing)"
echo

ORDER=$(grep -o 'FOCUSPROBE .*' /tmp/focus-probe-out.txt | sed 's/FOCUSPROBE //' | tr '\n' '|')
failed=0
expect() { # pattern label
    case "$ORDER" in
        *"$1"*) echo "PASS  $2" ;;
        *) echo "FAIL  $2"; failed=1 ;;
    esac
}
# `after` rather than `expect` wherever something else may legitimately land in
# between — closing a window blurs it before the next one is focused, and
# requiring the two to be adjacent would fail on correct behaviour.
after() { # first second label
    case "$ORDER" in
        *"$1"*"$2"*) echo "PASS  $3" ;;
        *) echo "FAIL  $3"; failed=1 ;;
    esac
}
# Controls first. Without either, nothing below means anything.
expect "locked=no" "the session is unlocked (a lock screen would hold focus)"
expect "mapped A" "the app started and created its first window"
expect "A didFocus" "window A became active — so it really is on screen"
# The discriminator: nothing called anything on A here.
after "-- mapping B --" "A didBlur" "mapping B reports didBlur on A, which nothing asked for"
expect "B didFocus" "and didFocus on B"
after "-- closing B --" "A didFocus" "closing B hands focus back to A"

[ "$failed" -eq 0 ] || exit 1
echo
echo "Desktop-driven focus changes reach WindowEvent on this backend."
