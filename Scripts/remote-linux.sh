#!/usr/bin/env bash
#
# Build / test the Linux (GTK) backend on a remote Linux box.
#
# The GTK targets are `#if os(Linux)` and never compile on a macOS dev machine,
# and CI only *compiles* them (no GUI), so runtime checks need a real box with
# GTK + WebKitGTK. This script is the repeatable form of "rsync the tree over,
# build it, run the GUI-gated suite under Xvfb".
#
# The host is a flag or $SWIFT_PWA_LINUX_HOST — never baked in, so this file
# carries no infrastructure identifiers.
#
# Usage:
#   Scripts/remote-linux.sh --host <ssh-host> [--gtk4] [--toolchain <ver>] \
#                           [--clean] <command>
#
#   Commands:
#     sync         rsync the working tree to <host>:<remote-dir>
#     build        sync, then `swift build`
#     test         sync, build, then run the suite under Xvfb with
#                  SWIFT_PWA_LINUX_GUI=1
#     provision    build the libxml2 compat shim the test bundle needs on
#                  libxml2 >= 2.14 distros (see "libxml2" below). Idempotent.
#     shell        print the env-primed ssh command for interactive poking
#
#   Options:
#     --host <h>        ssh host/alias. Default: $SWIFT_PWA_LINUX_HOST
#     --gtk4            build the GTK4 + WebKitGTK 6.0 backend (SWIFT_PWA_GTK4=1).
#                       Omit for the default GTK3 + WebKitGTK 4.1 backend.
#     --toolchain <v>   run under `swiftly run +<v>` (e.g. 6.2.0). Default: the
#                       box's default toolchain. Pin this — mixing toolchains in
#                       one .build fails with "module compiled with Swift X
#                       cannot be imported by the Swift Y compiler".
#     --remote-dir <d>  remote checkout path. Default: ~/swift-pwa
#     --filter <f>      pass --filter to `swift test`. swift-testing matches the
#                       *type* name (GTKFullscreenStateTests), not the @Suite
#                       display name.
#     --with-vendor     also sync Vendor/ (~1 GB of Apple/Android/desktop ONNX
#                       and llama artifacts). Excluded by default: the Linux box
#                       resolves its own, and syncing them dominates the transfer.
#     --clean           rm -rf the remote .build first. Required after a C-shim
#                       *header* change — SwiftPM does not pick those up
#                       incrementally — and after a toolchain switch.
#
# libxml2 (why `provision` exists):
#   libxml2 2.14 bumped its SONAME to libxml2.so.16 and dropped the versioned
#   symbols (LIBXML2_2.4.30 &c.). The Swift toolchain's prebuilt
#   libFoundationXML.so still has a DT_NEEDED on libxml2.so.2 and imports those
#   versioned symbols, so on Ubuntu 25.10+ / any distro shipping libxml2 >= 2.14
#   *the whole test bundle fails to link* — two CLI test files import
#   FoundationXML. Product builds are unaffected; only `swift test` breaks.
#   Distros no longer ship a .so.2 compat package, and the archived one pulls in
#   ICU 74, which those distros also no longer have. So `provision` builds
#   libxml2 2.12 from source `--without-icu` into a user-local prefix — one
#   self-contained .so, no root, no ICU chain. `build`/`test` auto-detect it and
#   pass -rpath-link (link time) + LD_LIBRARY_PATH (run time).
#
# Examples:
#   Scripts/remote-linux.sh --host gtk4-box --gtk4 --toolchain 6.2.0 provision
#   Scripts/remote-linux.sh --host gtk4-box --gtk4 --toolchain 6.2.0 build
#   SWIFT_PWA_LINUX_HOST=gtk3-box Scripts/remote-linux.sh test --filter GTKFullscreenStateTests

set -euo pipefail

# 2.12 is the last series with the libxml2.so.2 SONAME and versioned symbols.
readonly XML_VERSION="2.12.9"
readonly XML_PREFIX='$HOME/Code-3p/libxml2-compat'

HOST="${SWIFT_PWA_LINUX_HOST:-}"
REMOTE_DIR="swift-pwa"
GTK4=0
TOOLCHAIN=""
FILTER=""
CLEAN=0
WITH_VENDOR=0
COMMAND=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --gtk4) GTK4=1; shift ;;
        --toolchain) TOOLCHAIN="$2"; shift 2 ;;
        --remote-dir) REMOTE_DIR="$2"; shift 2 ;;
        --filter) FILTER="$2"; shift 2 ;;
        --with-vendor) WITH_VENDOR=1; shift ;;
        --clean) CLEAN=1; shift ;;
        sync|build|test|provision|shell) COMMAND="$1"; shift ;;
        -h|--help) sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "remote-linux.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

if [[ -z "$HOST" ]]; then
    echo "remote-linux.sh: no host — pass --host or set SWIFT_PWA_LINUX_HOST" >&2
    exit 2
fi
if [[ -z "$COMMAND" ]]; then
    echo "remote-linux.sh: no command — one of sync, build, test, provision, shell" >&2
    exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# swiftly is not always on a non-interactive shell's PATH; adding both of its
# install locations is harmless when it already is.
REMOTE_ENV='export PATH="$HOME/.local/share/swiftly/bin:$HOME/.swiftly/bin:$PATH";'
if [[ "$GTK4" == "1" ]]; then
    REMOTE_ENV+=' export SWIFT_PWA_GTK4=1;'
