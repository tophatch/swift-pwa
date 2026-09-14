<#
.SYNOPSIS
  End-to-end check that a Windows build can tell the app's own page from a
  frame it embeds - `CommandContext.frame` (#204).

.DESCRIPTION
  bridge.js is injected with `AddScriptToExecuteOnDocumentCreated`, which runs
  in every frame, so an `<iframe>` of embedded content can invoke commands
  exactly as the app's own page does. WebView2 raises those messages on the
  frame's own `ICoreWebView2Frame2::WebMessageReceived` rather than the
  top-level event, so which event fired is the answer - and it is structural,
  unlike `get_Source`, which reports an identical URI for an iframe loaded from
  its parent's own URL.

  Windows answers that structurally rather than by comparing URIs, which it
  could not do: `get_Source` reports an identical URI for an iframe loaded from
  its parent's own URL. Embedded frames are then refused - with a diagnostic,
  because WebView2 drops an unsubscribed frame's message in total silence.

  This script scaffolds a throwaway app whose `probe.record` handler writes the
  `ctx.frame` it saw to a log, embeds frames that each call it, and checks both
  the log and the app's diagnostics. The cases cover a same-origin child at a
  different path, a same-origin child at the *same* URL as its parent, an
  `about:srcdoc` frame, and two further nesting levels - `FrameCreated` on the
  webview reports only first-level frames, so a nested frame is reached through
  its own parent's.

  Nothing here can be checked from the page: an embedded frame's reply never
  reaches it (`deliver` evaluates into the main frame), so the app's own log is
  the only observer. The app is launched through a scheduled task with /IT
  because an SSH session lands in Session 0, where a WebView2 controller can't
  be created.

.PARAMETER Repo
  Path to the swift-pwa checkout to build against. Default: this script's repo.

.PARAMETER Packages
  Directory holding the restored WebView2 + WIL NuGet packages.

.PARAMETER WorkDir
  Where the throwaway app is scaffolded. Wiped on each run.

.PARAMETER KeepWorkDir
  Leave the scaffolded app and its log in place for debugging.

.EXAMPLE
  pwsh -File Scripts/verify-windows-frame-identity.ps1 -Repo C:\src\swift-pwa
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Packages,
    [string]$WorkDir = "$env:TEMP\swift-pwa-frame-check",
    [switch]$KeepWorkDir
)

$ErrorActionPreference = "Stop"
if (-not $Repo) { $Repo = (Resolve-Path "$PSScriptRoot\..").Path }
if (-not $Packages) { $Packages = Join-Path $Repo "packages" }
$appName = "FrameCheck"
$appDir = Join-Path $WorkDir $appName
$logDir = Join-Path $WorkDir "frames"
$taskName = "swift-pwa-frame-check"

# The window's own document reaches the app's commands and is reported as the
# main frame. Everything it embeds is refused, at every nesting depth - a
# refusal the app has to be *told* about, since WebView2 would otherwise drop
# the message with nothing anywhere to explain it.
$mustReach = "main"
# label -> the document URI the refusal must name. A refusal can only be
# reported for a frame that actually loaded, ran bridge.js and called, so these
# are what separate "refused" from "never happened" - and `child-same` shares
# its parent's URI exactly, which is why a refusal naming it can only have come
# from the frame.
$mustBeRefused = [ordered]@{
    "child-path"       = "child.html?label=child-path"
    "child-same"       = "/index.html"
    "srcdoc"           = "about:srcdoc"
    "grandchild"       = "child.html?label=grandchild"
    "great-grandchild" = "child.html?label=great-grandchild"
}

