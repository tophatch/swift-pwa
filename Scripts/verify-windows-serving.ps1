<#
.SYNOPSIS
  End-to-end check that a Windows build actually *serves* its bundle origin:
  the bundle itself, a `ctx.serveDirectory(_:at:)` mount, and an honest 404.

.DESCRIPTION
  CI builds the Windows target but never launches it (`swift test` can't run
  there, and a hosted runner has no interactive session), so nothing automated
  fetches a URL on the bundle origin. That gap is how #159 shipped: a folder
  mapping answered before `WebResourceRequested` was raised, every
  `serveDirectory` mount was unreachable, and the build was green throughout.
  Run this on a real Windows box after touching `WebView2Adapter`'s serving
  path, `AssetProvider`, or anything about the bundle origin.

  It scaffolds a throwaway app against the checkout you point it at, mounts a
  directory with known bytes, and has the page check every expectation and
  report by *exit code* - the app is a console-less GUI process whose stdout
  goes nowhere, and the box may be locked, so neither a log nor a screenshot
  can be relied on.

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
  pwsh -File Scripts/verify-windows-serving.ps1 -Repo C:\src\swift-pwa
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Packages,
    [string]$WorkDir = "$env:TEMP\swift-pwa-serving-check",
    [switch]$KeepWorkDir
)

$ErrorActionPreference = "Stop"
if (-not $Repo) { $Repo = (Resolve-Path "$PSScriptRoot\..").Path }
if (-not $Packages) { $Packages = Join-Path $Repo "packages" }
$appName = "ServingCheck"
$appDir = Join-Path $WorkDir $appName
$packsDir = Join-Path $WorkDir "packs"
$taskName = "swift-pwa-serving-check"

# The expectations the page checks. Exit code 0 means every one held; a
# non-zero code is 2 + the index of the first that didn't, so a failure says
# which. Sizes are bytes we write below, so a wrong body length is caught too.
$expectations = @(
    @{ url = "/packs/photo.png"; status = 200; len = 68 },  # mount, binary
    @{ url = "/packs/note.txt";  status = 200; len = 25 },  # mount, text
    @{ url = "/packs/nope.png";  status = 404; len = 0 },   # missing under a mount
    @{ url = "/index.html";      status = 200; len = -1 },  # the bundle itself
    # Ranges of note.txt ("hello from a served mount"): one that stops short of
    # the end, and one past the end, which has no body.
    @{ url = "/packs/note.txt"; range = "bytes=6-9";  status = 206; len = 4; text = "from" },
    @{ url = "/packs/note.txt"; range = "bytes=100-"; status = 416; len = 0 }
)

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }

function Enter-BuildEnv {
    # A shell that already has the MSVC environment (CI, Scripts/remote-windows.sh)
    # keeps it; a bare SSH shell loads the one for this machine's architecture.
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        $bat = if ($arch -eq 'arm64') { 'vcvarsarm64.bat' } else { 'vcvars64.bat' }
        $vcvars = Get-ChildItem "C:\Program Files*\Microsoft Visual Studio" -Recurse -Filter $bat `
            -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        if (-not $vcvars) { throw "$bat not found - install VS Build Tools (docs/windows-setup.md section 2)." }
        # `cmd /c ... & set` is the only way to lift vcvars' environment into this
        # session; it edits dozens of variables and has no PowerShell equivalent.
        cmd /c "call `"$vcvars`" >nul 2>&1 & set" | ForEach-Object {
            if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
        }
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
        "-Xlinker", "/LIBPATH:$(Join-Path $Packages "Microsoft.Web.WebView2\build\native\$arch")"
    )
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    # Set-Content -Encoding UTF8 writes a BOM on Windows PowerShell, which
    # hides `// swift-tools-version:` from SwiftPM and breaks the manifest.
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-SelfTestPage {
    $checks = ($expectations | ForEach-Object {
        "{ url: '$($_.url)', range: '$($_.range)', status: $($_.status), len: $($_.len), text: '$($_.text)' }"
    }) -join ",`n    "
    @"
<!doctype html>
<meta charset="utf-8">
<title>serving check</title>
<body style="font:14px system-ui;padding:24px">Checking the bundle origin...</body>
<script>
// Reports by exit code: 0 = every expectation held, 2+i = expectation i failed.
// Nothing here can print - a bundled app has no stdout and the box may be locked.
(function () {
  var checks = [
    $checks
  ];
  Promise.all(checks.map(function (c) {
    return fetch(c.url, c.range ? { headers: { Range: c.range } } : undefined).then(function (r) {
      return r.arrayBuffer().then(function (b) {
        var okLen = (c.len < 0) || (b.byteLength === c.len);
        var okText = !c.text || new TextDecoder().decode(b) === c.text;
        return (r.status === c.status && okLen && okText) ? null : (c.url + ' ' + c.range + ' got ' + r.status + '/' + b.byteLength);
      });
    }).catch(function (e) { return c.url + ' threw ' + e.name; });
  })).then(function (results) {
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
    $deadline = (Get-Date).AddSeconds(90)
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

function Test-Build([string]$Label, [string]$ExeDir) {
    Write-Host "== $Label ==" -ForegroundColor Cyan
    Push-Location $appDir
    try {
        $cli = Join-Path $Repo ".build\debug\swift-pwa.exe"
        # --configuration debug so the app driver is compiled in and the build
        # matches what a developer would be debugging.
        & $cli build --target windows --configuration debug | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "$Label build failed" }
    } finally { Pop-Location }

    # The app's own output and exit code, kept for a failure: the task's result
    # alone can't tell a page that reported from a process that never got there.
    $runner = Join-Path $WorkDir "run-$Label.cmd"
    $appLog = Join-Path $WorkDir "app-$Label.log"
    $appCode = Join-Path $WorkDir "app-$Label.code"
    Write-Utf8NoBom $runner ("@echo off`r`ncd /d `"$ExeDir`"`r`n$appName.exe > `"$appLog`" 2>&1`r`n" + `
        "echo %ERRORLEVEL% > `"$appCode`"`r`nexit /b %ERRORLEVEL%`r`n")
    $code = Invoke-App $runner

    if ($code -eq 0) {
        Write-Host "PASS  $Label - bundle, mount, ranges and 404 all correct" -ForegroundColor Green
        return $true
    }
    $which = $code - 2
    $detail = if ($which -ge 0 -and $which -lt $expectations.Count) {
        "$($expectations[$which].url) $($expectations[$which].range) (expected $($expectations[$which].status))"
    } else { "app exited $code before reporting" }
    Write-Host "FAIL  $Label - $detail" -ForegroundColor Red
    $exeCode = if (Test-Path $appCode) { (Get-Content $appCode -Raw).Trim() } else { "none - it never returned" }
    Write-Host "  the app's own exit code: $exeCode"
    if (Test-Path $appLog) { Get-Content $appLog | Select-Object -Last 30 | ForEach-Object { Write-Host "  | $_" } }
    return $false
}

Enter-BuildEnv
if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
New-Item -ItemType Directory -Path $WorkDir, $packsDir | Out-Null

# Known bytes, so a wrong body is a failure and not just a wrong status.
$png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
[IO.File]::WriteAllBytes((Join-Path $packsDir "photo.png"), [Convert]::FromBase64String($png))
[IO.File]::WriteAllText((Join-Path $packsDir "note.txt"), "hello from a served mount")

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

# Point the scaffold at this checkout, and mount the directory before the
# window is created (the navigation's own request arrives immediately).
$manifest = Join-Path $appDir "Package.swift"
$repoForSwift = $Repo.Replace('\', '/')
$repoLeaf = Split-Path $Repo -Leaf
Write-Utf8NoBom $manifest (([IO.File]::ReadAllText($manifest) `
    -replace '\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)', ".package(path: `"$repoForSwift`")") `
    -replace 'package: "swift-pwa"', "package: `"$repoLeaf`"")
# The bundler looks for the NuGet packages beside or above the project, and the
# work directory is neither. A copy, not a junction, so the cleanup's recursive
# delete can't reach the originals.
New-Item -ItemType Directory "$appDir\packages" | Out-Null
foreach ($pkg in "Microsoft.Web.WebView2", "Microsoft.Windows.ImplementationLibrary") {
    Copy-Item -Recurse -Path (Join-Path $Packages $pkg) -Destination "$appDir\packages\$pkg"
}

$appSwift = Join-Path $appDir "Sources\$appName\App.swift"
$packsForSwift = $packsDir.Replace('\', '\\')
Write-Utf8NoBom $appSwift ([IO.File]::ReadAllText($appSwift) -replace `
    '(?m)^    _ = try ctx\.createWindow\(', `
    "    ctx.serveDirectory(URL(fileURLWithPath: `"$packsForSwift`"), at: `"/packs`")`r`n`r`n    _ = try ctx.createWindow(")

Write-Utf8NoBom (Join-Path $appDir "web\index.html") (New-SelfTestPage)

$results = @()
$results += Test-Build "folder" (Join-Path $appDir "build\windows\$appName")

if (-not $KeepWorkDir) { Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue }
if ($results -contains $false) { exit 1 }
Write-Host "All serving checks passed." -ForegroundColor Green
