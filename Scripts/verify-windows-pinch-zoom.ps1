<#
.SYNOPSIS
  Verify that a page's viewport tag stops WebView2 zooming it (#304).

.DESCRIPTION
  WebView2, like desktop Chromium, ignores `<meta name="viewport"
  content="user-scalable=no">`, so a pinch magnified an app's whole UI that
  every other platform leaves alone. Swift-pwa injects a script that gives the
  tag its meaning (see ViewportZoom.swift). This drives a pinch at a real app
  through the DevTools protocol and reads `visualViewport.scale` back:

    1. CONTROL, must zoom: a page with no viewport tag, touchpad pinch. If it
       doesn't zoom, the instrument can't show anything and the run fails.
    2. A page whose tag rules zoom out, touchpad pinch: no zoom, and the page
       still receives the pinch's Ctrl-wheel events, so it can handle the
       gesture itself.
    3. The same with a touch pinch, and its two-finger touchmove events. Only
       measurable where a touch pinch zooms the control page: Chromium leaves a
       machine with no touchscreen unzoomed either way, so there the row is a
       SKIP, not a pass.

  A touchpad pinch is Input.synthesizePinchGesture, and a touch pinch two
  fingers moving apart through Input.dispatchTouchEvent, both reached through
  WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port. WebView2's own
  pinch setting stops a synthesized pinch as it stops a real one (measured), so
  the instrument sees what a user's pinch would do. The app is launched through
  a scheduled task with /IT, since an SSH session has no desktop for WebView2.

.PARAMETER Released
  Build against the last release instead: the control for the fix, where row
  2 has to fail.

.EXAMPLE
  powershell -File Scripts\verify-windows-pinch-zoom.ps1 -Packages C:\src\swift-pwa\packages
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Packages,
    [string]$WorkDir = "$env:TEMP\swift-pwa-pinch-zoom",
    [int]$Port = 9229,
    [switch]$Released
)

$ErrorActionPreference = "Stop"
if (-not $Repo) { $Repo = (Resolve-Path "$PSScriptRoot\..").Path }
if (-not $Packages) { $Packages = Join-Path $Repo "packages" }
$appName = "PinchZoomCheck"
$appDir = Join-Path $WorkDir $appName
$taskName = "swift-pwa-pinch-zoom-check"
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }

function Enter-BuildEnv {
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        $bat = if ($arch -eq 'arm64') { 'vcvarsarm64.bat' } else { 'vcvars64.bat' }
        $vcvars = Get-ChildItem "C:\Program Files*\Microsoft Visual Studio" -Recurse -Filter $bat `
            -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        if (-not $vcvars) { throw "$bat not found - install VS Build Tools (docs/windows-setup.md)." }
        cmd /c "call `"$vcvars`" >nul 2>&1 & set" | ForEach-Object {
            if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
        }
    }
    $wv2 = Join-Path $Packages "Microsoft.Web.WebView2\build\native"
    $wil = Join-Path $Packages "Microsoft.Windows.ImplementationLibrary\include"
    if (-not (Test-Path "$wv2\include")) { throw "WebView2 headers not at $wv2 - pass -Packages." }
    # Flags, not $env:INCLUDE / $env:LIB: Swift 6.4 passes neither on (#219).
    $script:BuildFlags = @("-Xcc", "-I$wv2\include", "-Xcc", "-I$wil", "-Xlinker", "/LIBPATH:$wv2\$arch")
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    # A BOM hides `// swift-tools-version:` from SwiftPM.
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# Runs a native command, failing on its exit code rather than on PowerShell
# 5.1 reading its first stderr line as an error.
function Invoke-Native([string]$Label, [scriptblock]$Command) {
    $ErrorActionPreference = "Continue"
    & $Command 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$Label failed ($LASTEXITCODE)" }
}

