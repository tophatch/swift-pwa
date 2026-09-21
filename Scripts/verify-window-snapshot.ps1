<#
.SYNOPSIS
    `window.snapshot` on Windows: does the page get a picture of itself (#255)?

.DESCRIPTION
    The Windows half of Scripts/verify-window-snapshot.sh — the same probe page
    and the same evaluated expression, from Scripts\snapshot-probe\, and the
    same reporter, so the two can't drift into checking different things.

    The instrument is what to distrust: a snapshot that comes back blank, black
    or the wrong size still decodes, still draws and still reports a plausible
    width. So the page paints a known colour with a known rectangle in it and
    reads the pixels back out of the returned image, then times the round trip
    over three kinds of content — flat, body text and `crypto.getRandomValues`
    noise — because what a snapshot costs is almost entirely how well the
    picture compresses.

    **Session 0.** Windows OpenSSH puts your shell in the non-interactive
    services session, where WebView2 refuses to create a controller
    (`CreateCoreWebView2Controller failed: 0x80070578`). The app starts and the
    driver attaches, but there is no desktop to put a window on — and a window
    with no size is exactly the case this script would otherwise report as a
    backend fault. So in session 0 it launches the app into the active console
    session with a scheduled task and attaches over loopback, which crosses the
    session boundary fine.

.PARAMETER AppDir
    Where to build the probe app. Defaults to a temp directory.

.PARAMETER PackagesDir
    The `packages\` folder holding the WebView2 and WIL NuGet packages.
    Defaults to `<repo>\packages`. The probe app builds `CWebView2Shim` like
    any Windows app, and since Swift 6.4's `swiftbuild` engine stopped
    forwarding `INCLUDE` / `LIB` those headers have to arrive as flags — the
    failure is `'wil/com.h' file not found` from a compile line that mentions
    nothing about NuGet.

.PARAMETER Dump
    Also write each variant's PNG to this directory, to look at by eye.

.PARAMETER Keep
    Don't delete the probe app afterwards.
#>
[CmdletBinding()]
param(
    [string]$AppDir = "",
    [string]$PackagesDir = "",
    [string]$Dump = "",
    [switch]$Keep
)

$ErrorActionPreference = "Continue"
# The reporter prints em dashes; without this the Windows console renders them
# as `?` and the output reads like corruption.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$repo = Split-Path -Parent $PSScriptRoot

$cleanupApp = $false
if (-not $AppDir) {
    $AppDir = Join-Path ([System.IO.Path]::GetTempPath()) "SnapshotProbe"
    if (-not $Keep) { $cleanupApp = $true }
}
$cli = Join-Path $repo ".build\debug\swift-pwa.exe"

if (-not $PackagesDir) { $PackagesDir = Join-Path $repo "packages" }
$wv2 = Join-Path $PackagesDir "Microsoft.Web.WebView2\build\native"
$wil = Join-Path $PackagesDir "Microsoft.Windows.ImplementationLibrary\include"
$sdkArgs = @()
if ((Test-Path (Join-Path $wv2 "include\WebView2.h")) -and (Test-Path (Join-Path $wil "wil\com.h"))) {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    $sdkArgs = @(
        "-Xcc", "-I$(Join-Path $wv2 'include')",
        "-Xcc", "-I$wil",
        "-Xlinker", "/LIBPATH:$(Join-Path $wv2 $arch)"
    )
} else {
    Write-Output "note: no WebView2/WIL packages under $PackagesDir - if the app fails to build with"
    Write-Output "      'wil/com.h' file not found, point -PackagesDir at them (see docs/windows-setup.md)."
}

Write-Output "== building the CLI =="
Push-Location $repo
swift build --product swift-pwa 2>&1 | Out-Null
Pop-Location
if (-not (Test-Path $cli)) { Write-Error "couldn't build swift-pwa.exe"; exit 1 }

if (-not (Test-Path $AppDir)) {
    Write-Output "== scaffolding a probe app in $AppDir =="
    $parent = Split-Path -Parent $AppDir
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Push-Location $parent
    & $cli init (Split-Path -Leaf $AppDir) | Out-Null
    Pop-Location
}

# `swift-pwa init` pins the app to the last *released* package, so an app
# scaffolded here would exercise the shipped backend and quietly ignore every
# local change.
$manifest = Join-Path $AppDir "Package.swift"
$source = Get-Content $manifest -Raw
$escaped = $repo -replace '\\', '\\'
$patched = [regex]::Replace($source, '\.package\(url: "[^"]*swift-pwa"[^)]*\)', ".package(path: `"$escaped`")")
# SwiftPM names a path dependency after its *directory*, so a checkout that
# isn't called `swift-pwa` — which is how this lands on a box that already has
# one — leaves the target depending on a package name that no longer exists.
$repoLeaf = Split-Path -Leaf $repo
$patched = $patched -replace 'package: "swift-pwa"', "package: `"$repoLeaf`""
if ($patched -ne $source) {
    Set-Content -Path $manifest -Value $patched
    Write-Output "    repointed Package.swift at the working tree"
}

Copy-Item (Join-Path $repo "Scripts\snapshot-probe\index.html") (Join-Path $AppDir "web\index.html") -Force

Write-Output "== building the app =="
Push-Location $AppDir
swift build @sdkArgs 2>&1 | Out-Null
$built = $LASTEXITCODE
if ($built -ne 0) {
    Write-Output "-- the app's build output --"
    swift build @sdkArgs 2>&1 | Select-Object -Last 12
}
Pop-Location
if ($built -ne 0) { Write-Error "the probe app didn't build"; exit 1 }

$binary = Get-ChildItem (Join-Path $AppDir ".build") -Recurse -Filter "$(Split-Path -Leaf $AppDir).exe" |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $binary) { Write-Error "couldn't find the built probe binary"; exit 1 }

# --- Launch -----------------------------------------------------------------
$log = Join-Path ([System.IO.Path]::GetTempPath()) "snapshot-probe.log"
Remove-Item $log -ErrorAction SilentlyContinue
$sessionId = (Get-Process -Id $PID).SessionId
$taskName = "SwiftPWASnapshotProbe"

if ($sessionId -eq 0) {
    Write-Output "== session 0: launching the app on the interactive desktop via a scheduled task =="
    $launcher = Join-Path ([System.IO.Path]::GetTempPath()) "snapshot-launch.bat"
    @"
@echo off
set SWIFT_PWA_DRIVE=0
set SWIFT_PWA_WEB_ROOT=$AppDir\web
"$binary" > "$log" 2>&1
"@ | Set-Content -Path $launcher -Encoding ASCII
    schtasks /create /tn $taskName /tr "`"$launcher`"" /sc once /st 23:59 /f /it /ru $env:USERNAME | Out-Null
    schtasks /run /tn $taskName | Out-Null
} else {
    $env:SWIFT_PWA_DRIVE = "0"
    $env:SWIFT_PWA_WEB_ROOT = (Join-Path $AppDir "web")
    Start-Process -FilePath $binary -RedirectStandardOutput $log -NoNewWindow
}

