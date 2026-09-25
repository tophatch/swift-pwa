#!/usr/bin/env bash
#
# Build / run the Windows backend on a remote Windows box over SSH.
#
# The Windows targets never compile on a macOS dev machine, and CI can build
# them but has no desktop to run an app on, so runtime checks need a real box.
# This is the repeatable form of "tar the tree over, load the MSVC dev
# environment, build with the WebView2 / WIL headers passed as flags, run it".
# Each step of that has a trap of its own (see docs/windows-setup.md):
#
#   - macOS `tar` adds AppleDouble `._*` sidecars that clang then reads as
#     sources ("source file is not valid UTF-8"). COPYFILE_DISABLE stops it.
#   - A bare SSH shell has no MSVC environment, and `swift build` dies at
#     `'errno.h' file not found`. vcvars is loaded into the session first.
#   - Since Swift 6.4 `INCLUDE` / `LIB` no longer reach the compile, so the
#     NuGet headers go in as `-Xcc -I` / `-Xlinker /LIBPATH:` (#219).
#   - cmd's quoting over ssh mangles paths with spaces, so every remote step
#     runs from a generated .ps1, never a one-liner.
#
# The host is a flag or $SWIFT_PWA_WINDOWS_HOST — never baked in, so this file
# carries no infrastructure identifiers.
#
# Usage:
#   Scripts/remote-windows.sh --host <ssh-host> [options] <command> [-- <args>]
#
#   Commands:
#     sync         copy the working tree to <host>:<remote-dir>
#     build        sync, then `swift build` (extra args after `--`)
#     runner       sync, then `swift run SwiftPWAWindowsTestRunner` — the
#                  Windows stand-in for `swift test`, which finds no tests there
#     run          sync, then run the PowerShell after `--` inside the checkout
#                  with the dev environment loaded and $SwiftFlags set, e.g.
#                    run -- 'swift build @SwiftFlags --product swift-pwa'
#
#   Options:
#     --host <h>          ssh host/alias. Default: $SWIFT_PWA_WINDOWS_HOST
#     --remote-dir <d>    checkout path under the remote user's profile.
#                         Default: swift-pwa-remote — deliberately not the
#                         box's own git checkout, which this would overwrite.
#     --packages-from <d> a `packages\` dir on the box holding the WebView2 and
#                         WIL NuGet packages, copied into the checkout once.
#                         Default: the first of ~\swift-pwa\packages and
#                         ~\Code\swift-pwa\packages that exists.
#     -c <config>         debug (default) or release
#     --clean             delete the remote .build first. Required after a
#                         C-shim *header* change — SwiftPM does not pick those
#                         up incrementally.
#
# Examples:
#   Scripts/remote-windows.sh --host win-x64 runner
#   Scripts/remote-windows.sh --host win-arm64 build -- --product swift-pwa
#   SWIFT_PWA_WINDOWS_HOST=win-x64 Scripts/remote-windows.sh run -- 'swift --version'

set -euo pipefail

HOST="${SWIFT_PWA_WINDOWS_HOST:-}"
REMOTE_DIR="swift-pwa-remote"
PACKAGES_FROM=""
CONFIG="debug"
CLEAN=0
COMMAND=""
EXTRA=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --remote-dir) REMOTE_DIR="$2"; shift 2 ;;
        --packages-from) PACKAGES_FROM="$2"; shift 2 ;;
        -c) CONFIG="$2"; shift 2 ;;
        --clean) CLEAN=1; shift ;;
        sync|build|runner|run) COMMAND="$1"; shift ;;
        --) shift; EXTRA=("$@"); break ;;
        -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "remote-windows.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

if [[ -z "$HOST" ]]; then
    echo "remote-windows.sh: no host — pass --host or set SWIFT_PWA_WINDOWS_HOST" >&2
    exit 2
fi
if [[ -z "$COMMAND" ]]; then
    echo "remote-windows.sh: no command — one of sync, build, runner, run" >&2
    exit 2
