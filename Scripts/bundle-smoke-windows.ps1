<#
.SYNOPSIS
  Bundle a fresh `swift-pwa init` app for Windows through the CLI, move the
  bundle away from the build, and check it starts (#239).

.DESCRIPTION
  The Windows counterpart of CI's bundle-smoke jobs. Nothing else in CI runs
  `swift-pwa build --target windows`, and two faults shipped through that gap:
  the headless catalog dump every build runs couldn't find the WebView2 / WIL
  headers under Swift 6.4 (no Windows build could complete at all), and an app
  declaring native_library_dirs crashed SwiftPM (#238).

  Weaker than the macOS and Linux jobs, on purpose: they drive their app, and
  this can't. WebView2 won't create a controller without an interactive
  desktop, and neither an SSH session nor (as far as anyone has measured) a
  hosted runner has one. So each bundle is launched with SWIFT_PWA_DESCRIBE,
  which loads the exe from its bundle folder, runs the app's `configure`,
  writes the command catalog and exits before any window. That catches a
  bundle that can't load (a missing DLL), can't find what it staged, or
  whose build broke; it can't catch anything in WebView2 or the page.

  Three launches:

    folder-control   the folder bundle with PATH as it is. Has to pass, or
                     the portable launch proves nothing.
    folder-portable  the same with only Windows on PATH, as on a user's
                     machine with no Swift toolchain: the bundle has to carry
                     the Swift runtime itself. Without it, this died
                     "FoundationNetworking.dll was not found".
    single-control   the `--single-file` exe with PATH as it is. There is no
                     portable leg for it: the loader can't take a DLL from
                     inside the exe, so a single file can't carry the runtime.

  A GUI-subsystem exe that can't load a DLL doesn't exit - csrss shows a
  "System Error" dialog and waits for a click - so a launch that hangs lists
  the windows on screen and saves a screenshot, and a failed portable launch
  reruns a console-subsystem copy, which does exit, with the loader's status.

  The app is scaffolded against this checkout (the examples are not the
  scaffold), and the bundles are moved out of the project and its .build
  deleted before either launch, so nothing can be read from the build tree.

.PARAMETER Repo
  The swift-pwa checkout to build against. Default: this script's repo.

.PARAMETER Packages
  Directory holding the restored WebView2 + WIL NuGet packages. Default: the
  `packages` folder in -Repo.

.PARAMETER WorkDir
  Where the throwaway app is scaffolded. Wiped on each run.

.PARAMETER Configuration
  release (default: what an adopter ships) or debug.

.EXAMPLE
  powershell -File Scripts\bundle-smoke-windows.ps1 -Packages C:\src\swift-pwa\packages
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Packages,
    [string]$WorkDir = "$env:TEMP\spwa-bundle-smoke",
    [ValidateSet("release", "debug")] [string]$Configuration = "release"
)

$ErrorActionPreference = "Stop"
if (-not $Repo) { $Repo = (Resolve-Path "$PSScriptRoot\..").Path }
if (-not $Packages) { $Packages = Join-Path $Repo "packages" }

$target = "BundleSmoke"
$appDir = Join-Path $WorkDir $target
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }

