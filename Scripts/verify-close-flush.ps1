<#
.SYNOPSIS
    Check that a page and the app's Swift code both get to finish their work
    when a window closes or the app quits, on Windows (#281).

.DESCRIPTION
    The Windows half of Scripts/verify-close-flush.sh: same probe
    (Scripts/close-flush-probe/), same markers, same rows where Windows has
    them. Each row launches a fresh scaffolded app; the probe writes a marker
    line, synchronously, from `willClose`, `visibilitychange` to hidden,
    `pagehide`, a 300ms-slow invoke posted from `pagehide`, and a Swift
    `beforeClose` handler.

    Rows: navigate (the control: it worked before #281), window.close, app.quit,
    WM_CLOSE (what the close button and Alt+F4 send), WM_ENDSESSION (logoff /
    shutdown), and app.quit with a handler that never returns.

    No Ctrl+Q row: the driver's keys go into the page through the DevTools
    protocol, so they never reach the window's own WM_KEYDOWN, which is where
    the shortcut lives. It calls the same `quit` as the app.quit row.

    **Session 0.** An SSH shell is in the services session, where WebView2 has
    no desktop. The app is launched into the console session with a scheduled
    task, and so are the WM_CLOSE / WM_ENDSESSION posts: one session can't post
    to another's windows. Someone has to be logged on at the console.

.PARAMETER AppDir
    Where to build the probe app. Defaults to a temp directory.

.PARAMETER Packages
    The `packages\` folder holding the WebView2 and WIL NuGet packages.
    Defaults to `<repo>\packages`.
#>
[CmdletBinding()]
param(
    [string]$AppDir = "",
    [string]$Packages = "",
    [string]$Only = ""
)

$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
$script:Passed = 0
$script:Failed = 0
$tmp = [System.IO.Path]::GetTempPath()

if (-not $AppDir) { $AppDir = Join-Path $tmp "CloseFlushProbe" }
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

# Repoint the scaffold at this checkout, and name the dependency after the
# checkout's directory, which is what SwiftPM calls a path dependency.
$appName = Split-Path -Leaf $AppDir
$manifest = Join-Path $AppDir "Package.swift"
$source = Get-Content $manifest -Raw
$escaped = $repo -replace '\\', '\\'
$patched = [regex]::Replace($source, '\.package\(url: "[^"]*swift-pwa"[^)]*\)', ".package(path: `"$escaped`")")
$patched = $patched -replace 'package: "swift-pwa"', "package: `"$(Split-Path -Leaf $repo)`""
if ($patched -ne $source) { Set-Content -Path $manifest -Value $patched }

$appSwift = Join-Path $AppDir "Sources\$appName\App.swift"
$appSource = Get-Content $appSwift -Raw
if ($appSource -notmatch 'registerCloseProbe\(ctx\)') {
    $appSource = $appSource -replace '(func configure\(_ ctx: any AppContext\) throws \{\r?\n)', "`$1    registerCloseProbe(ctx)`n"
    if ($appSource -notmatch 'registerCloseProbe\(ctx\)') { Write-Error "the scaffold's configure moved; this patch needs updating"; exit 1 }
    Set-Content -Path $appSwift -Value $appSource
}
Copy-Item (Join-Path $repo "Scripts\close-flush-probe\Probe.swift") (Join-Path $AppDir "Sources\$appName\Probe.swift") -Force
Copy-Item (Join-Path $repo "Scripts\close-flush-probe\index.html") (Join-Path $AppDir "web\index.html") -Force
Copy-Item (Join-Path $repo "Scripts\close-flush-probe\second.html") (Join-Path $AppDir "web\second.html") -Force

Write-Output "-> building the probe app"
Push-Location $AppDir
$buildOutput = swift build @buildFlags 2>&1 | ForEach-Object { "$_" }
$built = $LASTEXITCODE
Pop-Location
if ($built -ne 0) {
    $buildOutput | Where-Object { $_ -match 'error:' } | Select-Object -First 10 | ForEach-Object { Write-Output $_ }
    Write-Error "the probe app didn't build"; exit 1
}
$binary = Get-ChildItem (Join-Path $AppDir ".build") -Recurse -Filter "$appName.exe" |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $binary) { Write-Error "couldn't find the built probe binary"; exit 1 }

$sessionId = (Get-Process -Id $PID).SessionId
$markers = Join-Path $tmp "close-flush-markers.txt"
$out = Join-Path $tmp "close-flush-app.log"

# Run a command line in the console session (or here, if this is it).
function Invoke-InConsole($name, $commandLine) {
    if ($sessionId -eq 0) {
        $bat = Join-Path $tmp "$name.bat"
        "@echo off`r`n$commandLine" | Set-Content -Path $bat -Encoding ASCII
        schtasks /create /tn $name /tr "`"$bat`"" /sc once /st 23:59 /f /it /ru $env:USERNAME | Out-Null
        schtasks /run /tn $name | Out-Null
    } else {
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $commandLine -WindowStyle Hidden
    }
}