function Enter-BuildEnv {
    $vcvars = Get-ChildItem "C:\Program Files*\Microsoft Visual Studio" -Recurse -Filter vcvars64.bat `
        -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if (-not $vcvars) { throw "vcvars64.bat not found - install VS Build Tools (docs/windows-setup.md section 2)." }
    cmd /c "call `"$vcvars`" >nul 2>&1 & set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
    }
    # The two NuGet packages don't have to sit in the same place - a box that
    # restored them at different times can have WebView2 inside the checkout
    # and WIL in the profile - so each is resolved on its own.
    $roots = @($Packages, (Join-Path $env:USERPROFILE "packages")) | Where-Object { Test-Path $_ }
    function Resolve-PackageDir([string]$Relative, [string]$What) {
        foreach ($root in $roots) {
            $candidate = Join-Path $root $Relative
            if (Test-Path $candidate) { return $candidate }
        }
        throw "$What not found under: $($roots -join ', ') - restore the NuGet packages (docs/windows-setup.md) or pass -Packages."
    }
    $wv2 = Resolve-PackageDir "Microsoft.Web.WebView2\build\native\include" "WebView2 headers"
    $wil = Resolve-PackageDir "Microsoft.Windows.ImplementationLibrary\include" "WIL headers"
    $wv2lib = Resolve-PackageDir "Microsoft.Web.WebView2\build\native\x64" "WebView2 import library"
    $env:INCLUDE = "$wv2;$wil;$env:INCLUDE"
    $env:LIB = "$wv2lib;$env:LIB"
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-App([string]$RunnerCmd) {
    cmd /c "schtasks /delete /tn $taskName /f >nul 2>&1"
    cmd /c "schtasks /create /tn $taskName /tr `"$RunnerCmd`" /sc once /st 00:00 /it /f >nul 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "could not create the scheduled task (is a user logged on?)" }
    cmd /c "schtasks /run /tn $taskName >nul 2>&1"
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $status = (schtasks /query /tn $taskName /fo list /v | Select-String '^Status:').ToString()
        if ($status -match 'Ready') { break }
    }
    cmd /c "schtasks /delete /tn $taskName /f >nul 2>&1"
}

Enter-BuildEnv
if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
New-Item -ItemType Directory -Path $WorkDir | Out-Null

Write-Host "Building the CLI in $Repo..." -ForegroundColor Cyan
Push-Location $Repo
try {
    swift build --product swift-pwa | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "CLI build failed" }
} finally { Pop-Location }

Push-Location $WorkDir
try { & (Join-Path $Repo ".build\debug\swift-pwa.exe") init $appName | Out-Null } finally { Pop-Location }

# Point the scaffold at this checkout rather than the published release.
$manifest = Join-Path $appDir "Package.swift"
$repoForSwift = $Repo.Replace('\', '/')
$repoLeaf = Split-Path $Repo -Leaf
Write-Utf8NoBom $manifest (([IO.File]::ReadAllText($manifest) `
    -replace '\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)', ".package(path: `"$repoForSwift`")") `
    -replace 'package: "swift-pwa"', "package: `"$repoLeaf`"")

# The handler writes what it saw, because only the app can see it: a frame's
# reply is evaluated into the main frame, so an embedded caller reads nothing
# back and cannot report on itself.
$logForSwift = $logDir.Replace('\', '\\')
$probeSwift = @"
    struct ProbeArgs: Codable, Sendable { let label: String }
    struct ProbeResult: Codable, Sendable { let ok: Bool }
    ctx.registry.register("probe.record", typed: { (args: ProbeArgs, cmd) -> ProbeResult in
        let seen: String
        switch cmd.frame {
        case .main: seen = "main"
        case let .subframe(origin):
            if let o = origin { seen = "subframe(\(o.scheme)://\(o.host))" } else { seen = "subframe(nil)" }
        case .unknown: seen = "unknown"
        }
        // One file per record. `invoke` dispatches concurrently, so several
        // frames posting at once would race an append and silently lose one -
        // which is exactly what happened, and looked like a frame that never
        // reached the bridge.
        let line = args.label + " " + seen
        let url = URL(fileURLWithPath: "$logForSwift")
            .appendingPathComponent(UUID().uuidString + ".txt")
        try? Data(line.utf8).write(to: url)
        return ProbeResult(ok: true)
    })

"@

$appSwift = Join-Path $appDir "Sources\$appName\App.swift"
Write-Utf8NoBom $appSwift ([IO.File]::ReadAllText($appSwift) -replace `
    '(?m)^    _ = try ctx\.createWindow\(', ($probeSwift + "    _ = try ctx.createWindow("))

# One document serves every nesting level: each copy calls the command and,
# until the deepest level, embeds another. Two levels below the top prove the
# subscription is genuinely recursive rather than one extra level deep.
Write-Utf8NoBom (Join-Path $appDir "web\child.html") @"
<!doctype html><meta charset="utf-8"><title>child</title>
<script>
  var params = new URLSearchParams(location.search);
  var depth = parseInt(params.get('depth') || '1', 10);
  __SWIFT_PWA__.invoke('probe.record', { label: params.get('label') || 'child-path' });
  var next = { 1: 'grandchild', 2: 'great-grandchild' }[depth];
  if (next) {
    document.addEventListener('DOMContentLoaded', function () {
      var f = document.createElement('iframe');
      f.src = '/child.html?label=' + next + '&depth=' + (depth + 1);
      document.body.appendChild(f);
    });
  }
</script>
<body></body>
"@

