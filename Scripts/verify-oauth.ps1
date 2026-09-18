<#
.SYNOPSIS
    Drive a real app on Windows through a real OAuth 2.0 authorization-code flow.

.DESCRIPTION
    The Windows half of Scripts/verify-oauth.sh — same checks, same controls, in
    the language this box has. (No bash here, and the checks are all
    `swift-pwa drive` calls plus a local HTTP server, so a sibling is cheaper
    than a dependency.)

    Why it exists: Windows is where this project has twice found that something
    had *never* worked, because CI compiles the backend and never launches an
    app. `auth.*` is three mechanisms wearing one command — a URL handed to the
    system browser, an HTTP listener on 127.0.0.1, and a `state` check — and
    only the middle one is reachable from a unit test.

    The other side of the protocol is a real, separate process
    (Scripts\oauth-probe\provider.py), not a test double, so what it checks is
    what a provider checks: that the authorization request carries what RFC 6749
    and RFC 7636 require, and that the verifier presented at the token endpoint
    actually hashes to the challenge sent at the start.

    **Session 0.** Windows OpenSSH puts your shell in the non-interactive
    services session, where WebView2 refuses to create a controller *and* there
    is no desktop for a browser to open on. So when this script finds itself in
    session 0 it launches the app into the active console session with a
    scheduled task and attaches over loopback, which crosses the session
    boundary fine. If nobody is logged in at the console there is no interactive
    session at all — the browser check then SKIPs rather than failing, which is
    the whole point of running a control first.

.PARAMETER AppDir
    Where to build the probe app. Defaults to a temp directory.

.PARAMETER Keep
    Don't delete the probe app afterwards.
#>
[CmdletBinding()]
param(
    [string]$AppDir = "",
    [switch]$Keep
)

$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0

function Pass($name) { Write-Output "  PASS  $name"; $script:Passed++ }
function Fail($name, $detail) { Write-Output "  FAIL  $name"; Write-Output "        $detail"; $script:Failed++ }
function Skip($name, $why) { Write-Output "  SKIP  $name - $why"; $script:Skipped++ }

# --- The stand-in provider --------------------------------------------------
$providerLog = Join-Path ([System.IO.Path]::GetTempPath()) "oauth-provider.log"
Remove-Item $providerLog -ErrorAction SilentlyContinue
$providerScript = Join-Path $repo "Scripts\oauth-probe\provider.py"
$provider = Start-Process -FilePath "python" -ArgumentList $providerScript `
    -RedirectStandardOutput $providerLog -NoNewWindow -PassThru

$providerPort = $null
foreach ($_ in 1..60) {
    if (Test-Path $providerLog) {
        $line = Select-String -Path $providerLog -Pattern "provider listening" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($line -and $line.Line -match "port=(\d+)") { $providerPort = $Matches[1]; break }
    }
    Start-Sleep -Milliseconds 250
}
if (-not $providerPort) {
    Write-Output "::error::the stand-in provider never started"
    if (Test-Path $providerLog) { Get-Content $providerLog }
    exit 1
}
$providerURL = "http://127.0.0.1:$providerPort"
Write-Output "-> stand-in provider on $providerURL"

function Stop-Probe2 {
    if ($provider -and -not $provider.HasExited) { Stop-Process -Id $provider.Id -Force -ErrorAction SilentlyContinue }
}

# --- Probe app --------------------------------------------------------------
$cleanupApp = $false
if (-not $AppDir) {
    $AppDir = Join-Path ([System.IO.Path]::GetTempPath()) "OAuthProbe"
    if (-not $Keep) { $cleanupApp = $true }
}
$cli = Join-Path $repo ".build\debug\swift-pwa.exe"

# The WebView2 + WIL SDK, as *flags*. Since Swift 6.4 made `swiftbuild` the
# default engine, `$env:INCLUDE` / `$env:LIB` are not passed to the tasks that
# need them, so a build that relies on the environment fails with
# `'wil/com.h' file not found` (see docs/windows-setup.md, which measured it).
# Default to a `packages\` dir beside the checkout; $env:SWIFT_PWA_WINDOWS_PACKAGES
# points at one somewhere else, e.g. a sibling checkout that already ran
# `nuget install`.
$packages = if ($env:SWIFT_PWA_WINDOWS_PACKAGES) { $env:SWIFT_PWA_WINDOWS_PACKAGES } else { Join-Path $repo "packages" }
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$sdkFlags = @()
if (Test-Path (Join-Path $packages "Microsoft.Web.WebView2")) {
    $sdkFlags = @(
        "-Xcc", "-I$packages\Microsoft.Web.WebView2\build\native\include",
        "-Xcc", "-I$packages\Microsoft.Windows.ImplementationLibrary\include",
        "-Xlinker", "/LIBPATH:$packages\Microsoft.Web.WebView2\build\native\$arch"
    )
    Write-Output "-> using the WebView2 / WIL SDK from $packages"
} else {
    Write-Output "-> no WebView2 / WIL packages at $packages - set SWIFT_PWA_WINDOWS_PACKAGES if the build fails"
}

Write-Output "-> building the CLI"
Push-Location $repo
swift build --product swift-pwa @sdkFlags 2>&1 | Out-Null
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
if ($patched -ne $source) {
    Set-Content -Path $manifest -Value $patched
    Write-Output "    repointed Package.swift at the working tree"
}

Copy-Item (Join-Path $repo "Scripts\oauth-probe\index.html") (Join-Path $AppDir "web\index.html") -Force

# Register the plugin. This is the whole adopter-facing line, on every platform
# - if it ever needs an `#if os(...)` around it, that is itself the regression.
$appSwift = Join-Path $AppDir ("Sources\" + (Split-Path -Leaf $AppDir) + "\App.swift")
$appSource = Get-Content $appSwift -Raw
if ($appSource -notmatch "AuthPlugin") {
    $registration = "    ctx.use(AuthPlugin(networkClient: URLSessionNetworkClient()))`r`n`r`n    "
    $appPatched = [regex]::Replace($appSource, '(?m)^\s*(_ = )?try ctx\.createWindow',
        ($registration + '$1try ctx.createWindow'), 1)
    if ($appPatched -eq $appSource) { Write-Error "couldn't find where to register AuthPlugin"; exit 1 }
    Set-Content -Path $appSwift -Value $appPatched
    Write-Output "    registered AuthPlugin"
}

Write-Output "-> building the probe app"
Push-Location $AppDir
swift build @sdkFlags 2>&1 | Tee-Object -Variable appBuildOutput | Out-Null
$built = $LASTEXITCODE
Pop-Location
if ($built -ne 0) {
    Write-Error "the probe app didn't build"
    $appBuildOutput | Select-String -Pattern "error" | Select-Object -Last 10 | ForEach-Object { Write-Output $_ }
    Stop-Probe2
    exit 1
}

$binary = Get-ChildItem (Join-Path $AppDir ".build") -Recurse -Filter "$(Split-Path -Leaf $AppDir).exe" |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $binary) { Write-Error "couldn't find the built probe binary"; exit 1 }

