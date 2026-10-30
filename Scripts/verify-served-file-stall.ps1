<#
.SYNOPSIS
  Check that a served file whose bytes aren't on local disk doesn't freeze the
  app while it downloads (#338), on Windows with OneDrive. The twin of
  Scripts/verify-served-file-stall.sh.

.DESCRIPTION
  A fresh scaffolded app serves a new folder under %OneDrive% holding two 6 MB
  files: remote.bin, made a cloud placeholder (attrib -P +U) so reading it
  downloads it, and local.bin. Its page (Scripts\served-file-stall-probe\)
  asks for remote.bin and then local.bin, and times a bridge round trip every
  50ms; each needs the app's UI thread.

  Rows:
    evicted   remote.bin is a placeholder. The worst round trip and local.bin's
              load time must stay well under remote.bin's download time.
    on disk   the same, once remote.bin has downloaded - the baseline.

  The evicted row is only evidence if remote.bin was a placeholder at launch
  (FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS) and took a while to arrive; a
  download faster than the threshold makes the row INCONCLUSIVE, not a pass.

  Launched through a scheduled task with /IT: an SSH session lands in Session
  0, where a WebView2 controller can't be created and OneDrive isn't running.
  The page writes its result to a file and quits.

.PARAMETER Released
  Build against the last release instead: the control, which should fail the
  evicted row.

.EXAMPLE
  powershell -File Scripts\verify-served-file-stall.ps1
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Packages,
    [string]$WorkDir = "$env:TEMP\swift-pwa-served-file-stall",
    [int]$ThresholdMs = 300,
    [switch]$Released,
    # Leave the OneDrive folder in place afterwards, to look at.
    [switch]$Keep
)

$ErrorActionPreference = "Stop"
if (-not $Repo) { $Repo = (Resolve-Path "$PSScriptRoot\..").Path }
if (-not $Packages) { $Packages = Join-Path $Repo "packages" }
if (-not $env:OneDrive) { throw "this needs OneDrive signed in (%OneDrive% is unset)" }
$appName = "ServeStallProbe"
$appDir = Join-Path $WorkDir $appName
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$placeholderBit = 0x400000 # FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS

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

function Test-Placeholder([string]$Path) { (([int](Get-Item $Path).Attributes) -band $placeholderBit) -ne 0 }

