<#
.SYNOPSIS
  End-to-end check that an *app's own* `@MainActor` code runs on Windows (#216).

.DESCRIPTION
  Off Apple, `MainActor` is backed by libdispatch's main queue, and a
  `GetMessageW` pump drains nothing - so a bridge command that touched a
  `@MainActor` class never returned: no error, no timeout, nothing on stderr.
  CI builds the Windows target but never launches it, so this class of bug
  ships green. Run this after touching the message pump or PlatformMainQueue.

  It scaffolds a throwaway app against the checkout you point it at, registers
  four commands, and has the page invoke each one and report by *exit code* -
  the app is a console-less GUI process whose stdout goes nowhere, and the box
  may be locked, so neither a log nor a screenshot can be relied on.

    probe.nonisolated   control: must answer even on a broken build. Without
                        it, a hang anywhere upstream reads as "the fix failed".
    probe.actorMethod   a method on a `@MainActor final class`
    probe.mainActorRun  `await MainActor.run { ... }`
    probe.dispatchMain  `DispatchQueue.main.async`

  The app is launched through a scheduled task with /IT because an SSH session
  lands in Session 0, where `CreateCoreWebView2Controller` fails with
  0x80070578 (no window station).

.PARAMETER Repo
  Path to the swift-pwa checkout to build against. Default: this script's repo.

.PARAMETER Packages
  Directory holding the restored WebView2 + WIL NuGet packages. Default: the
  `packages` folder in -Repo (see docs/windows-setup.md to restore them).

.PARAMETER WorkDir
  Where the throwaway app is scaffolded. Wiped on each run.

.PARAMETER KeepWorkDir
  Leave the scaffolded app in place for debugging.

.EXAMPLE
  pwsh -File Scripts/verify-windows-main-actor.ps1 -Repo C:\src\swift-pwa
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Packages,
    [string]$WorkDir = "$env:TEMP\swift-pwa-main-actor-check",
    [switch]$KeepWorkDir
)

$ErrorActionPreference = "Stop"
if (-not $Repo) { $Repo = (Resolve-Path "$PSScriptRoot\..").Path }
if (-not $Packages) { $Packages = Join-Path $Repo "packages" }
$appName = "MainActorCheck"
$appDir = Join-Path $WorkDir $appName
$taskName = "swift-pwa-main-actor-check"

# Order matters: the exit code is 2 + the index of the first probe that did
# not answer, so a failure says which shape is broken.
$probes = @("probe.nonisolated", "probe.actorMethod", "probe.mainActorRun", "probe.dispatchMain")

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
import Dispatch
import Foundation
import SwiftPWA

/// The shape the reporting adopter's lock service had: app state behind the
/// main actor, reached from a bridge handler running on the cooperative pool.
@MainActor
final class ProbeService {
    private var touches = 0
    func touch() -> Int {
        touches += 1
        return touches
    }
}

struct ProbeArgs: Decodable, Sendable {}
struct ProbeResult: Encodable, Sendable {
    let value: Int
}

@MainActor let probeService = ProbeService()

@MainActor
func registerProbes(_ ctx: any AppContext) {
    // Control. Touches no actor, so it answers even on a broken build.
    ctx.registry.register("probe.nonisolated") { (_: ProbeArgs, _) async throws -> ProbeResult in
        ProbeResult(value: 1)
    }
    ctx.registry.register("probe.actorMethod") { (_: ProbeArgs, _) async throws -> ProbeResult in
        ProbeResult(value: await probeService.touch())
    }
    ctx.registry.register("probe.mainActorRun") { (_: ProbeArgs, _) async throws -> ProbeResult in
        await MainActor.run { ProbeResult(value: 2) }
    }
    ctx.registry.register("probe.dispatchMain") { (_: ProbeArgs, _) async throws -> ProbeResult in
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume(returning: ProbeResult(value: 3)) }
        }
    }
}
"@
}

