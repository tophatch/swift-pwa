#!/usr/bin/env bash
#
# `window.snapshot`: does the page get a picture of *itself*, and is it fast
# enough to animate with (#255)?
#
# The instrument is the thing to distrust here. A snapshot that comes back
# blank, black, or the wrong size still decodes, still draws, and still reports
# a plausible width — so this doesn't check that a PNG arrived. It paints the
# page a known colour with a known rectangle in it and reads the pixels back
# out of the returned image:
#
#   size      the picture is the window's CSS size times devicePixelRatio,
#             which is what a page needs to size a canvas
#   content   a pixel sampled inside the rectangle is the rectangle's colour,
#             and one outside it is the background's. A blank capture fails
#             both; a capture of the wrong window fails the second.
#   absent    `window.canSnapshot` agrees with whether `window.snapshot` works,
#             so an app can ask once instead of catching an error per call.
#
# Then it times the round trip — page to page: snapshot, encode, bridge, decode
# to an `ImageBitmap` — over three kinds of content, because what a snapshot
# costs is almost entirely how well the picture compresses, and one page would
# give one number that reads as "the" number.
#
# Usage: verify-window-snapshot.sh [--repo <dir>] [--simulator] [--keep] [--dump <dir>]
#   --simulator  drive an iOS Simulator build instead of the host app
#   --dump <dir> also write each variant's PNG there, to look at by eye — the
#                check that no automated one replaces
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=0
DUMP=""
DRIVE_TARGET=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --simulator) DRIVE_TARGET=(--simulator); shift ;;
        --dump) DUMP="$2"; mkdir -p "$DUMP"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

WORK="${TMPDIR:-/tmp}/swift-pwa-window-snapshot"
APP_NAME="SnapshotProbe"
APP="$WORK/$APP_NAME"
CLI="$REPO/.build/debug/swift-pwa"

cleanup() { [[ "$KEEP" -eq 1 ]] || rm -rf "$WORK"; }
trap cleanup EXIT

HEADLESS=()
if [[ "$(uname)" != "Darwin" && -z "${DISPLAY:-}" ]] && command -v xvfb-run >/dev/null; then
    HEADLESS=(xvfb-run -a)
fi

echo "== building the CLI =="
(cd "$REPO" && swift build --product swift-pwa >/dev/null)

echo "== scaffolding $APP_NAME =="
rm -rf "$WORK"; mkdir -p "$WORK"
(cd "$WORK" && "$CLI" init "$APP_NAME" >/dev/null)
cd "$APP"
sed -i.bak -e 's|\.package(url: "https://github.com/tophatch/swift-pwa", from: "[^"]*")|.package(path: "'"$REPO"'")|' Package.swift
# SwiftPM names a path dependency after its *directory*, so a checkout that
# isn't called `swift-pwa` leaves the target depending on a package name that
# no longer exists.
sed -i.bak -e "s|package: \"swift-pwa\"|package: \"$(basename "$REPO")\"|" Package.swift
rm -f Package.swift.bak
cp "$REPO/Package.resolved" Package.resolved 2>/dev/null || true

# The probe page and the expression evaluated against it are shared with
# Scripts/verify-window-snapshot.ps1, which runs the same checks on Windows —
# two copies of a page whose exact colours the checks depend on is a trap.
cp "$REPO/Scripts/snapshot-probe/index.html" web/index.html

if [[ ${#DRIVE_TARGET[@]} -eq 0 ]]; then
    echo "== building the app =="
    swift build >/dev/null 2>"$WORK/build.err" || { tail -20 "$WORK/build.err" >&2; exit 1; }
fi
# `drive --simulator` bundles and installs the app itself, so there is nothing
# useful to pre-build for that path.

# One eval does everything: it is the *page's* round trip being measured, and
# splitting it across driver calls would measure the driver instead.
PROBE_JS="$(cat "$REPO/Scripts/snapshot-probe/probe.js")"

echo
echo "== driving =="
[[ -n "$DUMP" ]] && PROBE_JS="${PROBE_JS/__DUMP__/true}" || PROBE_JS="${PROBE_JS/__DUMP__/false}"

OUT=$(${HEADLESS[@]+"${HEADLESS[@]}"} "$CLI" drive eval ${DRIVE_TARGET[@]+"${DRIVE_TARGET[@]}"} \
    --timeout 600 "$PROBE_JS" 2>"$WORK/drive.err") \
    || { tail -20 "$WORK/drive.err" >&2; exit 1; }

# Through stdin, not argv: with --dump the reply carries whole PNGs, and a
# multi-megabyte argument is past ARG_MAX — which fails as an empty run rather
# than as an error.
printf '%s' "$OUT" | python3 "$REPO/Scripts/report-window-snapshot.py" ${DUMP:+--dump "$DUMP"}
