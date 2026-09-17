<#
.SYNOPSIS
  End-to-end check that `WindowEvent.didFocus` / `.didBlur` follow the OS on
  Windows (#214).

.DESCRIPTION
  `WM_SETFOCUS` reported `didFocus` and nothing reported the other direction,
  so an app could learn it had become active and never that it had stopped —
  which is the edge a lock re-engages on. `WM_KILLFOCUS` now reports `didBlur`.

  A compile proves nothing about whether a window message arrives, and CI
  builds the Windows target without ever launching it, so this class of bug
  ships green.

  The trigger is a **second window mapping**, not a `focus()` call: the
  assertion has to land on window A, which nothing called anything on, or a
  backend that merely echoes its own `focus()` would pass. Closing B then
  measures the return path rather than inferring it.

  Reported by **exit code**: the app is a console-less GUI process whose stdout
  goes nowhere, and it runs through a scheduled task in the interactive session
  (an SSH session lands in Session 0, where `CreateCoreWebView2Controller`
  fails with 0x80070578 - no window station). The code is a bitmask of what was
  observed, so a partial failure says which half is broken:

    1  B was created                 (control - separates "never got there"
                                      from "the events didn't arrive")
    2  A blurred when B mapped       (the discriminator - needs WM_KILLFOCUS)
    4  A focused again when B closed (the return path - needs WM_SETFOCUS, and
                                      proves A really is on screen)

  7 = everything. The app adds 100 so that "nothing observed" (0) can't be
  mistaken for success.

  Deliberately NOT checked: the *first* focus event of either window. On
  Windows a new window takes focus synchronously inside `createWindow`, so its
  `WM_SETFOCUS` has already been emitted by the time `eventStream()` is
  attached to the returned window - `AsyncStream` doesn't replay, so the first
  event is unobservable to any caller. (GTK doesn't race this: it maps
  asynchronously, once the main loop runs.) Checking it would have failed
  against correct behaviour, which is what the first run of this script did.

.PARAMETER Repo
  Path to the swift-pwa checkout to build against. Default: this script's repo.

.PARAMETER Packages
  Directory holding the restored WebView2 + WIL NuGet packages. Default: the
  `packages` folder in -Repo (see docs/windows-setup.md to restore them).

.EXAMPLE
  pwsh -File Scripts/verify-windows-window-focus.ps1 -Repo C:\src\swift-pwa
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Packages,
    [string]$WorkDir = "$env:TEMP\swift-pwa-focus-check",
    [switch]$KeepWorkDir
)

$ErrorActionPreference = "Stop"
if (-not $Repo) { $Repo = (Resolve-Path "$PSScriptRoot\..").Path }
if (-not $Packages) { $Packages = Join-Path $Repo "packages" }
$appName = "FocusCheck"
$appDir = Join-Path $WorkDir $appName
$taskName = "swift-pwa-focus-check"

function Enter-BuildEnv {
    $vcvars = Get-ChildItem "C:\Program Files*\Microsoft Visual Studio" -Recurse -Filter vcvars64.bat `
        -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if (-not $vcvars) { throw "vcvars64.bat not found - install VS Build Tools (docs/windows-setup.md section 2)." }
    # `cmd /c ... & set` is the only way to lift vcvars' environment into this
    # session; it edits dozens of variables and has no PowerShell equivalent.
    cmd /c "call `"$vcvars`" >nul 2>&1 & set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
    }
    $wv2 = Join-Path $Packages "Microsoft.Web.WebView2\build\native\include"
    $wil = Join-Path $Packages "Microsoft.Windows.ImplementationLibrary\include"
    if (-not (Test-Path $wv2)) { throw "WebView2 headers not at $wv2 - restore NuGet packages or pass -Packages." }
    # Flags, not $env:INCLUDE / $env:LIB: Swift 6.4's swiftbuild engine passes
    # neither to the tasks that need them, so a build that relies on the
    # environment fails as if the headers were never installed.
    $script:BuildFlags = @(
        "-Xcc", "-I$wv2",
        "-Xcc", "-I$wil",
        "-Xlinker", "/LIBPATH:$(Join-Path $Packages 'Microsoft.Web.WebView2\build\native\x64')"
    )
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    # Set-Content -Encoding UTF8 writes a BOM on Windows PowerShell, which
    # hides `// swift-tools-version:` from SwiftPM and breaks the manifest.
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-ProbeSwift {
    @"
import Foundation
import SwiftPWA

/// Records what the window events actually reported, as the bitmask the exit
/// code carries. Serialized onto the main actor, which is also where the
/// window events are emitted from.
@MainActor
final class FocusLedger {
    private var seen = 0
    private(set) var bMapped = false
    private(set) var bClosed = false

    func note(_ bit: Int) { seen |= bit }
    /// Set *before* B is created, not after: on Windows the new window takes
    /// focus synchronously inside `createWindow`, so A's WM_KILLFOCUS has
    /// already been delivered by the time that call returns.
    func expectBlur() { bMapped = true }
    func markBCreated() { seen |= 1 }
    func markBClosed() { bClosed = true }
    var value: Int { seen }
}

@MainActor let ledger = FocusLedger()

@MainActor
func watchA(_ window: any Window) {
    let events = window.eventStream()
    Task.detached {
        for await event in events {
            await MainActor.run {
                switch event {
                case .didFocus:
                    // Only after B has gone: A's own first focus happens inside
                    // `createWindow`, before anything can subscribe.
                    if ledger.bClosed { ledger.note(4) }
                case .didBlur:
                    // Only once B has mapped - that is the transition nothing
                    // in this app asked for.
                    if ledger.bMapped { ledger.note(2) }
                default: break
                }
            }
        }
    }
}

@MainActor
func runFocusProbe(_ ctx: any AppContext, first: any Window) {
    watchA(first)
    Task.detached {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        await MainActor.run {
            ledger.expectBlur()
            guard let b = try? ctx.createWindow(WindowConfig(
                title: "FocusCheckB", size: Size(width: 500, height: 360),
                content: .remote(URL(string: "about:blank")!)
            )) else { return }
            ledger.markBCreated()
            Task.detached {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run {
                    ledger.markBClosed()
                    b.close()
                }
            }
        }
        try? await Task.sleep(nanoseconds: 12_000_000_000)
        await MainActor.run { ctx.quit(exitCode: Int32(100 + ledger.value)) }
    }
}
"@
}