function New-SelfTestPage {
    $list = ($probes | ForEach-Object { "'$_'" }) -join ", "
    @"
<!doctype html>
<meta charset="utf-8">
<title>main actor check</title>
<body style="font:14px system-ui;padding:24px">Checking the app's own main-actor code...</body>
<script>
// Reports by exit code: 0 = every probe answered, 2+i = probe i never did.
// Nothing here can print - a bundled app has no stdout and the box may be locked.
(function () {
  var probes = [$list];
  // A hang is the bug's signature, so the race IS the measurement: a working
  // command answers in single-digit milliseconds.
  function attempt(name) {
    return Promise.race([
      __SWIFT_PWA__.invoke(name, {}).then(function () { return null; },
                                          function (e) { return name + ' threw ' + e; }),
      new Promise(function (resolve) { setTimeout(function () { resolve(name + ' never answered'); }, 6000); })
    ]);
  }
  Promise.all(probes.map(attempt)).then(function (results) {
    var firstBad = results.findIndex(function (r) { return r !== null; });
    document.body.textContent = firstBad < 0 ? 'PASS' : results[firstBad];
    __SWIFT_PWA__.invoke('app.quit', { exitCode: firstBad < 0 ? 0 : 2 + firstBad });
  });
})();
</script>
"@
}

function Invoke-App([string]$RunnerCmd) {
    # Every schtasks call goes through cmd with its output swallowed there:
    # PowerShell turns a native command's *stderr* into a terminating error
    # under $ErrorActionPreference = "Stop", and deleting a task that doesn't
    # exist yet writes to stderr as a matter of course.
    cmd /c "schtasks /delete /tn $taskName /f >nul 2>&1"
    # /IT = run in the logged-on user's interactive session (Session 1+), which
    # is the only place a WebView2 controller can be created.
    cmd /c "schtasks /create /tn $taskName /tr `"$RunnerCmd`" /sc once /st 00:00 /it /f >nul 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "could not create the scheduled task (is a user logged on?)" }
    cmd /c "schtasks /run /tn $taskName >nul 2>&1"
    $deadline = (Get-Date).AddSeconds(120)
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

# Point the scaffold at this checkout.
$manifest = Join-Path $appDir "Package.swift"
$repoForSwift = $Repo.Replace('\', '/')
$repoLeaf = Split-Path $Repo -Leaf
Write-Utf8NoBom $manifest (([IO.File]::ReadAllText($manifest) `
    -replace '\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)', ".package(path: `"$repoForSwift`")") `
    -replace 'package: "swift-pwa"', "package: `"$repoLeaf`"")

Write-Utf8NoBom (Join-Path $appDir "Sources\$appName\Probe.swift") (New-ProbeSwift)

$appSwift = Join-Path $appDir "Sources\$appName\App.swift"
Write-Utf8NoBom $appSwift ([IO.File]::ReadAllText($appSwift) -replace `
    '(?m)^    _ = try ctx\.createWindow\(', `
    "    registerProbes(ctx)`r`n`r`n    _ = try ctx.createWindow(")

Write-Utf8NoBom (Join-Path $appDir "web\index.html") (New-SelfTestPage)

Push-Location $appDir
try {
    $cli = Join-Path $Repo ".build\debug\swift-pwa.exe"
    # --configuration debug so the build matches what a developer debugs.
    & $cli build --target windows --configuration debug | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "app build failed" }
} finally { Pop-Location }

$exeDir = Join-Path $appDir "build\windows\$appName"
$runner = Join-Path $WorkDir "run.cmd"
Write-Utf8NoBom $runner "@echo off`r`ncd /d `"$exeDir`"`r`n$appName.exe`r`n"
$code = Invoke-App $runner

if (-not $KeepWorkDir) { Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue }

if ($code -eq 0) {
    Write-Host "PASS - every probe answered, including the app's own main-actor code." -ForegroundColor Green
    exit 0
}
$which = $code - 2
if ($which -ge 0 -and $which -lt $probes.Count) {
    Write-Host "FAIL - $($probes[$which]) never answered." -ForegroundColor Red
} else {
    Write-Host "FAIL - the app exited $code before reporting." -ForegroundColor Red
}
exit 1