# Runs the app once in the logged-on user's session and returns the page's
# result, parsed.
function Invoke-Row([string]$Name) {
    $report = Join-Path $WorkDir "$Name.json"
    Remove-Item $report -ErrorAction SilentlyContinue
    $route = "/index.html?report=$([uri]::EscapeDataString($report))"
    $runner = Join-Path $WorkDir "$Name.cmd"
    Write-Utf8NoBom $runner ((@("@echo off", "cd /d `"$script:ExeDir`"",
        "set `"SERVE_PROBE_DIR=$script:Cloud`"",
        # %% in a .cmd file, or cmd expands the route's escapes as variables.
        "set `"SWIFT_PWA_INITIAL_ROUTE=$($route.Replace('%', '%%'))`"", "$appName.exe") -join "`r`n") + "`r`n")
    $task = "swift-pwa-served-file-stall-$Name"
    # Through cmd with output swallowed: PowerShell turns a native command's
    # stderr into a terminating error, and deleting a missing task writes some.
    cmd /c "schtasks /delete /tn $task /f >nul 2>&1"
    cmd /c "schtasks /create /tn $task /tr `"$runner`" /sc once /st 00:00 /it /f >nul 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "could not create the scheduled task (is a user logged on?)" }
    cmd /c "schtasks /run /tn $task >nul 2>&1"
    $deadline = (Get-Date).AddSeconds(120)
    while (-not (Test-Path $report) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    Start-Sleep -Seconds 2
    cmd /c "schtasks /end /tn $task >nul 2>&1"
    cmd /c "schtasks /delete /tn $task /f >nul 2>&1"
    if (-not (Test-Path $report)) { return $null }
    return [IO.File]::ReadAllText($report) | ConvertFrom-Json
}

Enter-BuildEnv
if (Test-Path $WorkDir) { cmd /c "rd /s /q `"\\?\$WorkDir`"" }
New-Item -ItemType Directory -Path $WorkDir | Out-Null

Write-Host "== building the CLI ==" -ForegroundColor Cyan
Push-Location $Repo
try {
    swift build --product swift-pwa @BuildFlags | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "CLI build failed" }
} finally { Pop-Location }
$cli = Join-Path $Repo ".build\debug\swift-pwa.exe"

Push-Location $WorkDir
try { & $cli init $appName | Out-Null } finally { Pop-Location }
if ($Released) {
    Write-Host "== scaffolded against the released package ==" -ForegroundColor Cyan
} else {
    Write-Host "== scaffolded against this checkout ==" -ForegroundColor Cyan
    $manifest = Join-Path $appDir "Package.swift"
    $text = [IO.File]::ReadAllText($manifest)
    $pin = '\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)'
    if ($text -notmatch $pin) { throw "the scaffold's package pin moved; this would test the released package" }
    Write-Utf8NoBom $manifest (($text -replace $pin, ".package(path: `"$($Repo.Replace('\', '/'))`")") `
        -replace 'package: "swift-pwa"', "package: `"$(Split-Path $Repo -Leaf)`"")
}
Copy-Item (Join-Path $Repo "Scripts\served-file-stall-probe\index.html") (Join-Path $appDir "web\index.html")
Copy-Item (Join-Path $Repo "Scripts\served-file-stall-probe\Probe.swift") (Join-Path $appDir "Sources\$appName\Probe.swift")
$appSwift = Join-Path $appDir "Sources\$appName\App.swift"
$text = [IO.File]::ReadAllText($appSwift)
$configure = '(?m)^func configure\(_ ctx: any AppContext\) throws \{\r?\n'
if ($text -notmatch $configure) { throw "the scaffold's configure moved; this patch needs updating" }
Write-Utf8NoBom $appSwift ($text -replace $configure, "func configure(_ ctx: any AppContext) throws {`n    registerServeProbe(ctx)`n")
# The bundler looks for the NuGet packages beside or above the project.
New-Item -ItemType Directory "$appDir\packages" | Out-Null
foreach ($pkg in "Microsoft.Web.WebView2", "Microsoft.Windows.ImplementationLibrary") {
    Copy-Item -Recurse -Path (Join-Path $Packages $pkg) -Destination "$appDir\packages\$pkg"
}
Write-Host "== building the app ==" -ForegroundColor Cyan
Push-Location $appDir
try {
    & $cli build --target windows --configuration debug | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "app build failed" }
} finally { Pop-Location }
$script:ExeDir = Join-Path $appDir "build\windows\$appName"

$script:Cloud = Join-Path $env:OneDrive "swift-pwa-served-file-stall-$(Get-Date -Format HHmmss)"
New-Item -ItemType Directory -Path $script:Cloud | Out-Null
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
foreach ($name in "remote.bin", "local.bin") {
    $bytes = New-Object byte[] 6291456
    $rng.GetBytes($bytes)
    [IO.File]::WriteAllBytes((Join-Path $script:Cloud $name), $bytes)
}
$remote = Join-Path $script:Cloud "remote.bin"

$pass = 0; $fail = 0; $inconclusive = 0
try {
    # Unpinning fails until OneDrive has uploaded a file, so keep asking.
    Write-Host "== waiting for OneDrive to upload remote.bin, then making it a placeholder ==" -ForegroundColor Cyan
    $deadline = (Get-Date).AddMinutes(5)
    do {
        cmd /c "attrib -P +U `"$remote`" >nul 2>&1"
        if (-not (Test-Placeholder $remote)) { Start-Sleep -Seconds 3 }
    } while (-not (Test-Placeholder $remote) -and (Get-Date) -lt $deadline)
    if (-not (Test-Placeholder $remote)) { throw "OneDrive never made remote.bin a placeholder" }

    foreach ($row in @(@{ Name = "evicted"; Want = "fast" }, @{ Name = "on-disk"; Want = "baseline" })) {
        if ($row.Want -eq "baseline" -and (Test-Placeholder $remote)) {
            Write-Host "  FAIL  on disk - remote.bin is still a placeholder after the app read it"; $fail++; continue
        }
        $r = Invoke-Row $row.Name
        if (-not $r) { Write-Host "  FAIL  $($row.Name) - the page never reported"; $fail++; continue }
        $line = "bridge worst $($r.worstBridgeMs) ms ($($r.rounds) rounds), local.bin at $($r.local.ms) ms, remote.bin at $($r.remote.ms) ms"
        $held = [Math]::Max([int]$r.worstBridgeMs, [int]$r.local.ms)
        if ($r.local.error -or $r.remote.error) {
            Write-Host "  FAIL  $($row.Name) - $line - $($r.local.error) $($r.remote.error)"; $fail++
        } elseif ($row.Want -eq "fast" -and [int]$r.remote.ms -lt $ThresholdMs) {
            Write-Host "  INCONCLUSIVE  $($row.Name) - $line - remote.bin arrived under $ThresholdMs ms, so nothing was slow"; $inconclusive++
        } elseif ($held -ge $ThresholdMs) {
            Write-Host "  FAIL  $($row.Name) - $line - the UI thread was held $held ms"; $fail++
        } else {
            Write-Host "  PASS  $($row.Name) - $line"; $pass++
        }
    }
} finally {
    if (-not $Keep) { cmd /c "rd /s /q `"$script:Cloud`" >nul 2>&1" }
}

Write-Host ""
Write-Host "$pass passed, $fail failed, $inconclusive inconclusive"
if ($fail -gt 0 -or $inconclusive -gt 0) { exit 1 }
