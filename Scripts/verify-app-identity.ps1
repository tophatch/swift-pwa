<#
.SYNOPSIS
  What a *bundled* Windows app is called at runtime, and so where
  `app.documentsDir` puts the user's files (#263).

.DESCRIPTION
  The Windows half of Scripts/verify-app-identity.sh. A Windows `.exe` has no
  Info.plist, so a bundled app answered its executable name — the SwiftPM
  target, which can't contain a space — and an app whose pwa.json says
  "Example Reader" put the user's library in `Documents\ExampleReader` while
  its macOS build used `Documents/Example Reader`. The bundler now writes the
  manifest name into the exe's version resource and the runtime reads it back.

  It scaffolds a fresh `swift-pwa init` app against this checkout (the examples
  are not the scaffold), renames it in pwa.json, and asks three launches where
  their documents and data directories are:

    bare         the `swift build` binary, which has no version resource. The
                 control: it must answer the executable name, which proves the
                 bundled legs measured the resource and not something baked in.
    folder       `swift-pwa build --target windows`.
    single-file  the same with `--single-file`, which has no pwa.json beside it.

  For the two bundled legs it also reads the exe's ProductName through
  PowerShell's own VersionInfo, independently of the runtime's reader, and
  checks the data directory did *not* move — every earlier release scoped it
  (and the WebView2 profile) by executable name, and moving it would strand a
  user's localStorage and IndexedDB.

  The probe answers from `configure`, before a window exists, so it runs from
  an SSH session without a desktop.

.PARAMETER Repo
  The swift-pwa checkout to build against. Default: this script's repo.

.PARAMETER Packages
  Directory holding the restored WebView2 + WIL NuGet packages. Default: the
  `packages` folder in -Repo.

.PARAMETER WorkDir
  Where the throwaway app is scaffolded. Wiped on each run.

.EXAMPLE
  powershell -File Scripts\verify-app-identity.ps1
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Packages,
    [string]$WorkDir = "$env:TEMP\spwa-identity"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
if (-not $Repo) { $Repo = (Resolve-Path "$PSScriptRoot\..").Path }
if (-not $Packages) { $Packages = Join-Path $Repo "packages" }

# Deliberately a name no real app has: asking for documentsDir creates the
# folder in the user's real Documents, and the cleanup below removes it.
$target = "SwiftPWAIdentityProbe"          # the SwiftPM target: no space is possible
$displayName = "SwiftPWA Identity Probe"   # what pwa.json calls it
$appDir = Join-Path $WorkDir $target
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }

function Enter-BuildEnv {
    $bat = if ($arch -eq 'arm64') { 'vcvarsarm64.bat' } else { 'vcvars64.bat' }
    $vcvars = Get-ChildItem "C:\Program Files*\Microsoft Visual Studio" -Recurse -Filter $bat `
        -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if (-not $vcvars) { throw "$bat not found - install VS Build Tools (docs/windows-setup.md section 2)." }
    cmd /c "call `"$vcvars`" >nul 2>&1 & set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
    }
    $wv2 = Join-Path $Packages "Microsoft.Web.WebView2\build\native"
    $wil = Join-Path $Packages "Microsoft.Windows.ImplementationLibrary\include"
    if (-not (Test-Path "$wv2\include")) { throw "WebView2 headers not at $wv2 - pass -Packages." }
    # Flags, not $env:INCLUDE / $env:LIB: Swift 6.4 passes neither on (#219).
    $script:BuildFlags = @("-Xcc", "-I$wv2\include", "-Xcc", "-I$wil", "-Xlinker", "/LIBPATH:$wv2\$arch")
}