function Stop-Probe {
    Get-Process -Name $appName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-Probe([switch]$Hang) {
    Stop-Probe
    Remove-Item $markers, $out -ErrorAction SilentlyContinue
    $env_ = "set SWIFT_PWA_DRIVE=0`r`nset SWIFT_PWA_DRIVE_BACKGROUND=1`r`nset SWIFT_PWA_WEB_ROOT=$AppDir\web`r`nset CLOSE_PROBE_LOG=$markers`r`n"
    if ($Hang) { $env_ += "set CLOSE_PROBE_HANG=1`r`n" }
    Invoke-InConsole "SwiftPWACloseFlushProbe" "$env_`"$binary`" > `"$out`" 2>&1"
    $script:port = $null; $script:token = $null
    foreach ($_ in 1..120) {
        if (-not $script:port -and (Test-Path $out)) {
            $line = Select-String -Path $out -Pattern "driver listening" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($line -and $line.Line -match "port=(\d+)") { $script:port = $Matches[1] }
            if ($line -and $line.Line -match "token=([0-9a-f]+)") { $script:token = $Matches[1] }
        }
        if ($script:port -and (Test-Path $markers) -and (Select-String -Path $markers -Pattern '^ready' -Quiet)) { return $true }
        Start-Sleep -Milliseconds 250
    }
    Write-Output "  FAIL  the app never became ready (is anyone logged on at the console?)"
    $script:Failed++
    Stop-Probe
    return $false
}

function Drive { & $cli drive @args --attach $script:port --token $script:token 2>$null | Out-Null }

# Seconds until the probe exits, or "running".
function Wait-Exit($seconds) {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $seconds) {
        if (-not (Get-Process -Name $appName -ErrorAction SilentlyContinue)) { return ("{0:N1}s" -f $watch.Elapsed.TotalSeconds) }
        Start-Sleep -Milliseconds 50
    }
    return "running"
}

function Check($row, $state, $want, [string[]]$expected) {
    $got = if (Test-Path $markers) { @(Get-Content $markers) } else { @() }
    $missing = @($expected | Where-Object { $got -notcontains $_ })
    $exitOk = -not (($want -eq "exits" -and $state -eq "running") -or ($want -eq "stays" -and $state -ne "running"))
    if ($missing.Count -eq 0 -and $exitOk) {
        Write-Output "  PASS  $row - [$($got -join ' ')] process: $state"; $script:Passed++
    } else {
        Write-Output "  FAIL  $row - missing: [$($missing -join ' ')] process: $state (wanted $want); got [$($got -join ' ')]"; $script:Failed++
    }
    Stop-Probe
}

# Post a message to the probe's top-level window from inside its session.
function Send-WindowMessage($messages) {
    $ps = Join-Path $tmp "close-flush-post.ps1"
    @"
Add-Type -Namespace W -Name U -MemberDefinition '[DllImport("user32.dll")] public static extern System.IntPtr SendMessageTimeout(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l, uint f, uint t, out System.IntPtr r); [DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);'
`$h = (Get-Process -Name '$appName').MainWindowHandle
$messages
"@ | Set-Content -Path $ps -Encoding ASCII
    Invoke-InConsole "SwiftPWACloseFlushPost" "powershell -NoProfile -ExecutionPolicy Bypass -File `"$ps`""
}

function Wanted($row) { -not $Only -or $Only -eq $row }
$page = @("willClose", "pagehide", "pagehide-slow")

Write-Output "-> running on windows"

if ((Wanted "navigate") -and (Start-Probe)) {
    Drive eval "location.href = 'second.html'; 1"
    Start-Sleep -Milliseconds 1500
    # Not pagehide-slow: an ordinary navigation cancels the old document's
    # in-flight invokes once the next one arrives, by design.
    Check "navigate (control)" (Wait-Exit 0) "stays" @("pagehide", "second")
    if ($script:Failed -gt 0) {
        Write-Output "::error::the control failed - the probe can't see a page's teardown, so no other row means anything"
        exit 1
    }
}

if ((Wanted "window.close") -and (Start-Probe)) {
    Drive eval "__SWIFT_PWA__.invoke('window.close'); 1"
    # The only window closing quits the app on Windows.
    Check "window.close" (Wait-Exit 6) "exits" ($page + @("swift:window", "swift:quit"))
}

if ((Wanted "app.quit") -and (Start-Probe)) {
    Drive eval "setTimeout(() => __SWIFT_PWA__.invoke('app.quit', {}), 50); 1"
    Check "app.quit" (Wait-Exit 6) "exits" ($page + @("swift:quit"))
}

if ((Wanted "wm-close") -and (Start-Probe)) {
    Send-WindowMessage "[W.U]::PostMessage(`$h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null"
    Check "WM_CLOSE (close button / Alt+F4)" (Wait-Exit 8) "exits" ($page + @("swift:window", "swift:quit"))
}

if ((Wanted "endsession") -and (Start-Probe)) {
    # What a logoff sends: ask, then end. Sent rather than posted, as the
    # system does, so WM_ENDSESSION's handler has to finish before it returns.
    Send-WindowMessage @"
`$r = [IntPtr]::Zero
[W.U]::SendMessageTimeout(`$h, 0x0011, [IntPtr]::Zero, [IntPtr]0x80000000, 0, 5000, [ref]`$r) | Out-Null
[W.U]::SendMessageTimeout(`$h, 0x0016, [IntPtr]1, [IntPtr]0x80000000, 0, 6000, [ref]`$r) | Out-Null
"@
    Start-Sleep -Seconds 8
    # A real logoff ends the process once WM_ENDSESSION returns; a sent one
    # doesn't, so this row asks only that everything landed before it did.
    Check "WM_ENDSESSION (logoff)" "n/a" "any" ($page + @("swift:system"))
}

if ((Wanted "hang") -and (Start-Probe -Hang)) {
    Drive eval "setTimeout(() => __SWIFT_PWA__.invoke('app.quit', {}), 50); 1"
    Check "app.quit with a beforeClose handler that never returns" (Wait-Exit 5) "exits" ($page + @("swift:quit"))
}

if ($sessionId -eq 0) {
    schtasks /delete /tn SwiftPWACloseFlushProbe /f 2>&1 | Out-Null
    schtasks /delete /tn SwiftPWACloseFlushPost /f 2>&1 | Out-Null
}
Write-Output ""
Write-Output "$($script:Passed) passed, $($script:Failed) failed"
if ($script:Failed -gt 0) { exit 1 }
