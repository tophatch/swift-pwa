# End-to-end check that an app can vendor a native library with an API (#238),
# on Windows. The bash sibling (Scripts/verify-vendored-native-deps.sh) does the
# same for Android and Linux; the shape and the reasoning are documented there.
#
# Two runs, and the FIRST is the instrument's control: the same app, same
# vendored files, `native_include_dirs` removed, must fail with
# `'vendoredprobe.h' file not found`. A green control run means the header
# reached the compile some other way - a warm module cache, a global INCLUDE -
# and nothing the second run says can be trusted. Each run gets a fresh
# `.build`, because clang caches the built shim module across a change of
# include flags.
#
# The probe library is the SQLite amalgamation built and included under a name
# nothing else can provide, so no system-installed copy can satisfy the control.
#
# Run it on the box (see the Windows sync recipe in docs/windows-setup.md):
#   powershell -NoProfile -ExecutionPolicy Bypass `
#     -File Scripts\verify-vendored-native-deps.ps1 -Amalgamation C:\Users\<you>\sqlite
[CmdletBinding()]
param(
    # Directory holding the SQLite amalgamation (sqlite3.c + sqlite3.h).
    [Parameter(Mandatory = $true)][string]$Amalgamation,
    # Where the WebView2 / WIL NuGet packages live. The bundler finds them
    # itself from <app>\..\packages, which is why the probe app is scaffolded
    # inside the repo rather than in TEMP.
    [string]$Packages = "$env:USERPROFILE\swift-pwa\packages",
    # Keep the scaffolded app for debugging.
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'

# Every native build below runs through `cmd /c ... > log 2>&1` rather than a
# PowerShell pipeline. PowerShell routes a native command's stderr into the
# error stream, and under `Stop` a single swiftc *warning* then terminates the
# script - which reads exactly like a failed build.
function Invoke-Logged([string]$commandLine, [string]$log) {
    & cmd /c "$commandLine > `"$log`" 2>&1"
    return $LASTEXITCODE
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$app = 'VendoredDepApp'
$appDir = Join-Path $repo $app

if (-not (Test-Path (Join-Path $Amalgamation 'sqlite3.c'))) {
    Write-Error "no sqlite3.c in $Amalgamation - download sqlite-amalgamation-*.zip from sqlite.org"
}

# MSVC's dev environment, lifted into this session. Without it `swift build`
# dies at `'errno.h' file not found` (the Swift overlay can't find the UCRT),
# and neither `cl` nor `lib` is on PATH.
$vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) { Write-Error "no vcvars64.bat at $vcvars" }
cmd /c "call `"$vcvars`" >nul & set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
}

if (Test-Path $appDir) { Remove-Item -Recurse -Force $appDir }

# --- the vendored library, under a name nothing else provides ----------------

Write-Host '== building the probe library =='
$vendorInc = Join-Path $repo 'probe-include'
$vendorLib = Join-Path $repo 'probe-lib'
foreach ($d in @($vendorInc, $vendorLib)) {
    if (Test-Path $d) { Remove-Item -Recurse -Force $d }
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
Copy-Item (Join-Path $Amalgamation 'sqlite3.h') (Join-Path $vendorInc 'vendoredprobe.h')
Push-Location $vendorLib
try {
    # SQLITE_OMIT_LOAD_EXTENSION drops the dlopen path, which nothing here needs.
    $src = Join-Path $Amalgamation 'sqlite3.c'
    if ((Invoke-Logged "cl /nologo /c /Od /DSQLITE_OMIT_LOAD_EXTENSION `"$src`" /Foprobe.obj" 'cl.log') -ne 0) {
        Get-Content 'cl.log' -Tail 20 | Write-Host
        Write-Error 'cl failed on the amalgamation'
    }
    if ((Invoke-Logged 'lib /nologo /OUT:vendoredprobe.lib probe.obj' 'lib.log') -ne 0) {
        Get-Content 'lib.log' -Tail 20 | Write-Host
        Write-Error 'lib failed'
    }
} finally { Pop-Location }

# --- the app -----------------------------------------------------------------

Write-Host '== building the CLI =='
Push-Location $repo
try {
    if ((Invoke-Logged 'swift build --product swift-pwa' 'cli-build.log') -ne 0) {
        Get-Content 'cli-build.log' -Tail 30 | Write-Host
        Write-Error 'the CLI did not build'
    }
} finally { Pop-Location }
$cli = Join-Path $repo '.build\debug\swift-pwa.exe'
if (-not (Test-Path $cli)) { Write-Error "no CLI at $cli" }

Write-Host "== scaffolding $app =="
# A fresh `init` app, not an example: the examples carry resource declarations
# and Bundle.module fallbacks the scaffold never emits. Inside the repo, so the
# bundler's `<app>\..\packages` auto-detect finds the WebView2 / WIL headers.
Push-Location $repo
try {
    if ((Invoke-Logged "`"$cli`" init $app" 'init.log') -ne 0) {
        Get-Content 'init.log' -Tail 20 | Write-Host
        Write-Error 'swift-pwa init failed'
    }
} finally { Pop-Location }

if (-not (Test-Path (Join-Path $repo 'packages'))) {
    if (-not (Test-Path $Packages)) { Write-Error "no NuGet packages at $Packages" }
    Copy-Item -Recurse $Packages (Join-Path $repo 'packages')
}

# The scaffold pins the published release, so without this the run would verify
# the shipped backend rather than the working tree.
$pkgManifest = Join-Path $appDir 'Package.swift'
$text = Get-Content $pkgManifest -Raw
$repoEscaped = $repo -replace '\\', '\\'
$text = $text -replace '\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)', ".package(path: `"$repoEscaped`")"
$pkgName = Split-Path $repo -Leaf
$text = $text.Replace('package: "swift-pwa"', "package: `"$pkgName`"")

# The reported shape: a C target whose umbrella header includes the vendored
# header, which the app's Swift module imports.
$text = $text.Replace(
    "                .product(name: `"SwiftPWA`", package: `"$pkgName`"),",
    "                .product(name: `"SwiftPWA`", package: `"$pkgName`"),`n                `"CVendoredProbe`",")
$text = $text.Replace("        ),`r`n    ]`r`n)", @"
        ),
        .target(
            name: "CVendoredProbe",
            linkerSettings: [.linkedLibrary("vendoredprobe")]
        ),
    ]
)
"@)
$text = $text.Replace("        ),`n    ]`n)", @"
        ),
        .target(
            name: "CVendoredProbe",
            linkerSettings: [.linkedLibrary("vendoredprobe")]
        ),
    ]
)
"@)
Set-Content -Path $pkgManifest -Value $text -NoNewline
if ($text -notmatch 'CVendoredProbe') { Write-Error 'failed to add the C target to Package.swift' }