# --- Launch -----------------------------------------------------------------
$log = Join-Path ([System.IO.Path]::GetTempPath()) "oauth-probe.log"
Remove-Item $log -ErrorAction SilentlyContinue
$sessionId = (Get-Process -Id $PID).SessionId
$taskName = "SwiftPWAOAuthProbe"

# `/it` runs the task *as the interactive user*, which means there has to be
# one. A server sitting at the login screen has a connected console session with
# nobody on it, and the task then never starts — which without this check reads
# as "the app never printed its driver port", i.e. exactly like a broken app.
if ($sessionId -eq 0) {
    $loggedOn = @(quser 2>$null) | Where-Object { $_ -notmatch "^\s*USERNAME" -and $_.Trim() }
    if (-not $loggedOn) {
        Write-Output "  CONTROL  nobody is logged on at the console, so there is no interactive desktop"
        Write-Output "  SKIP  the whole flow - log in at the console (or run this from an RDP session) to verify it here"
        Write-Output ""
        Write-Output "  0 passed, 0 failed, 1 skipped"
        Stop-Probe2
        exit 0
    }
    Write-Output "-> session 0: launching the app on the interactive desktop via a scheduled task"
    $launcher = Join-Path ([System.IO.Path]::GetTempPath()) "oauth-launch.bat"
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
    if ($provider -and -not $provider.HasExited) { Stop-Process -Id $provider.Id -Force -ErrorAction SilentlyContinue }
    if ($cleanupApp) { Remove-Item $AppDir -Recurse -Force -ErrorAction SilentlyContinue }
}

if (-not $port -or -not $token) {
    Write-Output "::error::the app never printed its driver port"
    if (Test-Path $log) { Get-Content $log | Select-Object -First 20 }
    Stop-Probe
    exit 1
}

# `drive` warns on stderr whenever the target window isn't frontmost - true for
# every backgrounded run - so keep stdout clean.
function Invoke-Drive {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    & $cli drive @Args --attach $port --token $token 2>$null
}
function Get-Recorded {
    try { Invoke-RestMethod -Uri "$providerURL/recorded" -TimeoutSec 5 } catch { $null }
}

Write-Output "-> driving $(Split-Path -Leaf $binary) on windows (port $port)"

# --- CONTROL: can this box open a browser at all? ---------------------------
# Without this, a box with nobody logged in at the console reports the browser
# leg as a broken feature rather than as an environment it can't test.
Invoke-Drive eval "__probe.openControl('$providerURL/control')" | Out-Null
$browser = $false
# Generous, because this is a *cold* browser start.
foreach ($_ in 1..180) {
    $seen = Get-Recorded
    if ($seen -and $seen.control -gt 0) { $browser = $true; break }
    Start-Sleep -Milliseconds 250
}
if ($browser) {
    Write-Output "  CONTROL  the system browser opened a URL from this app"
} else {
    Write-Output "  CONTROL  no browser on this box - the browser leg will be SKIPped, not failed"
}