function Invoke-App([string]$RunnerCmd) {
    # Every schtasks call goes through cmd with its output swallowed there:
    # PowerShell turns a native command's *stderr* into a terminating error
    # under $ErrorActionPreference = "Stop", and deleting a task that doesn't
    # exist yet writes to stderr as a matter of course.
    cmd /c "schtasks /delete /tn $taskName /f >nul 2>&1"
    # /IT = run in the logged-on user's interactive session (Session 1+), which
    # is the only place a WebView2 controller can be created - and the only
    # place a window can take focus at all.
    cmd /c "schtasks /create /tn $taskName /tr `"$RunnerCmd`" /sc once /st 00:00 /it /f >nul 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "could not create the scheduled task (is a user logged on?)" }
    cmd /c "schtasks /run /tn $taskName >nul 2>&1"
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $status = (schtasks /query /tn $taskName /fo list /v | Select-String '^Status:').ToString()
        if ($status -match 'Ready') { break }
    }
    $line = (schtasks /query /tn $taskName /fo list /v | Select-String '^Last Result:').ToString()
    cmd /c "schtasks /delete /tn $taskName /f >nul 2>&1"
    if ($line -match '(-?\d+)\s*$') { return [int]$matches[1] }
    throw "could not read the task's exit code"
}

Enter-BuildEnv
if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
New-Item -ItemType Directory -Path $WorkDir | Out-Null

Write-Host "Building the CLI in $Repo..." -ForegroundColor Cyan
Push-Location $Repo
try {
    swift build --product swift-pwa @BuildFlags | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "CLI build failed" }
} finally { Pop-Location }

Push-Location $WorkDir
try {
    & (Join-Path $Repo ".build\debug\swift-pwa.exe") init $appName | Out-Null
} finally { Pop-Location }

$manifest = Join-Path $appDir "Package.swift"
$repoForSwift = $Repo.Replace('\', '/')
$repoLeaf = Split-Path $Repo -Leaf
Write-Utf8NoBom $manifest (([IO.File]::ReadAllText($manifest) `
    -replace '\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)', ".package(path: `"$repoForSwift`")") `
    -replace 'package: "swift-pwa"', "package: `"$repoLeaf`"")

Write-Utf8NoBom (Join-Path $appDir "Sources\$appName\Probe.swift") (New-ProbeSwift)

# Keep the scaffold's window as A, and hand it to the probe.
$appSwift = Join-Path $appDir "Sources\$appName\App.swift"
$text = [IO.File]::ReadAllText($appSwift) -replace `
    '(?m)^    _ = try ctx\.createWindow\(', "    let focusProbeWindow = try ctx.createWindow("
$closing = $text.TrimEnd().LastIndexOf("`n}")
if ($closing -lt 0) { throw "could not find the end of configure() in the scaffold" }
$text = $text.TrimEnd().Substring(0, $closing) + "`r`n    runFocusProbe(ctx, first: focusProbeWindow)" + `
    $text.TrimEnd().Substring($closing) + "`r`n"
Write-Utf8NoBom $appSwift $text

Push-Location $appDir
try {
    $cli = Join-Path $Repo ".build\debug\swift-pwa.exe"
    & $cli build --target windows --configuration debug | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "app build failed" }
} finally { Pop-Location }

$exeDir = Join-Path $appDir "build\windows\$appName"
$runner = Join-Path $WorkDir "run.cmd"
Write-Utf8NoBom $runner "@echo off`r`ncd /d `"$exeDir`"`r`n$appName.exe`r`n"
$code = Invoke-App $runner

if (-not $KeepWorkDir) { Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue }

if ($code -lt 100) {
    Write-Host "FAIL - the app exited $code before reporting (it never reached the probe)." -ForegroundColor Red
    exit 1
}
$mask = $code - 100
$checks = @(
    @{ Bit = 1; Label = "a second window was created (control)" },
    @{ Bit = 2; Label = "mapping B reports didBlur on A, which nothing asked for" },
    @{ Bit = 4; Label = "closing B hands focus back to A, so A is really on screen" }
)
$failed = $false
foreach ($c in $checks) {
    if ($mask -band $c.Bit) {
        Write-Host "PASS  $($c.Label)" -ForegroundColor Green
    } else {
        Write-Host "FAIL  $($c.Label)" -ForegroundColor Red
        $failed = $true
    }
}
if ($failed) { exit 1 }
Write-Host "`nOS-driven focus changes reach WindowEvent on Windows." -ForegroundColor Green
exit 0
