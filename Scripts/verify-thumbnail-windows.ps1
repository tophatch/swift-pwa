<#
.SYNOPSIS
  Verify fs.thumbnail on Windows (#320). The twin of Scripts/verify-thumbnail.sh.

.DESCRIPTION
  The rows are the probe page's (Scripts/thumbnail-probe/index.html): a PDF, a
  PNG and a file of an unknown type in the app's cache, and a missing path.
  Windows has no PDF thumbnailer of its own, so a PDF passes as page one or as
  null; a reader that installs a thumbnail handler (Acrobat, PowerToys) makes
  it page one.

  With -OneDrive, the probe files are also written into a fresh folder under
  %OneDrive%, uploaded, and made into cloud placeholders (attrib +U -P). Each
  then has to give a thumbnail or null and still be a placeholder afterwards
  (FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS) - the shell never downloads one to
  draw it, and listing the folder mustn't either. Then fs.remove deletes a
  30 MB placeholder, which has to cost well under 30 MB received (summed over
  every network adapter): Foundation's fileExists downloaded it first.

  Launched through a scheduled task with /IT: an SSH session lands in Session
  0, where a WebView2 controller can't be created and OneDrive isn't running.
  The page writes its rows to a file and quits.

.PARAMETER Repo
  The swift-pwa checkout to build against. Default: this script's repo.

.PARAMETER Packages
  Directory holding the restored WebView2 + WIL NuGet packages. Default: the
  `packages` folder in -Repo.

.PARAMETER Released
  Build against the last release instead: the control, where every thumbnail
  row has to fail (there is no fs.thumbnail).

.EXAMPLE
  powershell -File Scripts\verify-thumbnail-windows.ps1 -OneDrive
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Packages,
    [string]$WorkDir = "$env:TEMP\swift-pwa-thumbnail",
    [switch]$OneDrive,
    [switch]$Released,
    # Leave the OneDrive folder in place afterwards, to look at.
    [switch]$Keep
)

$ErrorActionPreference = "Stop"
if (-not $Repo) { $Repo = (Resolve-Path "$PSScriptRoot\..").Path }
if (-not $Packages) { $Packages = Join-Path $Repo "packages" }
$appName = "ThumbProbe"
$appDir = Join-Path $WorkDir $appName
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

