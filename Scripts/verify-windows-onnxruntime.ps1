<#
.SYNOPSIS
  Does a Windows app that opts into `ai.local_onnx_runtime` link and load ONNX
  Runtime for *this* box's architecture (#262)?

.DESCRIPTION
  The resolver picks a pinned `onnxruntime.lib` / `onnxruntime.dll` pair per
  architecture. Until #262 it had only the x64 pair, and an arm64 host
  downloaded it and failed at the link with `machine type x64 conflicts with
  arm64` - an error that names no fix. Nothing in CI builds this tier on arm64,
  so run this on each Windows architecture after touching
  `OnnxRuntimeWindowsArtifact` or bumping the runtime.

  It scaffolds a fresh `swift-pwa init` app against this checkout, makes it link
  `SwiftPWAONNX` and set `ai.local_onnx_runtime`, builds it with
  `swift-pwa build --target windows` - the path that resolves and stages the
  pair - and then checks three things:

    staged   onnxruntime.dll sits beside the exe, and its PE machine type is
             this box's architecture (dumpbin's own reading, not ours).
    loaded   the bundled exe's `OrtRuntime.shared` is non-nil, which needs the
             DLL to load, serve the API version the committed headers ask for,
             and create an environment.

  The probe answers from `configure`, before a window exists, so it runs from
  an SSH session without a desktop.

.PARAMETER Repo
  The swift-pwa checkout to build against. Default: this script's repo.

.PARAMETER Packages
  Directory holding the restored WebView2 + WIL NuGet packages. Default: the
  `packages` folder in -Repo.

.PARAMETER LocalPair
  A directory holding `onnxruntime.lib` + `onnxruntime.dll` to place in the
  app's `Vendor\onnxruntime-desktop\windows-<arch>\`, exercising the resolver's
  local-vendor step instead of the download.

.PARAMETER WorkDir
  Where the throwaway app is scaffolded. Wiped on each run.
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Packages,
    [string]$LocalPair = "",
    [string]$WorkDir = "$env:TEMP\spwa-ort"
)

$ErrorActionPreference = "Stop"
if (-not $Repo) { $Repo = (Resolve-Path "$PSScriptRoot\..").Path }
if (-not $Packages) { $Packages = Join-Path $Repo "packages" }

$target = "SwiftPWAOrtProbe"
$appDir = Join-Path $WorkDir $target
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$archDir = if ($arch -eq 'arm64') { 'windows-arm64' } else { 'windows-x86_64' }
$expectedMachine = if ($arch -eq 'arm64') { 'AA64' } else { '8664' }

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