function Enter-BuildEnv {
    # CI loads the MSVC environment in an earlier step; a bare SSH shell hasn't.
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

# Remove-Item fails on a 6.4 build tree: macro-expansion file names push the
# path past MAX_PATH. `rd` with the `\\?\` prefix doesn't have that limit.
function Remove-Tree([string]$Path) {
    if (Test-Path $Path) { cmd /c "rd /s /q `"\\?\$Path`"" }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    # A BOM hides `// swift-tools-version:` from SwiftPM.
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# Runs a native command with its output streaming, failing on its exit code
# rather than on PowerShell's reading of the first stderr line as an error.
function Invoke-Native([string]$Label, [scriptblock]$Command) {
    $ErrorActionPreference = "Continue"
    & $Command 2>&1 | ForEach-Object {
        # A native stderr line arrives as an ErrorRecord; print the line.
        if ($_ -is [System.Management.Automation.ErrorRecord]) { "$($_.TargetObject)" } else { "$_" }
    } | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "$Label failed ($LASTEXITCODE)" }
}

# Launch `$Exe` in describe mode and return a verdict. The exe is a GUI-subsystem
# binary, so PowerShell wouldn't wait for it: Start-Process -Wait does, and
# hands back the exit code. It inherits this process's environment, which is
# how PATH and SWIFT_PWA_DESCRIBE reach it.
# What is on screen while a launch hangs: every top-level window's owner and
# title (a loader or CRT dialog would show here), and a screenshot of the
# desktop, which also answers whether this machine has one to draw on.
function Save-HangEvidence([string]$Label) {
    Get-Process | Where-Object { $_.MainWindowTitle } |
        ForEach-Object { Write-Host ("  window: {0} (pid {1}): {2}" -f $_.ProcessName, $_.Id, $_.MainWindowTitle) }
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $shot = Join-Path $WorkDir "hang-$Label.png"
        $bitmap.Save($shot)
        Write-Host "  screenshot: $shot ($($bounds.Width)x$($bounds.Height))"
    } catch {
        Write-Host "  screenshot failed: $($_.Exception.Message)"
    }
}

function Test-Launch([string]$Label, [string]$Exe, [string]$PathValue) {
    $catalog = Join-Path $WorkDir "catalog-$Label.json"
    Remove-Item $catalog -ErrorAction SilentlyContinue
    $savedPath = $env:Path
    $env:Path = $PathValue
    $env:SWIFT_PWA_DESCRIBE = $catalog
    try {
        $process = Start-Process -FilePath $Exe -WorkingDirectory $WorkDir -PassThru -WindowStyle Hidden
        if (-not $process.WaitForExit(120000)) {
            Save-HangEvidence $Label
            $process.Kill()
            return "FAIL  $Label - still running after 120 s"
        }
        $code = $process.ExitCode
    } finally {
        $env:Path = $savedPath
        Remove-Item Env:SWIFT_PWA_DESCRIBE
    }
    # 0xC0000135: a DLL the exe imports wasn't found. 0xC0000139: one was, but
    # not the version it was linked against.
    $hex = "0x{0:X8}" -f $code
    if ($code -ne 0) { return "FAIL  $Label - exited $hex (0xC0000135 = a DLL is missing)" }
    if (-not (Test-Path $catalog)) { return "FAIL  $Label - exited 0 but wrote no catalog" }
    $names = @((Get-Content $catalog -Raw | ConvertFrom-Json) | ForEach-Object { $_.name })
    if (-not ($names | Where-Object { $_ -like "window.*" })) {
        return "FAIL  $Label - catalog has no window.* command ($($names.Count) commands)"
    }
    return "PASS  $Label - $($names.Count) commands"
}

Enter-BuildEnv
Remove-Tree $WorkDir
New-Item -ItemType Directory -Path $WorkDir | Out-Null

Write-Host "== building the CLI ==" -ForegroundColor Cyan
# The product only: a package-level build also builds the test targets'
# resource bundles, and swiftbuild's Touch task on one of those is racy on
# Windows (see the next-toolchain-windows job).
Push-Location $Repo
try { Invoke-Native "CLI build" { swift build --product swift-pwa @BuildFlags } } finally { Pop-Location }
$cli = Join-Path $Repo ".build\debug\swift-pwa.exe"
if (-not (Test-Path $cli)) {
    $binPath = (swift build --package-path $Repo --show-bin-path 2>$null | Select-Object -Last 1)
    $cli = Join-Path $binPath "swift-pwa.exe"
}

Write-Host "== scaffolding $target against $Repo ==" -ForegroundColor Cyan
Push-Location $WorkDir
try { Invoke-Native "init" { & $cli init $target } } finally { Pop-Location }
$manifest = Join-Path $appDir "Package.swift"
$repoForSwift = $Repo.Replace('\', '/')
$repoLeaf = Split-Path $Repo -Leaf
# A path dependency is named after its directory, so the product reference has
# to follow a checkout that isn't called swift-pwa.
Write-Utf8NoBom $manifest (([IO.File]::ReadAllText($manifest) `
    -replace '\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)', ".package(path: `"$repoForSwift`")") `
    -replace 'package: "swift-pwa"', "package: `"$repoLeaf`"")
if (-not (Select-String -Path $manifest -Pattern 'package\(path:' -Quiet)) {
    throw "the scaffold's Package.swift no longer matches the rewrite - it would test the released package"
}
# The bundler looks for the NuGet packages beside or above the project. A copy,
# not a junction: the cleanup's recursive delete must not reach the originals.
New-Item -ItemType Directory "$appDir\packages" | Out-Null
foreach ($pkg in "Microsoft.Web.WebView2", "Microsoft.Windows.ImplementationLibrary") {
    Copy-Item -Recurse -Path (Join-Path $Packages $pkg) -Destination "$appDir\packages\$pkg"
}

$relocated = Join-Path $WorkDir "relocated"
New-Item -ItemType Directory $relocated | Out-Null
Push-Location $appDir
try {
    Write-Host "== swift-pwa build --target windows ($Configuration) ==" -ForegroundColor Cyan
    Invoke-Native "folder bundle" {
        & $cli build --target windows --configuration $Configuration --output "out\folder"
    }
    Write-Host "== swift-pwa build --target windows --single-file ==" -ForegroundColor Cyan
    Invoke-Native "single-file bundle" {
        & $cli build --target windows --configuration $Configuration --single-file --output "out\single"
    }
} finally { Pop-Location }

# Move both artifacts out of the project, then delete its build tree, so a
# bundle that reaches back into .build fails here rather than on a user's box.
$folderExe = Get-ChildItem "$appDir\out\folder" -Recurse -Filter "$target.exe" | Select-Object -First 1
$singleExe = Get-ChildItem "$appDir\out\single" -Filter "$target.exe" | Select-Object -First 1
if (-not $folderExe) { throw "the folder bundle has no $target.exe under out\folder" }
if (-not $singleExe) { throw "the single-file build left no $target.exe in out\single" }
Move-Item $folderExe.Directory.FullName "$relocated\folder"
New-Item -ItemType Directory "$relocated\single" | Out-Null
Move-Item $singleExe.FullName "$relocated\single\$target.exe"
Remove-Tree "$appDir\.build"
Remove-Tree "$appDir\out"
Write-Host "folder bundle: $((Get-ChildItem "$relocated\folder" | ForEach-Object Name) -join ', ')"

# Only Windows itself: every Swift, Visual Studio and user entry is gone.
$windowsOnly = @("$env:SystemRoot\System32", "$env:SystemRoot", "$env:SystemRoot\System32\Wbem") -join ';'

Write-Host "== launching each bundle headlessly (SWIFT_PWA_DESCRIBE) ==" -ForegroundColor Cyan
$results = @(
    (Test-Launch "folder-control" "$relocated\folder\$target.exe" $env:Path),
    (Test-Launch "folder-portable" "$relocated\folder\$target.exe" $windowsOnly),
    # No single-file portable leg: the loader can't take a DLL from inside the
    # exe, so a single-file build can't carry the Swift runtime, and the build
    # says so. What's checked is that it starts.
    (Test-Launch "single-control" "$relocated\single\$target.exe" $env:Path)
)
$results | ForEach-Object {
    Write-Host $_ -ForegroundColor $(if ($_ -like "PASS*") { "Green" } else { "Red" })
}
if ($results | Where-Object { $_ -like "FAIL*portable*" }) {
    $folderApp = "$relocated\folder\$target.exe"
    # The bundled exe is a GUI app, so whatever it prints is lost. A copy
    # switched back to the console subsystem shows it.
    $console = "$relocated\folder\$target-console.exe"
    Copy-Item $folderApp $console
    editbin /nologo /SUBSYSTEM:CONSOLE $console | Out-Null
    $savedPath = $env:Path
    $env:Path = $windowsOnly
    $env:SWIFT_PWA_DESCRIBE = Join-Path $WorkDir "catalog-console.json"
    try {
        $p = Start-Process -FilePath $console -WorkingDirectory $WorkDir -PassThru -NoNewWindow `
            -RedirectStandardOutput "$WorkDir\console.out" -RedirectStandardError "$WorkDir\console.err"
        $finished = $p.WaitForExit(60000)
        if (-not $finished) { $p.Kill() }
        Write-Host ("console copy with only Windows on PATH: {0}" -f `
            $(if ($finished) { "exited 0x{0:X8}" -f $p.ExitCode } else { "still running after 60 s" }))
    } finally {
        $env:Path = $savedPath
        Remove-Item Env:SWIFT_PWA_DESCRIBE
    }
    Get-Content "$WorkDir\console.out", "$WorkDir\console.err" -ErrorAction SilentlyContinue |
        Select-Object -First 40 | ForEach-Object { Write-Host "  | $_" }
}
if ($results | Where-Object { $_ -like "FAIL*" }) { exit 1 }