# --- authorize --------------------------------------------------------------
$redirect = $null; $state = $null; $verifier = $null
if (-not $browser) {
    Skip "authorize" "no system browser here"
} else {
    $args = "{authorizationEndpoint:'$providerURL/authorize',clientId:'probe-client',scopes:['read'],redirect:'loopback',timeoutMs:60000}"
    Invoke-Drive eval "__probe.authorize($args)" | Out-Null

    foreach ($_ in 1..180) {
        $seen = Get-Recorded
        if ($seen -and $seen.authorize.Count -gt 0) {
            $last = $seen.authorize[-1]
            $redirect = $last.redirect_uri
            $state = $last.state
            $method = $last.code_challenge_method
            $challenge = $last.code_challenge
            $responseType = $last.response_type
            break
        }
        Start-Sleep -Milliseconds 250
    }

    if (-not $redirect) {
        Fail "authorize" "the consent page never reached the provider (but the control did, so this is real)"
    } else {
        if ($responseType -eq "code" -and $state -and $method -eq "S256" -and $challenge) {
            Pass "the authorization request carries code/state/S256 challenge"
        } else {
            Fail "the authorization request carries code/state/S256 challenge" `
                "response_type=$responseType state=$state method=$method challenge=$challenge"
        }
        if ($redirect -like "http://127.0.0.1:*") {
            Pass "the redirect URI is an OS-assigned loopback port ($redirect)"
        } else {
            Fail "the redirect URI is loopback" $redirect
        }
    }
}

# --- wrong state ------------------------------------------------------------
if ($redirect) {
    $status = 0
    try { Invoke-WebRequest -Uri "$redirect`?code=attacker&state=not-the-one" -TimeoutSec 10 | Out-Null }
    catch { $status = [int]$_.Exception.Response.StatusCode }
    $snapshot = Invoke-Drive eval '__probe.snapshot()'
    # `drive eval` returns the page's value as a JSON *string*, so the snapshot
    # arrives with its quotes backslash-escaped (`{\"running\":true,...}`). Match
    # the escaped spelling too, or this reads as a failure while both conditions
    # it tests are actually satisfied.
    if ($status -eq 400 -and $snapshot -match 'running\\?":\s*true') {
        Pass "a callback with the wrong state is refused and the flow keeps waiting"
    } else {
        Fail "a callback with the wrong state is refused and the flow keeps waiting" "http=$status snapshot=$snapshot"
    }
}

# --- the real redirect ------------------------------------------------------
$grantCode = "probe-code-$(Get-Random)"
if ($redirect) {
    try { Invoke-WebRequest -Uri "$redirect`?code=$grantCode&state=$state" -TimeoutSec 10 | Out-Null } catch {}
    $snapshot = ""
    foreach ($_ in 1..40) {
        $snapshot = Invoke-Drive eval '__probe.snapshot()'
        if ($snapshot -match [regex]::Escape($grantCode)) { break }
        Start-Sleep -Milliseconds 250
    }
    if ($snapshot -match [regex]::Escape($grantCode)) {
        Pass "the page received the authorization code through the loopback receiver"
        if ($snapshot -match '"codeVerifier\\?":\\?"([A-Za-z0-9\-._~]+)') { $verifier = $Matches[1] }
    } else {
        Fail "the page received the authorization code" $snapshot
    }
}

# --- exchange ---------------------------------------------------------------
if ($redirect -and $verifier) {
    $args = "{tokenEndpoint:'$providerURL/token',clientId:'probe-client',code:'$grantCode',codeVerifier:'$verifier',redirectUri:'$redirect'}"
    $out = Invoke-Drive eval "__probe.exchange($args)"
    # The provider recomputes SHA256(verifier) and compares it to the challenge
    # the app sent at the start, so this passing means PKCE round-tripped for
    # real across two processes.
    if ($out -match "verified-access-token") {
        Pass "the token exchange round-tripped, PKCE verified by the provider"
    } else {
        Fail "the token exchange round-tripped" $out
    }
}

# --- timeout (the negative control) -----------------------------------------
# A run where nothing redirects MUST fail. Without it, every check above is
# equally consistent with a flow that resolves whatever it is handed.
if ($browser) {
    $args = "{authorizationEndpoint:'$providerURL/authorize',clientId:'probe-client',redirect:'loopback',timeoutMs:1500}"
    Invoke-Drive eval "__probe.authorize($args)" | Out-Null
    Start-Sleep -Seconds 3
    $out = Invoke-Drive eval '__probe.snapshot()'
    if ($out -match "E_AUTH_TIMEOUT") {
        Pass "a flow nothing redirects to times out with E_AUTH_TIMEOUT"
    } else {
        Fail "a flow nothing redirects to times out" $out
    }
}

Stop-Probe
Write-Output ""
Write-Output "  $script:Passed passed, $script:Failed failed, $script:Skipped skipped"
if ($script:Failed -gt 0) { exit 1 }
