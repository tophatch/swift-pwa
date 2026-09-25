<#
.SYNOPSIS
    Drive a real app on Windows and check that keyboard, editing and drag work.

.DESCRIPTION
    The Windows half of Scripts/verify-driven-input.sh — same checks, same
    traps, in the language this box has. (No bash here, and the checks are all
    `swift-pwa drive` calls, so a sibling is cheaper than a dependency.)

    Why it exists: the WM_SETFOCUS -> MoveFocus fix in #163 was verified by hand
    and CI only ever *compiles* this backend, so it could regress silently
    (#164). Synthetic input reaches the page through the DevTools protocol
    (Input.dispatchKeyEvent / dispatchMouseEvent over
    CallDevToolsProtocolMethod), which needs no foreground window — but it does
    need a WebView2 controller, and that needs a desktop.

    **Session 0.** Windows OpenSSH puts your shell in the non-interactive
    services session, where WebView2 refuses to create a controller: the app
    starts, the driver attaches, `info` answers, and every page-dependent verb
    times out behind `CreateCoreWebView2Controller failed: 0x80070578`
    (ERROR_INVALID_WINDOW_HANDLE). Nothing is wrong with the app; there is no
    desktop to put a window on. So when this script finds itself in session 0 it
    launches the app into the active console session with a scheduled task and
    attaches over loopback, which crosses the session boundary fine. Run from a
    console or RDP session it just launches the app.

.PARAMETER AppDir
    Where to build the probe app. Defaults to a temp directory.

.PARAMETER Keep
    Don't delete the probe app afterwards.

.PARAMETER Packages
    The `packages\` folder holding the WebView2 and WIL NuGet packages.
    Defaults to `<repo>\packages`. Swift 6.4 no longer passes `INCLUDE` / `LIB`
    on, so the probe app gets them as flags (#219).

.PARAMETER Background
    Launch with SWIFT_PWA_DRIVE_BACKGROUND=1 — the parked, never-activated
    window an e2e suite runs in (#208). Input has to reach it too.
#>
[CmdletBinding()]
param(
    [string]$AppDir = "",
    [switch]$Keep,
    [string]$Packages = "",
    [switch]$Background
)

$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0

function Pass($name) { Write-Output "  PASS  $name"; $script:Passed++ }
function Fail($name, $detail) { Write-Output "  FAIL  $name"; Write-Output "        $detail"; $script:Failed++ }
function Skip($name, $why) { Write-Output "  SKIP  $name - $why"; $script:Skipped++ }

# --- Probe app --------------------------------------------------------------
$cleanupApp = $false
if (-not $AppDir) {
    $AppDir = Join-Path ([System.IO.Path]::GetTempPath()) "DrivenInputProbe"
    if (-not $Keep) { $cleanupApp = $true }
}
$cli = Join-Path $repo ".build\debug\swift-pwa.exe"
if (-not $Packages) { $Packages = Join-Path $repo "packages" }
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$buildFlags = @(
    '-Xcc', "-I$Packages\Microsoft.Web.WebView2\build\native\include",
    '-Xcc', "-I$Packages\Microsoft.Windows.ImplementationLibrary\include",
    '-Xlinker', "/LIBPATH:$Packages\Microsoft.Web.WebView2\build\native\$arch"
)

Write-Output "-> building the CLI"
Push-Location $repo
swift build --product swift-pwa @buildFlags 2>&1 | Out-Null
Pop-Location
if (-not (Test-Path $cli)) { Write-Error "couldn't build swift-pwa.exe"; exit 1 }

if (-not (Test-Path $AppDir)) {
    Write-Output "-> scaffolding a probe app in $AppDir"
    $parent = Split-Path -Parent $AppDir
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Push-Location $parent
    & $cli init (Split-Path -Leaf $AppDir) | Out-Null
    Pop-Location
}

# `swift-pwa init` pins the app to the last *released* package, so an app
# scaffolded here would exercise the shipped backend and quietly ignore every
# local change. Point it at this checkout instead.
$manifest = Join-Path $AppDir "Package.swift"
$source = Get-Content $manifest -Raw
$escaped = $repo -replace '\\', '\\'
$patched = [regex]::Replace($source, '\.package\(url: "[^"]*swift-pwa"[^)]*\)', ".package(path: `"$escaped`")")
# A path dependency is named after its directory, so a checkout not called
# swift-pwa leaves the product pointing at a package that no longer exists.
$patched = $patched -replace 'package: "swift-pwa"', "package: `"$(Split-Path -Leaf $repo)`""
if ($patched -ne $source) {
    Set-Content -Path $manifest -Value $patched
    Write-Output "    repointed Package.swift at the working tree"
}

Copy-Item (Join-Path $repo "Scripts\driver-probe\index.html") (Join-Path $AppDir "web\index.html") -Force

Write-Output "-> building the probe app"
Push-Location $AppDir
$buildOutput = swift build @buildFlags 2>&1 | ForEach-Object { "$_" }
$built = $LASTEXITCODE
Pop-Location
if ($built -ne 0) {
    $buildOutput | Where-Object { $_ -match 'error:' } | Select-Object -First 10 | ForEach-Object { Write-Output $_ }
    Write-Error "the probe app didn't build"; exit 1
}

$binary = Get-ChildItem (Join-Path $AppDir ".build") -Recurse -Filter "$(Split-Path -Leaf $AppDir).exe" |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $binary) { Write-Error "couldn't find the built probe binary"; exit 1 }

# --- Launch -----------------------------------------------------------------
$log = Join-Path ([System.IO.Path]::GetTempPath()) "driven-input-probe.log"
Remove-Item $log -ErrorAction SilentlyContinue
$sessionId = (Get-Process -Id $PID).SessionId
$taskName = "SwiftPWADrivenInputProbe"

if ($sessionId -eq 0) {
    Write-Output "-> session 0: launching the app on the interactive desktop via a scheduled task"
    $launcher = Join-Path ([System.IO.Path]::GetTempPath()) "driven-input-launch.bat"
    @"
@echo off
set SWIFT_PWA_DRIVE=0
set SWIFT_PWA_DRIVE_BACKGROUND=$(if ($Background) { '1' } else { '0' })
set SWIFT_PWA_WEB_ROOT=$AppDir\web
"$binary" > "$log" 2>&1
"@ | Set-Content -Path $launcher -Encoding ASCII
    schtasks /create /tn $taskName /tr "`"$launcher`"" /sc once /st 23:59 /f /it /ru $env:USERNAME | Out-Null
    schtasks /run /tn $taskName | Out-Null
} else {
    $env:SWIFT_PWA_DRIVE = "0"
    $env:SWIFT_PWA_DRIVE_BACKGROUND = $(if ($Background) { '1' } else { '0' })
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

function Drive { & $cli drive @args --attach $port --token $token 2>$null }
function EvalJs($js) { (Drive eval $js) -replace '^"', '' -replace '"$', '' }

Write-Output "-> driving $(Split-Path -Leaf $binary) on windows (port $port)$(if ($Background) { ', backgrounded' })"

$caps = (Drive info) -join "`n"
$hasKey = $false; $hasPointer = $false; $hasWheel = $false; $delivery = "?"
try {
    $parsed = $caps | ConvertFrom-Json
    $hasKey = [bool]$parsed.input.key
    $hasPointer = [bool]$parsed.input.pointer
    $hasWheel = [bool]$parsed.input.wheel
    $delivery = $parsed.input.delivery
} catch { }
Write-Output "   input: key=$hasKey pointer=$hasPointer delivery=$delivery"

# --- 1. Control: a keystroke that MUST land ---------------------------------
# A quiet environment is not a passing test: with no desktop every check below
# fails exactly as a broken fix would. Prove one keystroke lands before
# believing any failure that follows.
if ($hasKey) {
    EvalJs "__setField('')" | Out-Null
    Drive type "x" --selector "#field" | Out-Null
    $control = EvalJs "__field()"
    if ($control -eq "x") {
        Pass "control: a plain keystroke reaches a focused field"
    } else {
        Fail "control: a plain keystroke reaches a focused field" `
             "typed 'x', field holds '$control' - everything below would be meaningless, stopping here"
        Write-Output ""
        Write-Output "Result: $script:Passed passed, $script:Failed failed, $script:Skipped skipped"
        Stop-Probe
        exit 1
    }
} else {
    Skip "control" "this backend reports no key input"
}

# --- 2. Editing shortcuts, each step leaving a distinct value ---------------
# The obvious sequence round-trips to its starting value, which is equally
# consistent with everything working and with only select-all working.
$undoOk = $false
if ($hasKey) {
    EvalJs "__setField('alpha')" | Out-Null
    Drive type --key a --modifiers control | Out-Null
    Drive type --key x --modifiers control | Out-Null
    $afterCut = EvalJs "__field()"
    Drive type "beta" | Out-Null
    $afterType = EvalJs "__field()"
    if ($afterCut -eq "" -and $afterType -eq "beta") {
        Pass "editing: select-all, cut and typing each leave a distinct value"
    } else {
        Fail "editing: select-all, cut and typing each leave a distinct value" `
             "cut->'$afterCut' (want ''), type->'$afterType' (want 'beta')"
    }

    # Paste is a separate check because the *driver* can't reach the system
    # clipboard here, and that is not an app bug. Synthetic input arrives
    # through the DevTools protocol, which dispatches into the renderer;
    # Chromium runs clipboard commands in the browser process off a native key
    # event. Measured: after a driven Ctrl+X the field empties (the renderer did
    # run Cut) and `Get-Clipboard` is still empty, so Ctrl+V has nothing to
    # restore. A real user's Ctrl+X/Ctrl+V works — only driving it doesn't.
    Skip "clipboard" "the DevTools protocol can't reach the system clipboard; a real keystroke still can"
} else {
    Skip "editing" "this backend reports no key input"
    Skip "clipboard" "this backend reports no key input"
}

# --- 3. Undo and redo -------------------------------------------------------
if ($hasKey) {
    EvalJs "__setField('')" | Out-Null
    Drive type "abc" --selector "#field" | Out-Null
    Drive type --key z --modifiers control | Out-Null
    $afterUndo = EvalJs "__field()"
    Drive type --key z --modifiers "control,shift" | Out-Null
    $afterRedo = EvalJs "__field()"
    # Undo granularity differs per engine, so assert that undo changed
    # something and redo put it back - both true only if the path works.
    if ($afterUndo -ne "abc" -and $afterRedo -eq "abc") {
        $undoOk = $true
        Pass "undo: type, undo, redo round-trips through the embedder"
    } else {
        Fail "undo: type, undo, redo round-trips through the embedder" `
             "typed 'abc', undo->'$afterUndo' (want anything else), redo->'$afterRedo' (want 'abc')"
    }
} else {
    Skip "undo" "this backend reports no key input"
}

# --- 4. The page keeps the undo key when it claims it -----------------------
if ($hasKey -and $undoOk) {
    EvalJs "__setField('')" | Out-Null
    Drive type "xyz" --selector "#field" | Out-Null
    EvalJs "__probe.swallowUndo = true, 'on'" | Out-Null
    Drive type --key z --modifiers control | Out-Null
    $swallowed = EvalJs "__field()"
    $saw = EvalJs "__probe.sawUndoKey"
    EvalJs "__probe.swallowUndo = false, 'off'" | Out-Null
    if ($swallowed -eq "xyz" -and $saw -ne "0") {
        Pass "preventDefault: a page that claims the undo key keeps it"
    } else {
        Fail "preventDefault: a page that claims the undo key keeps it" `
             "page saw the key $saw time(s) and field is '$swallowed' (want 'xyz' - unchanged)"
    }
} elseif ($hasKey) {
    # "The field didn't change" is equally true of a page that kept the key and
    # of an undo that never fired, so this would pass by not testing anything.
    Skip "preventDefault" "undo didn't work here, so 'the page kept the key' would prove nothing"
} else {
    Skip "preventDefault" "this backend reports no key input"
}

# --- 5. A fresh window takes typing with no click first ---------------------
# The Windows one. Activating the host window does not focus the web content:
# document.hasFocus() stayed false and every keystroke went nowhere until the
# user clicked inside it, until WM_SETFOCUS -> MoveFocus.
if ($hasKey) {
    EvalJs "__setField('')" | Out-Null
    EvalJs "document.getElementById('field').focus(), 'ok'" | Out-Null
    Drive type "k" | Out-Null
    $focused = EvalJs "__field()"
    if ($focused -eq "k") {
        Pass "focus: typing lands without a click first"
    } else {
        Fail "focus: typing lands without a click first" "typed 'k' into a focused field, got '$focused'"
    }
} else {
    Skip "focus" "this backend reports no key input"
}

# --- 6. Drag ----------------------------------------------------------------
if ($hasPointer) {
    EvalJs "__reset()" | Out-Null
    Drive drag --from "70,150" --to "400,150" --to "400,320" --duration 400 | Out-Null
    $reportRaw = EvalJs "JSON.stringify({moves:__probe.moves.length,trusted:__probe.trusted,corner:__probe.moves.some(m=>m.x===400&&m.y===150),speed:__probe.endSpeed,left:document.getElementById('box').style.left})"
    $problems = @()
    try {
        $r = ($reportRaw -replace '\\"', '"') | ConvertFrom-Json
        if (-not $r.trusted) { $problems += "events were not trusted" }
        if ($r.moves -lt 5) { $problems += "only $($r.moves) move(s) reached the page" }
        if (-not $r.corner) { $problems += "the path did not pass through its corner" }
        if (-not $r.speed) { $problems += "no end-of-gesture velocity - the moves had no spacing" }
        if (-not $r.left) { $problems += "the page did not move anything" }
    } catch { $problems += "couldn't read the probe back: $reportRaw" }
    if ($problems.Count -eq 0) {
        Pass "drag: a multi-segment gesture delivers a real, paced path"
    } else {
        Fail "drag: a multi-segment gesture delivers a real, paced path" (($problems -join "; ") + " ($reportRaw)")
    }
} else {
    Skip "drag" "this backend reports no pointer input"
}

# --- 7. Wheel ---------------------------------------------------------------
# Two facts, checked separately: the event reached the page, trusted, and it
# scrolled the element under it. A wheel that returns success and delivers
# nothing (#264) reads as a scroll-chaining bug in whatever test used it.
if ($hasWheel) {
    EvalJs "__reset()" | Out-Null
    Drive scroll 120 --selector "#scroller" | Out-Null
    $reportRaw = EvalJs "JSON.stringify({wheels:__probe.wheels,top:document.getElementById('scroller').scrollTop})"
    $problems = @()
    try {
        $r = ($reportRaw -replace '\\"', '"') | ConvertFrom-Json
        $w = @($r.wheels)
        if ($w.Count -eq 0) { $problems += "no wheel event reached the page" }
        elseif (@($w | Where-Object { -not $_[2] }).Count -gt 0) { $problems += "wheel events were not trusted" }
        elseif (@($w | Where-Object { $_[1] -eq 'scroller' }).Count -eq 0) { $problems += "no wheel event targeted #scroller" }
        if (-not $r.top) { $problems += "#scroller did not scroll" }
    } catch { $problems += "couldn't read the probe back: $reportRaw" }
    if ($problems.Count -eq 0) {
        Pass "wheel: a scroll reaches the page trusted and scrolls the element under it"
    } else {
        Fail "wheel: a scroll reaches the page trusted and scrolls the element under it" (($problems -join "; ") + " ($reportRaw)")
    }
} elseif ($Background) {
    $out = (& $cli drive scroll 120 --selector "#scroller" --attach $port --token $token 2>&1) -join " "
    if ($LASTEXITCODE -eq 0) {
        Fail "wheel: refused, not dropped, in a backgrounded run" "drive info reports no wheel, yet drive scroll succeeded: $out"
    } elseif ($out -match "background") {
        Pass "wheel: refused, not dropped, in a backgrounded run"
    } else {
        Fail "wheel: refused, not dropped, in a backgrounded run" "failed without naming --background: $out"
    }
} else {
    Skip "wheel" "this backend reports no wheel input"
}

Write-Output ""
Write-Output "Result: $script:Passed passed, $script:Failed failed, $script:Skipped skipped"
Stop-Probe
if ($script:Failed -ne 0) { exit 1 }
exit 0