$shim = Join-Path $appDir 'Sources\CVendoredProbe'
New-Item -ItemType Directory -Force -Path (Join-Path $shim 'include') | Out-Null
Set-Content (Join-Path $shim 'include\shim.h') "#include <vendoredprobe.h>"
Set-Content (Join-Path $shim 'shim.c') '#include "include/shim.h"'

# Call into the library as well as including its header, so a green run proves
# both halves rather than just the compile.
Set-Content (Join-Path $appDir "Sources\$app\VendoredProbe.swift") @'
import CVendoredProbe
import Foundation

enum VendoredProbe {
    static var version: String { String(cString: sqlite3_libversion()) }
}
'@
$appSwiftPath = Join-Path $appDir "Sources\$app\App.swift"
$appSwift = Get-Content $appSwiftPath -Raw
$appSwift = $appSwift -replace '(?m)^    _ = try ctx\.createWindow\(', @'
    print("vendored probe " + VendoredProbe.version)

    _ = try ctx.createWindow(
'@.TrimEnd("`r", "`n")
Set-Content -Path $appSwiftPath -Value $appSwift -NoNewline

Copy-Item -Recurse $vendorInc (Join-Path $appDir 'Vendor-include')
Copy-Item -Recurse $vendorLib (Join-Path $appDir 'Vendor-lib')

function Write-Manifest([string]$mode) {
    $path = Join-Path $appDir 'pwa.json'
    $m = Get-Content $path -Raw | ConvertFrom-Json
    if (-not $m.PSObject.Properties['windows']) {
        $m | Add-Member -NotePropertyName windows -NotePropertyValue ([pscustomobject]@{})
    }
    $w = $m.windows
    $w | Add-Member -NotePropertyName native_library_dirs -NotePropertyValue @('Vendor-lib') -Force
    if ($mode -eq 'with-headers') {
        $w | Add-Member -NotePropertyName native_include_dirs -NotePropertyValue @('Vendor-include') -Force
    } elseif ($w.PSObject.Properties['native_include_dirs']) {
        $w.PSObject.Properties.Remove('native_include_dirs')
    }
    $m | ConvertTo-Json -Depth 20 | Set-Content -Path $path
}

function Build-Cold([string]$log) {
    # A genuinely cold clang module cache: the built `CVendoredProbe` module
    # survives a change of include flags, so anything short of wiping .build
    # confirms whatever it already believed.
    $b = Join-Path $appDir '.build'
    if (Test-Path $b) { Remove-Item -Recurse -Force $b }
    Push-Location $appDir
    try {
        return (Invoke-Logged "`"$cli`" build --target windows" $log)
    } finally { Pop-Location }
}

$controlLog = Join-Path $repo 'probe-control.log'
$subjectLog = Join-Path $repo 'probe-subject.log'

Write-Host ''
Write-Host '== control: native_library_dirs alone, cold module cache =='
Write-Manifest 'without-headers'
if ((Build-Cold $controlLog) -eq 0) {
    Write-Error @'
CONTROL FAILED: the build SUCCEEDED without native_include_dirs.
The header reached the compile some other way (a warm cache, a global INCLUDE).
This run proves nothing - fix the instrument before trusting the measurement.
'@
}
if (-not (Select-String -Path $controlLog -SimpleMatch "'vendoredprobe.h' file not found" -Quiet)) {
    Get-Content $controlLog -Tail 30 | Write-Host
    Write-Error 'CONTROL FAILED: the build failed, but not on the missing header.'
}
Write-Host "control ok - 'vendoredprobe.h' file not found, as it should be"

Write-Host ''
Write-Host '== subject: native_include_dirs added, cold module cache =='
Write-Manifest 'with-headers'
if ((Build-Cold $subjectLog) -ne 0) {
    Get-Content $subjectLog -Tail 40 | Write-Host
    Write-Error "FAILED: the build still doesn't reach the vendored header."
}

$exe = Get-ChildItem -Path (Join-Path $appDir 'build\windows') -Recurse -Filter "$app.exe" |
    Select-Object -First 1
if (-not $exe) {
    Get-Content $subjectLog -Tail 40 | Write-Host
    Write-Error 'FAILED: the build reported success but produced no .exe.'
}

# The compile succeeding isn't the whole claim, though on Windows a missing
# import library is already a hard link error (LNK1104). The library's own
# version string being in the image says the archive was pulled in, not just
# opened.
$version = (Select-String -Path (Join-Path $Amalgamation 'sqlite3.h') -Pattern '#define SQLITE_VERSION\s+"([^"]+)"').Matches[0].Groups[1].Value
$bytes = [System.IO.File]::ReadAllBytes($exe.FullName)
$ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
if (-not $ascii.Contains($version)) {
    Write-Error "FAILED: the app compiled, but the probe library's version string ($version) isn't in the .exe - the header reached the compile and the library didn't reach the link."
}

Write-Host ''
Write-Host 'PASS (windows)'
Write-Host "  control : 'vendoredprobe.h' file not found without native_include_dirs"
Write-Host '  subject : compiled against the vendored header, cold module cache'
Write-Host "  linked  : probe library $version present in the built image"
Write-Host "  packaged: $($exe.FullName)"

if (-not $Keep) {
    Remove-Item -Recurse -Force $appDir, $vendorInc, $vendorLib -ErrorAction SilentlyContinue
}