# Remove-Item fails on the build tree: Swift's macro expansions have file
# names long enough to push the path past MAX_PATH. `rd` with the `\\?\`
# prefix doesn't have that limit.
function Remove-Tree([string]$Path) {
    if (Test-Path $Path) { cmd /c "rd /s /q `"\\?\$Path`"" }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    # A BOM hides `// swift-tools-version:` from SwiftPM.
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# Runs a native command, failing with its output rather than PowerShell's
# rendering of the first stderr line as a terminating error.
function Invoke-Native([string]$Label, [scriptblock]$Command) {
    $ErrorActionPreference = "Continue"
    # A native stderr line arrives as an ErrorRecord whose TargetObject is the
    # line; an empty one otherwise prints as "RemoteException".
    $out = & $Command 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { "$($_.TargetObject)" } else { "$_" }
    }
    if ($LASTEXITCODE -ne 0) {
        # The last lines are swiftc's frontend command, kilobytes long; the
        # diagnostics are what's worth reading.
        $out | Where-Object { $_ -match 'error:' -and $_ -notmatch 'frontend' } |
            Select-Object -First 15 | ForEach-Object { Write-Host $_ }
        throw "$Label failed ($LASTEXITCODE)"
    }
}

function Get-Identity([string]$Exe) {
    $report = Join-Path $WorkDir "identity.json"
    Remove-Item $report -ErrorAction SilentlyContinue
    $env:PROBE_IDENTITY_REPORT = $report
    try {
        $ErrorActionPreference = "Continue"
        & $Exe 2>&1 | Out-Null
    } finally {
        Remove-Item Env:PROBE_IDENTITY_REPORT
        $ErrorActionPreference = "Stop"
    }
    if (-not (Test-Path $report)) { throw "$Exe wrote no report (exit $LASTEXITCODE)" }
    Get-Content $report -Raw | ConvertFrom-Json
}

$script:failed = $false
$script:touched = @()
function Test-Leg([string]$Label, [string]$Exe, [string]$WantName, [bool]$Bundled) {
    if (-not (Test-Path $Exe)) { throw "$Label : no exe at $Exe" }
    $identity = Get-Identity $Exe
    $script:touched += $identity.docs, $identity.data
    $docsLeaf = Split-Path $identity.docs -Leaf
    $dataLeaf = Split-Path $identity.data -Leaf
    $problems = @()
    if ($docsLeaf -ne $WantName) { $problems += "documentsDir leaf '$docsLeaf', wanted '$WantName'" }
    # The data directory keeps the executable name on every leg.
    if ($dataLeaf -ne $target) { $problems += "dataDir leaf '$dataLeaf' moved from '$target'" }
    if ($Bundled) {
        $info = (Get-Item $Exe).VersionInfo
        if ($info.ProductName -ne $displayName) { $problems += "VersionInfo.ProductName '$($info.ProductName)'" }
        if ($info.FileDescription -ne $displayName) { $problems += "VersionInfo.FileDescription '$($info.FileDescription)'" }
    }
    if ($problems.Count -eq 0) {
        Write-Host ("PASS  {0,-12} documentsDir={1}   dataDir={2}" -f $Label, $identity.docs, $identity.data) -ForegroundColor Green
    } else {
        Write-Host ("FAIL  {0,-12} {1}" -f $Label, ($problems -join '; ')) -ForegroundColor Red
        $script:failed = $true
    }
}

Enter-BuildEnv
Remove-Tree $WorkDir
New-Item -ItemType Directory -Path $WorkDir | Out-Null

try {
    Write-Host "== building the CLI ==" -ForegroundColor Cyan
    Push-Location $Repo
    try { Invoke-Native "CLI build" { swift build --product swift-pwa @BuildFlags } } finally { Pop-Location }
    $cli = Join-Path $Repo ".build\debug\swift-pwa.exe"

    Write-Host "== scaffolding $target, renamed to `"$displayName`" in pwa.json ==" -ForegroundColor Cyan
    Push-Location $WorkDir
    try { Invoke-Native "init" { & $cli init $target } } finally { Pop-Location }

    $manifest = Join-Path $appDir "Package.swift"
    $repoForSwift = $Repo.Replace('\', '/')
    $repoLeaf = Split-Path $Repo -Leaf
    # A path dependency is named after its directory, so the product reference
    # has to follow a checkout that isn't called swift-pwa.
    Write-Utf8NoBom $manifest (([IO.File]::ReadAllText($manifest) `
        -replace '\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)', ".package(path: `"$repoForSwift`")") `
        -replace 'package: "swift-pwa"', "package: `"$repoLeaf`"")

    # The bundler looks for the NuGet packages beside or above the project,
    # and a scaffold in %TEMP% has neither. A copy rather than a junction:
    # the cleanup's recursive delete must not be able to reach the originals.
    New-Item -ItemType Directory "$appDir\packages" | Out-Null
    foreach ($pkg in "Microsoft.Web.WebView2", "Microsoft.Windows.ImplementationLibrary") {
        Copy-Item -Recurse -Path (Join-Path $Packages $pkg) -Destination "$appDir\packages\$pkg"
    }

    $pwa = Join-Path $appDir "pwa.json"
    $m = Get-Content $pwa -Raw | ConvertFrom-Json
    $m.name = $displayName
    Write-Utf8NoBom $pwa ($m | ConvertTo-Json -Depth 20)

    # The probe: report where this launch's folders are, then leave before a
    # window is created. Behind an env var so the app is otherwise the scaffold.
    Write-Utf8NoBom (Join-Path $appDir "Sources\$target\Probe.swift") @"
import Foundation
import SwiftPWA

@MainActor
func reportIdentityIfAsked(_ ctx: any AppContext) {
    guard let path = ProcessInfo.processInfo.environment["PROBE_IDENTITY_REPORT"] else { return }
    let report = ["docs": ctx.documentsDirectory().path, "data": ctx.dataDirectory().path]
    let json = try! JSONSerialization.data(withJSONObject: report)
    try! json.write(to: URL(fileURLWithPath: path))
    exit(0)
}
"@
    $appSwift = Join-Path $appDir "Sources\$target\App.swift"
    $src = [IO.File]::ReadAllText($appSwift)
    $marker = "func configure(_ ctx: any AppContext) throws {"
    if (-not $src.Contains($marker)) { throw "the scaffold's configure function moved; this probe needs updating" }
    $i = $src.IndexOf($marker) + $marker.Length
    Write-Utf8NoBom $appSwift ($src.Substring(0, $i) + "`n            reportIdentityIfAsked(ctx)" + $src.Substring($i))

    Push-Location $appDir
    try {
        Write-Host "== building ==" -ForegroundColor Cyan
        Invoke-Native "app build" { swift build @BuildFlags }
        Invoke-Native "folder bundle" { & $cli build --target windows }
        $folderExe = Join-Path $appDir "build\windows\$displayName\$target.exe"
        # The single-file build replaces the folder, so measure it first.
        Test-Leg "bare" (Join-Path $appDir ".build\debug\$target.exe") $target $false
        Test-Leg "folder" $folderExe $displayName $true
        Invoke-Native "single-file bundle" { & $cli build --target windows --single-file }
        Test-Leg "single-file" (Join-Path $appDir "build\windows\$target.exe") $displayName $true
    } finally { Pop-Location }
} finally {
    # Asking for the folders created them. Remove each only while empty, so a
    # same-named folder of someone's own survives. OneDrive marks a new folder
    # in a redirected Documents read-only, and Windows won't remove a read-only
    # directory, so clear that first; a delete that still fails is worth a
    # line, not a failed run.
    foreach ($dir in ($script:touched | Sort-Object -Unique)) {
        if ((Test-Path $dir) -and -not (Get-ChildItem $dir -Force)) {
            try {
                $item = Get-Item $dir -Force
                $item.Attributes = $item.Attributes -band -bnot [IO.FileAttributes]::ReadOnly
                [IO.Directory]::Delete($dir)
            }
            catch { Write-Host "note: couldn't remove the empty $dir ($($_.Exception.Message.Trim())) - remove it by hand" }
        }
    }
    Remove-Tree $WorkDir
}

if ($script:failed) { exit 1 }
Write-Host "All identity checks passed." -ForegroundColor Green