fi
if [[ "$COMMAND" == "run" && ${#EXTRA[@]} -eq 0 ]]; then
    echo "remote-windows.sh: run needs a PowerShell command after --" >&2
    exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ packing the working tree"
# `.build`, the per-example `build/` trees and `Vendor/`'s binaries are several
# GB between them and are rebuilt or re-resolved on the box. The committed
# `Vendor/*-headers/` dirs must travel: Package.swift fails to *load* without
# them. bsdtar reads the first matching pattern, so the header dirs are named
# by adding them after the exclude-everything-in-Vendor pass.
(
    cd "$REPO_ROOT"
    COPYFILE_DISABLE=1 tar -czf "$WORK/tree.tgz" \
        --exclude='./.git' --exclude='*.build' --exclude='./.swiftpm' \
        --exclude='./Examples/*/build' --exclude='./Examples/CritterFacts' \
        --exclude='*.xcframework' --exclude='._*' --exclude='./Vendor' \
        --exclude='./packages' \
        .
    # Append the header dirs on their own; they're small and always needed.
    if compgen -G "Vendor/*-headers" >/dev/null; then
        COPYFILE_DISABLE=1 tar -czf "$WORK/headers.tgz" --exclude='._*' Vendor/*-headers
    fi
)

# PowerShell single-quoted strings escape a quote by doubling it.
ps_quote() { printf "'%s'" "${1//\'/\'\'}"; }

case "$COMMAND" in
    sync) ACTION="" ;;
    build) ACTION="swift build -c $CONFIG @SwiftFlags ${EXTRA[*]:-}" ;;
    runner) ACTION="swift run -c $CONFIG @SwiftFlags SwiftPWAWindowsTestRunner" ;;
    run) ACTION="${EXTRA[*]}" ;;
esac

# Windows PowerShell 5.1 reads a script without a BOM as the ANSI code page,
# and a single em dash then fails the parse several lines later.
printf '\xEF\xBB\xBF' >"$WORK/remote.ps1"
cat >>"$WORK/remote.ps1" <<PS1
\$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
\$root = Join-Path \$HOME $(ps_quote "$REMOTE_DIR")
New-Item -ItemType Directory -Force \$root | Out-Null
if ($([[ $CLEAN == 1 ]] && echo '$true' || echo '$false')) {
    Write-Output "→ removing .build"
    Remove-Item -Recurse -Force (Join-Path \$root '.build') -ErrorAction SilentlyContinue
}
# Extract over the previous sync so .build stays warm. A file deleted locally
# survives here until --clean; that has never mattered for a build.
tar -xzf (Join-Path \$HOME 'swift-pwa-remote-tree.tgz') -C \$root
if (Test-Path (Join-Path \$HOME 'swift-pwa-remote-headers.tgz')) {
    tar -xzf (Join-Path \$HOME 'swift-pwa-remote-headers.tgz') -C \$root
}
Get-ChildItem \$root -Recurse -Force -Filter '._*' -ErrorAction SilentlyContinue | Remove-Item -Force

\$packages = Join-Path \$root 'packages'
if (-not (Test-Path (Join-Path \$packages 'Microsoft.Web.WebView2'))) {
    \$from = $(ps_quote "$PACKAGES_FROM")
    if (-not \$from) {
        \$from = @((Join-Path \$HOME 'swift-pwa\packages'), (Join-Path \$HOME 'Code\swift-pwa\packages')) |
            Where-Object { Test-Path (Join-Path \$_ 'Microsoft.Web.WebView2') } | Select-Object -First 1
    }
    if (-not \$from) { throw "no WebView2/WIL packages found on this box — pass --packages-from" }
    Write-Output "→ copying NuGet packages from \$from"
    Copy-Item -Recurse -Force \$from \$packages
}

\$arch = if (\$env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
if ($(ps_quote "$ACTION") -ne '') {
    # vswhere needs -products * to see a BuildTools-only install.
    \$vswhere = "\${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    \$vs = if (Test-Path \$vswhere) { & \$vswhere -latest -products * -property installationPath } else { \$null }
    \$vcvars = if (\$vs) { Join-Path \$vs "VC\Auxiliary\Build\vcvars\$(if (\$arch -eq 'arm64') { 'arm64' } else { '64' }).bat" }
    if (-not \$vcvars -or -not (Test-Path \$vcvars)) {
        \$vcvars = Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio' -Recurse -ErrorAction SilentlyContinue \`
            -Filter "vcvars\$(if (\$arch -eq 'arm64') { 'arm64' } else { '64' }).bat" |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not \$vcvars) { throw "no vcvars batch file found — is Visual Studio installed?" }
    cmd /c "call \`"\$vcvars\`" >nul 2>&1 & set" | ForEach-Object {
        if (\$_ -match '^([^=]+)=(.*)\$') { Set-Item -Path "env:\$(\$matches[1])" -Value \$matches[2] }
    }
    \$SwiftFlags = @(
        '-Xcc', "-I\$packages\Microsoft.Web.WebView2\build\native\include",
        '-Xcc', "-I\$packages\Microsoft.Windows.ImplementationLibrary\include",
        '-Xlinker', "/LIBPATH:\$packages\Microsoft.Web.WebView2\build\native\\\$arch"
    )
    Set-Location \$root
    Write-Output ("→ " + (& swift --version 2>&1 | Select-Object -First 1) + " (\$arch)")
    \$ErrorActionPreference = 'Continue'
    # PowerShell wraps each native stderr line in an ErrorRecord, and prints
    # an empty one as "System.Management.Automation.RemoteException". The
    # original line is its TargetObject.
    & { $ACTION } 2>&1 | ForEach-Object {
        if (\$_ -is [System.Management.Automation.ErrorRecord]) { "\$(\$_.TargetObject)" } else { "\$_" }
    }
    exit \$LASTEXITCODE
}
PS1

echo "→ copying to $HOST"
scp -q "$WORK/tree.tgz" "$HOST:swift-pwa-remote-tree.tgz"
[[ -f "$WORK/headers.tgz" ]] && scp -q "$WORK/headers.tgz" "$HOST:swift-pwa-remote-headers.tgz"
scp -q "$WORK/remote.ps1" "$HOST:swift-pwa-remote.ps1"

[[ -n "$ACTION" ]] && echo "→ $COMMAND on $HOST: $ACTION"
ssh "$HOST" 'powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\swift-pwa-remote.ps1"'