function New-Page([string]$Viewport) {
    $meta = if ($Viewport) { "<meta name=`"viewport`" content=`"$Viewport`">" } else { "" }
    @"
<!doctype html><meta charset="utf-8">$meta<title>pinch check</title>
<script>
window.__events = { touchmove2: 0, ctrlwheel: 0 };
addEventListener('touchmove', e => { if (e.touches.length >= 2) __events.touchmove2++; }, { passive: true });
addEventListener('wheel', e => { if (e.ctrlKey) __events.ctrlwheel++; }, { passive: true });
</script>
<body style="font:14px system-ui;padding:24px;height:2000px">pinch check</body>
"@
}

# The smallest DevTools client that works on Windows PowerShell 5.1: .NET's
# ClientWebSocket, one request at a time.
function Connect-DevTools {
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        try {
            $pages = @(Invoke-RestMethod "http://127.0.0.1:$Port/json" -TimeoutSec 2 |
                Where-Object { $_.type -eq "page" -and $_.url -notlike "about:*" })
            if ($pages.Count -gt 0) {
                $socket = New-Object System.Net.WebSockets.ClientWebSocket
                $socket.ConnectAsync([Uri]$pages[0].webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
                $script:NextId = 0
                return $socket
            }
        } catch { }
        Start-Sleep -Seconds 1
    }
    throw "no DevTools page on port $Port - did the app start?"
}

function Invoke-DevTools($Socket, [string]$Method, [hashtable]$Params = @{}) {
    $script:NextId++
    $id = $script:NextId
    $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 5 -Compress))
    $Socket.SendAsync((New-Object ArraySegment[byte] -ArgumentList (, $bytes)),
        [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
    $buffer = New-Object byte[] 65536
    while ($true) {
        $text = ""
        do {
            $result = $Socket.ReceiveAsync((New-Object ArraySegment[byte] -ArgumentList (, $buffer)),
                [Threading.CancellationToken]::None).Result
            $text += [Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        $message = $text | ConvertFrom-Json
        if ($message.id -eq $id) { return $message }
    }
}

function Get-PageState($Socket) {
    $reply = Invoke-DevTools $Socket "Runtime.evaluate" @{
        expression = "JSON.stringify({ scale: visualViewport.scale, events: window.__events })"
        returnByValue = $true
    }
    return $reply.result.result.value | ConvertFrom-Json
}

# Launches the app on `$Route`, pinches with `$Source`, and returns what the
# page saw: its scale afterwards and the events it was sent.
function Measure-Pinch([string]$Route, [string]$Source) {
    $runner = Join-Path $WorkDir "run.cmd"
    Write-Utf8NoBom $runner (@(
            "@echo off",
            "cd /d `"$script:ExeDir`"",
            "set WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=$Port",
            "set `"SWIFT_PWA_INITIAL_ROUTE=$Route`"",
            "$appName.exe"
        ) -join "`r`n")
    cmd /c "schtasks /delete /tn $taskName /f >nul 2>&1"
    cmd /c "schtasks /create /tn $taskName /tr `"$runner`" /sc once /st 00:00 /it /f >nul 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "could not create the scheduled task (is a user logged on?)" }
    cmd /c "schtasks /run /tn $taskName >nul 2>&1"
    try {
        $socket = Connect-DevTools
        # The page's own script has to have run before the pinch.
        for ($i = 0; $i -lt 50 -and -not (Get-PageState $socket).events; $i++) { Start-Sleep -Milliseconds 200 }
        Start-Sleep -Seconds 1
        if ($Source -eq "touch") {
            # Two fingers moving apart, as raw touch events: the synthesized
            # touch pinch zooms nothing in WebView2, even with no tag.
            $fingers = { param($spread) @(
                    @{ x = 300 - $spread; y = 300; id = 0 },
                    @{ x = 300 + $spread; y = 300; id = 1 }) }
            $null = Invoke-DevTools $socket "Input.dispatchTouchEvent" @{ type = "touchStart"; touchPoints = (& $fingers 20) }
            foreach ($spread in 30, 50, 80, 120, 160, 200) {
                $null = Invoke-DevTools $socket "Input.dispatchTouchEvent" @{ type = "touchMove"; touchPoints = (& $fingers $spread) }
                Start-Sleep -Milliseconds 30
            }
            $null = Invoke-DevTools $socket "Input.dispatchTouchEvent" @{ type = "touchEnd"; touchPoints = @() }
        } else {
            $null = Invoke-DevTools $socket "Input.synthesizePinchGesture" @{
                x = 300; y = 300; scaleFactor = 4; relativeSpeed = 400; gestureSourceType = $Source
            }
        }
        Start-Sleep -Milliseconds 1500
        $state = Get-PageState $socket
        $socket.Dispose()
        return $state
    } finally {
        Get-Process $appName -ErrorAction SilentlyContinue | Stop-Process -Force
        cmd /c "schtasks /delete /tn $taskName /f >nul 2>&1"
        Start-Sleep -Seconds 2
    }
}

Enter-BuildEnv
if (Test-Path $WorkDir) { cmd /c "rd /s /q `"\\?\$WorkDir`"" }
New-Item -ItemType Directory -Path $WorkDir | Out-Null

Write-Host "== building ==" -ForegroundColor Cyan
Push-Location $Repo
try { Invoke-Native "CLI build" { swift build --product swift-pwa @BuildFlags } } finally { Pop-Location }
$cli = Join-Path $Repo ".build\debug\swift-pwa.exe"
Push-Location $WorkDir
try { Invoke-Native "init" { & $cli init $appName } } finally { Pop-Location }
if ($Released) {
    Write-Host "   against the released package" -ForegroundColor Cyan
} else {
    Write-Host "   against this checkout" -ForegroundColor Cyan
    $manifest = Join-Path $appDir "Package.swift"
    $text = [IO.File]::ReadAllText($manifest)
    $pin = '\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)'
    if ($text -notmatch $pin) { throw "the scaffold's package pin moved; this would test the released package" }
    Write-Utf8NoBom $manifest (($text -replace $pin, ".package(path: `"$($Repo.Replace('\', '/'))`")") `
        -replace 'package: "swift-pwa"', "package: `"$(Split-Path $Repo -Leaf)`"")
}
Write-Utf8NoBom (Join-Path $appDir "web\index.html") (New-Page "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no")
Write-Utf8NoBom (Join-Path $appDir "web\zoomable.html") (New-Page "")
# The bundler looks for the NuGet packages beside or above the project.
New-Item -ItemType Directory "$appDir\packages" | Out-Null
foreach ($pkg in "Microsoft.Web.WebView2", "Microsoft.Windows.ImplementationLibrary") {
    Copy-Item -Recurse -Path (Join-Path $Packages $pkg) -Destination "$appDir\packages\$pkg"
}
Push-Location $appDir
try { Invoke-Native "app build" { & $cli build --target windows --configuration debug } } finally { Pop-Location }
$script:ExeDir = Join-Path $appDir "build\windows\$appName"

$failed = $false
function Report([string]$Verdict, [string]$Row, $State) {
    $color = @{ PASS = "Green"; FAIL = "Red"; SKIP = "Yellow" }[$Verdict]
    Write-Host ("{0} {1}: scale {2:N2}, events {3}" -f $Verdict, $Row, $State.scale, ($State.events | ConvertTo-Json -Compress)) `
        -ForegroundColor $color
    if ($Verdict -eq "FAIL") { $script:failed = $true }
}

Write-Host "== rows ==" -ForegroundColor Cyan
$control = Measure-Pinch "/zoomable.html" "mouse"
Report $(if ($control.scale -gt 1.5) { "PASS" } else { "FAIL" }) "1. control: a page with no tag zooms on a touchpad pinch" $control

$touchpad = Measure-Pinch "/index.html" "mouse"
Report $(if ($touchpad.scale -lt 1.01 -and $touchpad.events.ctrlwheel -gt 0) { "PASS" } else { "FAIL" }) `
    "2. user-scalable=no: a touchpad pinch doesn't zoom, and its events reach the page" $touchpad

$touchControl = Measure-Pinch "/zoomable.html" "touch"
$touch = Measure-Pinch "/index.html" "touch"
$verdict = if ($touchControl.scale -lt 1.5) { "SKIP" }
elseif ($touch.scale -lt 1.01 -and $touch.events.touchmove2 -gt 0) { "PASS" } else { "FAIL" }
Write-Host ("     touch control, no tag: scale {0:N2}" -f $touchControl.scale)
Report $verdict "3. user-scalable=no: a touch pinch doesn't zoom, and its events reach the page" $touch
if ($verdict -eq "SKIP") {
    Write-Host "   (a touch pinch doesn't zoom even the control page here, so there is nothing to stop)"
}

Write-Host ""
if ($failed) { Write-Host "FAIL: see above." -ForegroundColor Red; exit 1 }
Write-Host "PASS: every row that could be measured held." -ForegroundColor Green