# Swift's macro expansions push a build tree past MAX_PATH, which Remove-Item
# can't delete; `rd` with the `\\?\` prefix can.
function Remove-Tree([string]$Path) {
    if (Test-Path $Path) { cmd /c "rd /s /q `"\\?\$Path`"" }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Native([string]$Label, [scriptblock]$Command) {
    $ErrorActionPreference = "Continue"
    $out = & $Command 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { "$($_.TargetObject)" } else { "$_" }
    }
    if ($LASTEXITCODE -ne 0) {
        $out | Where-Object { $_ -match 'error' -and $_ -notmatch 'frontend' } |
            Select-Object -First 15 | ForEach-Object { Write-Host $_ }
        throw "$Label failed ($LASTEXITCODE)"
    }
    $out
}

$failed = $false
function Report([bool]$Ok, [string]$Label, [string]$Detail) {
    if ($Ok) { Write-Host ("PASS  {0,-8} {1}" -f $Label, $Detail) -ForegroundColor Green }
    else { Write-Host ("FAIL  {0,-8} {1}" -f $Label, $Detail) -ForegroundColor Red; $script:failed = $true }
}

Enter-BuildEnv
Remove-Tree $WorkDir
New-Item -ItemType Directory -Path $WorkDir | Out-Null

try {
    Write-Host "== building the CLI ($arch) ==" -ForegroundColor Cyan
    Push-Location $Repo
    try { Invoke-Native "CLI build" { swift build --product swift-pwa @BuildFlags } | Out-Null } finally { Pop-Location }
    $cli = Join-Path $Repo ".build\debug\swift-pwa.exe"

    Push-Location $WorkDir
    try { Invoke-Native "init" { & $cli init $target } | Out-Null } finally { Pop-Location }

    # Point the scaffold at this checkout and link the ONNX tier.
    $manifest = Join-Path $appDir "Package.swift"
    $repoForSwift = $Repo.Replace('\', '/')
    $repoLeaf = Split-Path $Repo -Leaf
    $src = [IO.File]::ReadAllText($manifest) `
        -replace '\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)', ".package(path: `"$repoForSwift`")" `
        -replace 'package: "swift-pwa"', "package: `"$repoLeaf`""
    $product = '.product(name: "SwiftPWA", package: "' + $repoLeaf + '")'
    if (-not $src.Contains($product)) { throw "the scaffold's product dependency moved; this probe needs updating" }
    $src = $src.Replace($product, $product + ",`n                .product(name: `"SwiftPWAONNX`", package: `"$repoLeaf`")")
    Write-Utf8NoBom $manifest $src

    $pwa = Join-Path $appDir "pwa.json"
    $m = Get-Content $pwa -Raw | ConvertFrom-Json
    $m | Add-Member -NotePropertyName ai -NotePropertyValue ([pscustomobject]@{ local_onnx_runtime = $true }) -Force
    Write-Utf8NoBom $pwa ($m | ConvertTo-Json -Depth 20)

    # The bundler looks for the NuGet packages beside or above the project.
    # Copies, not junctions: the cleanup's recursive delete must not reach them.
    New-Item -ItemType Directory "$appDir\packages" | Out-Null
    foreach ($pkg in "Microsoft.Web.WebView2", "Microsoft.Windows.ImplementationLibrary") {
        Copy-Item -Recurse -Path (Join-Path $Packages $pkg) -Destination "$appDir\packages\$pkg"
    }
    if ($LocalPair) {
        $dest = New-Item -ItemType Directory -Force "$appDir\Vendor\onnxruntime-desktop\$archDir"
        Copy-Item (Join-Path $LocalPair "onnxruntime.lib"), (Join-Path $LocalPair "onnxruntime.dll") $dest
        Write-Host "   using the local pair in Vendor\onnxruntime-desktop\$archDir"
    }

    Write-Utf8NoBom (Join-Path $appDir "Sources\$target\Probe.swift") @"
import Foundation
import SwiftPWA
import SwiftPWAONNX

@MainActor
func reportOrtIfAsked() {
    guard let path = ProcessInfo.processInfo.environment["PROBE_ORT_REPORT"] else { return }
    let report = ["loaded": OrtRuntime.shared != nil ? "yes" : "no"]
    try! JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: path))
    exit(0)
}
"@
    $appSwift = Join-Path $appDir "Sources\$target\App.swift"
    $src = [IO.File]::ReadAllText($appSwift)
    $marker = "func configure(_ ctx: any AppContext) throws {"
    if (-not $src.Contains($marker)) { throw "the scaffold's configure function moved; this probe needs updating" }
    $i = $src.IndexOf($marker) + $marker.Length
    Write-Utf8NoBom $appSwift ($src.Substring(0, $i) + "`n            reportOrtIfAsked()" + $src.Substring($i))

    Push-Location $appDir
    try {
        Write-Host "== bundling ==" -ForegroundColor Cyan
        Invoke-Native "bundle" { & $cli build --target windows } | Select-String "onnxruntime" | ForEach-Object { "   $_" }
    } finally { Pop-Location }

    $bundle = Join-Path $appDir "build\windows\$($m.name)"
    $exe = Join-Path $bundle "$target.exe"
    $dll = Join-Path $bundle "onnxruntime.dll"
    if (-not (Test-Path $dll)) {
        Report $false "staged" "no onnxruntime.dll beside $exe"
    } else {
        $headers = (dumpbin /nologo /headers $dll) -join "`n"
        $machine = [regex]::Match($headers, '([0-9A-F]{3,4}) machine').Groups[1].Value
        Report ($machine -eq $expectedMachine) "staged" "onnxruntime.dll machine $machine (want $expectedMachine for $arch)"
    }

    $reportPath = Join-Path $WorkDir "ort.json"
    $env:PROBE_ORT_REPORT = $reportPath
    try {
        $ErrorActionPreference = "Continue"
        & $exe 2>&1 | Out-Null
        $code = $LASTEXITCODE
    } finally { Remove-Item Env:PROBE_ORT_REPORT; $ErrorActionPreference = "Stop" }
    if (-not (Test-Path $reportPath)) {
        Report $false "loaded" ("the exe wrote no report (exit 0x{0:X8})" -f $code)
    } else {
        $r = Get-Content $reportPath -Raw | ConvertFrom-Json
        Report ($r.loaded -eq "yes") "loaded" "OrtRuntime.shared: $($r.loaded)"
    }
} finally {
    Remove-Tree $WorkDir
}

if ($failed) { exit 1 }
Write-Host "ONNX Runtime links and loads for $arch." -ForegroundColor Green