# Runs the app once in the logged-on user's session at /index.html?<query>,
# waits for it to quit, and returns what the page wrote to the report file.
function Invoke-Page([string]$Name, [string]$Query) {
    $report = Join-Path $WorkDir "$Name.txt"
    Remove-Item $report -ErrorAction SilentlyContinue
    $route = "/index.html?$Query&report=$([uri]::EscapeDataString($report))"
    $runner = Join-Path $WorkDir "$Name.cmd"
    Write-Utf8NoBom $runner ((@("@echo off", "cd /d `"$script:ExeDir`"",
        # %% in a .cmd file, or cmd expands the route's escapes as variables.
        "set `"SWIFT_PWA_INITIAL_ROUTE=$($route.Replace('%', '%%'))`"", "$appName.exe") -join "`r`n") + "`r`n")
    $task = "swift-pwa-thumbnail-$Name"
    # Through cmd with output swallowed: PowerShell turns a native command's
    # stderr into a terminating error, and deleting a missing task writes some.
    cmd /c "schtasks /delete /tn $task /f >nul 2>&1"
    cmd /c "schtasks /create /tn $task /tr `"$runner`" /sc once /st 00:00 /it /f >nul 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "could not create the scheduled task (is a user logged on?)" }
    cmd /c "schtasks /run /tn $task >nul 2>&1"
    $deadline = (Get-Date).AddSeconds(180)
    while (-not (Test-Path $report) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    Start-Sleep -Seconds 2
    cmd /c "schtasks /end /tn $task >nul 2>&1"
    cmd /c "schtasks /delete /tn $task /f >nul 2>&1"
    if (-not (Test-Path $report)) { throw "the page never reported (launch $Name)" }
    return [IO.File]::ReadAllText($report)
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
Copy-Item (Join-Path $Repo "Scripts\thumbnail-probe\index.html") (Join-Path $appDir "web\index.html")
Copy-Item (Join-Path $Repo "Scripts\thumbnail-probe\Probe.swift") (Join-Path $appDir "Sources\$appName\Probe.swift")
$appSwift = Join-Path $appDir "Sources\$appName\App.swift"
$text = [IO.File]::ReadAllText($appSwift)
if ($text -notmatch '(?m)^    _ = try ctx\.createWindow\(') { throw "the scaffold's createWindow call moved" }
Write-Utf8NoBom $appSwift ($text -replace '(?m)^    _ = try ctx\.createWindow\(', "    registerProbes(ctx)`n`n    _ = try ctx.createWindow(")
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

$query = "run=1"
$cloud = $null
if ($OneDrive) {
    if (-not $env:OneDrive) { throw "-OneDrive needs OneDrive signed in (%OneDrive% is unset)" }
    $cloud = Join-Path $env:OneDrive "swift-pwa-thumbprobe-$(Get-Date -Format HHmmss)"
    New-Item -ItemType Directory -Path $cloud | Out-Null
    Write-Host "== seeding $cloud ==" -ForegroundColor Cyan
    Invoke-Page "seed" "seed=$([uri]::EscapeDataString($cloud))" | Out-Null
    # Random, so it can't compress: removing it must not cost its size.
    $bulk = Join-Path $WorkDir "remove-me.bin"
    $bytes = New-Object byte[] (30MB)
    (New-Object Random).NextBytes($bytes)
    [IO.File]::WriteAllBytes($bulk, $bytes)
    $removeMe = Join-Path $cloud "remove-me.bin"
    Move-Item $bulk $removeMe
    # Unpinning fails until OneDrive has uploaded a file, so keep asking.
    Write-Host "== waiting for OneDrive to upload, then making placeholders ==" -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds(600)
    do {
        Get-ChildItem $cloud -File | ForEach-Object { cmd /c "attrib -P +U `"$($_.FullName)`" >nul 2>&1" }
        Start-Sleep -Seconds 4
        $local = @(Get-ChildItem $cloud -File | Where-Object { ([int]$_.Attributes -band 0x400000) -eq 0 })
    } while ($local.Count -gt 0 -and (Get-Date) -lt $deadline)
    if ($local.Count -gt 0) { throw "OneDrive never made placeholders of: $($local.Name -join ', ')" }
    $query += "&folder=$([uri]::EscapeDataString($cloud))"
}

function Get-Received { (Get-NetAdapterStatistics | Measure-Object -Property ReceivedBytes -Sum).Sum }

try {
    Write-Host "== running the probe page ==" -ForegroundColor Cyan
    $rows = Invoke-Page "run" $query
    if ($cloud) {
        # A placeholder again, whatever the listing did to it, so this row
        # measures fs.remove alone.
        $deadline = (Get-Date).AddSeconds(120)
        do {
            cmd /c "attrib -P +U `"$removeMe`" >nul 2>&1"
            Start-Sleep -Seconds 3
        } while ((([int](Get-Item $removeMe).Attributes) -band 0x400000) -eq 0 -and (Get-Date) -lt $deadline)
        if ((([int](Get-Item $removeMe).Attributes) -band 0x400000) -eq 0) { throw "remove-me.bin never went back to a placeholder" }
        $before = Get-Received
        $removed = (Invoke-Page "remove" "remove=$([uri]::EscapeDataString($removeMe))").Trim()
        $received = (Get-Received) - $before
        $ok = ($removed -like 'removed*') -and -not (Test-Path $removeMe) -and $received -lt 3MB
        $rows += "$(if ($ok) { 'PASS' } else { 'FAIL' }) fs.remove deletes a 30 MB placeholder without downloading it - $removed; received $received bytes`n"
    }
    Write-Host $rows
} finally {
    if ($cloud -and -not $Keep) { cmd /c "rd /s /q `"$cloud`"" }
}
if ($rows -match '(?m)^PASS' -and $rows -notmatch '(?m)^FAIL') {
    Write-Host "PASS: every row held." -ForegroundColor Green
    exit 0
}
Write-Host "FAIL: see above." -ForegroundColor Red
exit 1