# The main document embeds itself once, which is the case `get_Source` can't
# answer: the child's document URI is identical to its parent's.
Write-Utf8NoBom (Join-Path $appDir "web\index.html") @"
<!doctype html><meta charset="utf-8"><title>frame identity check</title>
<body style="font:14px system-ui;padding:24px">Checking frame identity...</body>
<script>
(function () {
  var isTop = window.top === window;
  __SWIFT_PWA__.invoke('probe.record', { label: isTop ? 'main' : 'child-same' });
  if (!isTop) { return; }
  function frame(attr, value) {
    var f = document.createElement('iframe');
    f.setAttribute(attr, value);
    document.body.appendChild(f);
  }
  frame('src', '/child.html?label=child-path');
  frame('src', location.pathname);
  frame('srcdoc', '<script>__SWIFT_PWA__.invoke("probe.record", { label: "srcdoc" });<\/script>');
  // Long enough for four frames to load, run bridge.js and post. What each
  // frame actually became is reported too - every one of them is same-origin
  // or srcdoc, so the top document can read their URL and readyState, which
  // separates "the frame never loaded" from "it loaded and wasn't heard".
  setTimeout(function () {
    var notes = [];
    Array.prototype.forEach.call(document.querySelectorAll('iframe'), function (f, i) {
      var href, state;
      try { href = f.contentWindow.location.href; } catch (e) { href = 'blocked-' + e.name; }
      try { state = f.contentDocument.readyState; } catch (e) { state = 'blocked'; }
      notes.push(i + ':' + state + '@' + href);
    });
    __SWIFT_PWA__.invoke('probe.record', { label: 'note=' + notes.join(',') });
    setTimeout(function () { __SWIFT_PWA__.invoke('app.quit', { exitCode: 0 }); }, 500);
  }, 9000);
})();
</script>
"@

Write-Host "Building $appName..." -ForegroundColor Cyan
Push-Location $appDir
try {
    & (Join-Path $Repo ".build\debug\swift-pwa.exe") build --target windows --configuration debug | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "app build failed" }
} finally { Pop-Location }

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$exeDir = Join-Path $appDir "build\windows\$appName"
$runner = Join-Path $WorkDir "run.cmd"
# The app's own diagnostics are half the check: a refusal nobody is told about
# is the failure mode this exists to prevent.
$diagPath = Join-Path $WorkDir "app.log"
Write-Utf8NoBom $runner ("@echo off`r`ncd /d `"$exeDir`"`r`n" +
    "$appName.exe > `"$diagPath`" 2>&1`r`n")
Invoke-App $runner
# -Encoding UTF8: the runtime writes UTF-8, and reading it as the console
# codepage mangles anything non-ASCII in the message.
$diagnostics = @(Get-Content $diagPath -Encoding UTF8 -ErrorAction SilentlyContinue |
    Where-Object { $_ -match 'refused a bridge call from embedded content' })

$lines = @(Get-ChildItem $logDir -Filter *.txt -ErrorAction SilentlyContinue |
    ForEach-Object { (Get-Content $_.FullName -Raw).Trim() } | Where-Object { $_ -match '\S' })
Write-Host "`n-- what the app saw --" -ForegroundColor Cyan
if ($lines.Count -eq 0) { Write-Host "(nothing)" } else { $lines | ForEach-Object { Write-Host "   $_" } }

Write-Host "`n-- what the app reported --" -ForegroundColor Cyan
if ($diagnostics.Count -eq 0) { Write-Host "(no refusals reported)" } else { $diagnostics | ForEach-Object { Write-Host "   $_" } }

# The leading comma keeps this an array: PowerShell unwraps a single-element
# array on return, and indexing a bare string yields its first *character*.
function Get-Records([string]$Label) {
    , @($lines | Where-Object { $_ -like "$Label *" } | ForEach-Object { $_.Substring($Label.Length + 1) })
}

$failed = $false
$got = Get-Records $mustReach
if ($got.Count -eq 0) {
    Write-Host "FAIL  $mustReach never reached the bridge" -ForegroundColor Red
    $failed = $true
} elseif ($got.Count -gt 1) {
    # Both the top-level and a per-frame event firing for one message would run
    # every command twice.
    Write-Host "FAIL  $mustReach arrived $($got.Count) times - delivered on more than one event" -ForegroundColor Red
    $failed = $true
} elseif ($got[0] -ne "main") {
    Write-Host "FAIL  $mustReach reported $($got[0]), expected main" -ForegroundColor Red
    $failed = $true
} else {
    Write-Host "PASS  $mustReach -> main" -ForegroundColor Green
}

foreach ($label in $mustBeRefused.Keys) {
    $marker = $mustBeRefused[$label]
    if ((Get-Records $label).Count -gt 0) {
        Write-Host "FAIL  $label reached the app's commands - embedded content must not" -ForegroundColor Red
        $failed = $true
    } elseif (-not ($diagnostics | Where-Object { $_ -like "*$marker*" })) {
        # Either the frame never called, or it did and was dropped in silence -
        # the second is the bug this guards, and both are failures here.
        Write-Host "FAIL  $label was never reported as refused (looked for '$marker')" -ForegroundColor Red
        $failed = $true
    } else {
        Write-Host "PASS  $label refused, and said so" -ForegroundColor Green
    }
}

if (-not $KeepWorkDir) { Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue }
if ($failed) { exit 1 }
Write-Host "`nFrame identity is reported correctly on Windows." -ForegroundColor Green