$port = $null; $token = $null
foreach ($_ in 1..120) {
    if (Test-Path $log) {
        $line = Select-String -Path $log -Pattern "driver listening" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($line) {
            if ($line.Line -match "port=(\d+)") { $port = $Matches[1] }
            if ($line.Line -match "token=([0-9a-f]+)") { $token = $Matches[1] }
            break
        }
    }
    Start-Sleep -Milliseconds 500
}

function Stop-Probe {
    Get-Process -Name (Split-Path -Leaf $binary).Replace(".exe", "") -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    if ($sessionId -eq 0) { schtasks /delete /tn $taskName /f 2>&1 | Out-Null }
    if ($cleanupApp) { Remove-Item $AppDir -Recurse -Force -ErrorAction SilentlyContinue }
}

if (-not $port -or -not $token) {
    Write-Output "::error::the app never printed its driver port"
    if (Test-Path $log) { Get-Content $log | Select-Object -First 20 }
    Stop-Probe
    exit 1
}

# --- Drive ------------------------------------------------------------------
$probeJs = Get-Content (Join-Path $repo "Scripts\snapshot-probe\probe.js") -Raw
$probeJs = $probeJs -replace "__DUMP__", $(if ($Dump) { "true" } else { "false" })

Write-Output ""
Write-Output "== driving on windows (port $port) =="
$out = & $cli drive eval --attach $port --token $token --timeout 600 $probeJs 2>$null

# Through a file, not an argument: with -Dump the reply carries whole PNGs and
# a multi-megabyte command line is past what the shell will pass.
$replyFile = Join-Path ([System.IO.Path]::GetTempPath()) "snapshot-reply.json"
Set-Content -Path $replyFile -Value ($out -join "`n") -Encoding UTF8

$reportArgs = @((Join-Path $repo "Scripts\report-window-snapshot.py"))
if ($Dump) {
    New-Item -ItemType Directory -Force -Path $Dump | Out-Null
    $reportArgs += @("--dump", $Dump)
}
Get-Content $replyFile -Raw | & python @reportArgs
$status = $LASTEXITCODE

Remove-Item $replyFile -ErrorAction SilentlyContinue
Stop-Probe
exit $status