fi

SWIFT="swift"
if [[ -n "$TOOLCHAIN" ]]; then
    SWIFT="swiftly run +$TOOLCHAIN swift"
fi

if [[ "$COMMAND" == "shell" ]]; then
    echo "ssh -t $HOST '$REMOTE_ENV cd ~/$REMOTE_DIR && exec bash -l'"
    exit 0
fi

if [[ "$COMMAND" == "provision" ]]; then
    echo "→ provisioning the libxml2 $XML_VERSION compat shim on $HOST"
    ssh "$HOST" "bash -s" <<PROVISION
set -euo pipefail
PREFIX="$XML_PREFIX"
if [[ -f "\$PREFIX/install/lib/libxml2.so.2" ]]; then
    echo "already provisioned: \$PREFIX/install/lib/libxml2.so.2"
    exit 0
fi
mkdir -p "\$PREFIX/src"
cd "\$PREFIX/src"
curl -sLO "https://download.gnome.org/sources/libxml2/${XML_VERSION%.*}/libxml2-$XML_VERSION.tar.xz"
tar xf "libxml2-$XML_VERSION.tar.xz"
cd "libxml2-$XML_VERSION"
# --without-icu is the point: the archived distro builds pull in an ICU major
# these distros no longer ship, which just moves the missing-symbol wall.
./configure --prefix="\$PREFIX/install" --without-icu --without-python \
            --without-lzma --disable-static >/dev/null
make -j"\$(nproc)" >/dev/null
make install >/dev/null
ls -la "\$PREFIX/install/lib/libxml2.so.2"
PROVISION
    exit 0
fi

echo "→ syncing to $HOST:~/$REMOTE_DIR"
# Build outputs and vendored binaries are excluded: `.build`, the per-example
# `build/` trees and `Vendor/` are together several GB, are regenerated or
# re-resolved on the box, and syncing them dominates the wall clock on a slow
# link. `--delete` leaves excluded paths alone on the receiver, so the box keeps
# its own.
RSYNC_EXCLUDES=(
    --exclude='.git'
    --exclude='.build'
    --exclude='build/'
    --exclude='.swiftpm'
    --exclude='*.xcframework'
)
if [[ "$WITH_VENDOR" == "0" ]]; then
    RSYNC_EXCLUDES+=(--exclude='Vendor/')
fi
rsync -az --delete "${RSYNC_EXCLUDES[@]}" "$REPO_ROOT/" "$HOST:$REMOTE_DIR/"

if [[ "$CLEAN" == "1" ]]; then
    echo "→ removing remote .build"
    ssh "$HOST" "rm -rf ~/$REMOTE_DIR/.build"
fi

[[ "$COMMAND" == "sync" ]] && exit 0

# Use the compat shim when it's been provisioned; stay out of the way when the
# box's own libxml2 is old enough not to need it.
XML_LIB="$XML_PREFIX/install/lib"
XML_ENV="if [ -f $XML_LIB/libxml2.so.2 ]; then export LD_LIBRARY_PATH=\"$XML_LIB\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\"; XMLFLAGS=\"-Xlinker -rpath-link -Xlinker $XML_LIB\"; else XMLFLAGS=\"\"; fi;"

echo "→ building on $HOST (gtk$([[ $GTK4 == 1 ]] && echo 4 || echo 3)${TOOLCHAIN:+, toolchain $TOOLCHAIN})"
BUILD_ARGS=""
[[ "$COMMAND" == "test" ]] && BUILD_ARGS="--build-tests"
ssh "$HOST" "$REMOTE_ENV $XML_ENV cd ~/$REMOTE_DIR && $SWIFT build $BUILD_ARGS \$XMLFLAGS"

[[ "$COMMAND" == "build" ]] && exit 0

# WebKitGTK needs software rendering under Xvfb — the box has no GPU compositor
# and no sandbox-capable session. These three are the known-good headless set.
# The `WEBKIT_IS_WEB_VIEW ... load_uri` CRITICAL lines they produce are harmless
# headless noise, not failures.
WEBKIT_ENV='export WEBKIT_DISABLE_COMPOSITING_MODE=1 WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1;'
echo "→ testing on $HOST under Xvfb"
# Delegate to ci-test-linux.sh rather than `swift test`. On Linux the test
# process intermittently crashes *at exit*, after every test has run, and that
# truncates swift-testing's block-buffered output — so `swift test` reports a
# fully passing run as `exited with unexpected signal code 6` with the passing
# tail missing. ci-test-linux.sh reads the verdict from the structured event
# stream instead of stdout, which is the only way to tell that apart from a
# real failure. It runs the already-built bundle directly, so the linker flags
# stay on the build step above (passing them here would forward them into the
# test binary's own argv).
#
# A suite name can contain spaces, so the filter has to survive a second round
# of word-splitting on the remote shell — quote it there, not just here.
REMOTE_FILTER=""
if [[ -n "$FILTER" ]]; then
    REMOTE_FILTER="$(printf '%q' "$FILTER")"
fi
ssh "$HOST" "$REMOTE_ENV $WEBKIT_ENV $XML_ENV export SWIFT_PWA_LINUX_GUI=1; cd ~/$REMOTE_DIR && xvfb-run -a bash Scripts/ci-test-linux.sh $REMOTE_FILTER"
