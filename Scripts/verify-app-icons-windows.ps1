<#
.SYNOPSIS
  Verify the MSIX's light/dark taskbar logos (#314). The Windows twin of
  Scripts/verify-app-icons.sh.

.DESCRIPTION
  A fresh `swift-pwa init` app with a light (blue) and dark (green) icon is
  packaged as an MSIX, signed with a throwaway certificate, installed and
  launched. Rows:

    1. The package carries the theme-qualified logos and a resources.pri that
       indexes them (TargetSize + AlternateForm candidates).
    2. With the taskbar dark, the app's taskbar button shows the dark art.
    3. With the taskbar light, it shows the light art.

  The taskbar is read from a DPI-aware screen capture of its strip, counting
  pixels of each art's colour: the shell's own icon APIs return the
  unqualified asset whatever the theme, so they can't stand in for it.

  Installing and launching go through a scheduled task with /IT, because an
  SSH session lands in Session 0 and Add-AppxPackage is refused there
  (0x80070005). Needs a logged-on, unlocked desktop. The taskbar theme is
  restored afterwards, and the package and certificate removed.

.PARAMETER Control
  Build the same app with a light-only icon: the control, where row 1 and
  row 2 have to fail (no qualified logos, so a dark taskbar shows the light
  art).

.EXAMPLE
  powershell -File Scripts\verify-app-icons-windows.ps1
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Packages,
    [string]$WorkDir = "$env:TEMP\swift-pwa-app-icons",
    [switch]$Control
)

$ErrorActionPreference = "Stop"
if (-not $Repo) { $Repo = (Resolve-Path "$PSScriptRoot\..").Path }
if (-not $Packages) { $Packages = Join-Path $Repo "packages" }
$appName = "IconProbe"
$appId = "com.example.iconprobe"
$appDir = Join-Path $WorkDir $appName
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$light = @(40, 90, 220)
$dark = @(20, 110, 60)

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

function Write-Png([string]$Path, [int[]]$Rgb) {
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap 1024, 1024
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(255, $Rgb[0], $Rgb[1], $Rgb[2]))
    $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

# Runs a PowerShell script block in the logged-on user's session and returns
# what it printed.
function Invoke-InSession([string]$Name, [string]$Body) {
    $script = Join-Path $WorkDir "$Name.ps1"
    $out = Join-Path $WorkDir "$Name.out"
    $done = Join-Path $WorkDir "$Name.done"
    Remove-Item $out, $done -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText($script, $Body, (New-Object System.Text.UTF8Encoding($true)))
    $runner = Join-Path $WorkDir "$Name.cmd"
    Write-Utf8NoBom $runner ("@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -Command `"& '$script' *> '$out'; New-Item '$done' | Out-Null`"`r`n")
    $task = "swift-pwa-app-icons-$Name"
    cmd /c "schtasks /delete /tn $task /f >nul 2>&1"
    cmd /c "schtasks /create /tn $task /tr `"$runner`" /sc once /st 00:00 /it /f >nul 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "could not create the scheduled task (is a user logged on?)" }
    cmd /c "schtasks /run /tn $task >nul 2>&1"
    $deadline = (Get-Date).AddSeconds(120)
    while (-not (Test-Path $done) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    cmd /c "schtasks /delete /tn $task /f >nul 2>&1"
    if (-not (Test-Path $done)) { throw "the session task '$Name' never finished" }
    return [IO.File]::ReadAllText($out)
}

# A locked desktop captures as solid black, which would read as a failed row.
$console = (Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1).SessionId
if (Get-Process LogonUI -ErrorAction SilentlyContinue | Where-Object SessionId -eq $console) {
    throw "the desktop is locked (LogonUI is up in session $console) - unlock it; rows 2 and 3 read the taskbar"
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
$manifest = Join-Path $appDir "Package.swift"
$text = [IO.File]::ReadAllText($manifest)
$pin = '\.package\(url: "https://github\.com/tophatch/swift-pwa", from: "[^"]+"\)'
if ($text -notmatch $pin) { throw "the scaffold's package pin moved; this would test the released package" }
Write-Utf8NoBom $manifest (($text -replace $pin, ".package(path: `"$($Repo.Replace('\', '/'))`")") `
    -replace 'package: "swift-pwa"', "package: `"$(Split-Path $Repo -Leaf)`"")
New-Item -ItemType Directory "$appDir\art" | Out-Null
Write-Png "$appDir\art\icon.png" $light
Write-Png "$appDir\art\icon-dark.png" $dark
$pwa = Get-Content (Join-Path $appDir "pwa.json") -Raw | ConvertFrom-Json
$icon = if ($Control) { "art/icon.png" } else { [pscustomobject]@{ light = "art/icon.png"; dark = "art/icon-dark.png" } }
$pwa | Add-Member -NotePropertyName icon -NotePropertyValue $icon -Force
Write-Utf8NoBom (Join-Path $appDir "pwa.json") ($pwa | ConvertTo-Json -Depth 10)
# The bundler looks for the NuGet packages beside or above the project.
New-Item -ItemType Directory "$appDir\packages" | Out-Null
foreach ($pkg in "Microsoft.Web.WebView2", "Microsoft.Windows.ImplementationLibrary") {
    Copy-Item -Recurse -Path (Join-Path $Packages $pkg) -Destination "$appDir\packages\$pkg"
}

# A throwaway signing certificate whose subject is the package's Publisher.
$cert = New-SelfSignedCertificate -Type Custom -Subject "CN=$appId" -KeyUsage DigitalSignature `
    -FriendlyName "swift-pwa app-icons probe" -CertStoreLocation Cert:\CurrentUser\My `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
$cer = Join-Path $WorkDir "probe.cer"
Export-Certificate -Cert $cert -FilePath $cer | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null

$rows = @()
function Add-Row([string]$Text, [bool]$Ok) {
    $script:rows += "$(if ($Ok) { 'PASS' } else { 'FAIL' }) $Text"
}
$themeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$originalTheme = (Get-ItemProperty $themeKey).SystemUsesLightTheme
try {
    Write-Host "== building the MSIX ==" -ForegroundColor Cyan
    Push-Location $appDir
    try {
        # Through cmd into a file: PowerShell 5.1 turns a native command's
        # stderr into a terminating error, and the CLI writes warnings there.
        $buildLog = Join-Path $WorkDir "build.log"
        cmd /c "`"$cli`" build --target windows --package-format msix --arch $arch --sign $($cert.Thumbprint) > `"$buildLog`" 2>&1"
        $log = Get-Content $buildLog -Encoding UTF8
        if ($LASTEXITCODE -ne 0) { $log | Select-Object -Last 20 | Write-Host; throw "app build failed" }
        $log | Where-Object { "$_" -like "*app icon*" } | Write-Host
    } finally { Pop-Location }
    $msix = Get-ChildItem (Join-Path $appDir "build\windows") -Filter *.msix | Select-Object -First 1

    # Row 1: what the package carries.
    $unpacked = Join-Path $WorkDir "unpacked"
    makeappx.exe unpack /p $msix.FullName /d $unpacked /o | Out-Null
    $pri = Join-Path $unpacked "resources.pri"
    $candidates = ""
    if (Test-Path $pri) {
        makepri.exe dump /if $pri /of (Join-Path $WorkDir "pri.xml") /o | Out-Null
        $candidates = (Select-String -Path (Join-Path $WorkDir "pri.xml") -Pattern 'AlternateForm-(UNPLATED|LIGHTUNPLATED)').Count
    }
    $logos = @(Get-ChildItem $unpacked -Filter "Square44x44Logo.targetsize-*_altform-*unplated.png").Count
    Add-Row "1. the package carries theme-qualified taskbar logos, indexed by resources.pri ($logos files, $candidates candidates)" ($logos -gt 0 -and $candidates -gt 0)

    Write-Host "== installing and launching ==" -ForegroundColor Cyan
    $installed = Invoke-InSession "install" @"
Get-AppxPackage $($appId.Replace('.', '')) -ErrorAction SilentlyContinue | Remove-AppxPackage
Get-AppxPackage | Where-Object { `$_.Name -like '*iconprobe*' } | Remove-AppxPackage
Add-AppxPackage '$($msix.FullName)'
`$p = Get-AppxPackage | Where-Object { `$_.Name -like '*iconprobe*' } | Select-Object -First 1
Start-Process "shell:AppsFolder\`$(`$p.PackageFamilyName)!App"
Start-Sleep 6
"installed `$(`$p.PackageFullName)"
"@
    Write-Host $installed.Trim()

    $capture = @'
param([int]$Light, [string]$Save)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, UIntPtr w, string l, uint f, uint t, out UIntPtr r);
}
"@
[W]::SetProcessDPIAware() | Out-Null
Set-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize SystemUsesLightTheme $Light
$r = [UIntPtr]::Zero
[W]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'ImmersiveColorSet', 2, 5000, [ref]$r) | Out-Null
Start-Sleep 4
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$strip = 140
$bmp = New-Object System.Drawing.Bitmap $b.Width, $strip
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.X, $b.Bottom - $strip, 0, 0, $bmp.Size)
$bmp.Save($Save, [System.Drawing.Imaging.ImageFormat]::Png)
$running = @(Get-Process IconProbe -ErrorAction SilentlyContinue).Count
function Count($rgb) {
  $n = 0
  for ($y = 0; $y -lt $bmp.Height; $y += 2) { for ($x = 0; $x -lt $bmp.Width; $x += 2) {
    $c = $bmp.GetPixel($x, $y)
    if ([Math]::Abs($c.R - $rgb[0]) -lt 14 -and [Math]::Abs($c.G - $rgb[1]) -lt 14 -and [Math]::Abs($c.B - $rgb[2]) -lt 14) { $n++ }
  } }
  $n
}
"light=$(Count @(LIGHT)) dark=$(Count @(DARK)) running=$running"
'@
    $capture = $capture.Replace('LIGHT', ($light -join ',')).Replace('DARK', ($dark -join ','))
    $captureFile = Join-Path $WorkDir "capture.ps1"
    [IO.File]::WriteAllText($captureFile, $capture, (New-Object System.Text.UTF8Encoding($true)))

    # The strips are kept in -WorkDir, to look at when a row fails.
    $darkTaskbar = (Invoke-InSession "dark" "& '$captureFile' -Light 0 -Save '$WorkDir\taskbar-dark.png'").Trim()
    $lightTaskbar = (Invoke-InSession "light" "& '$captureFile' -Light 1 -Save '$WorkDir\taskbar-light.png'").Trim()
    $counts = { param($s, $k) if ($s -match "$k=(\d+)") { [int]$matches[1] } else { 0 } }
    $d = & $counts $darkTaskbar 'dark'; $dl = & $counts $darkTaskbar 'light'
    $l = & $counts $lightTaskbar 'light'; $ld = & $counts $lightTaskbar 'dark'
    Add-Row "2. a dark taskbar shows the dark art ($darkTaskbar)" ($d -gt 20 -and $d -gt $dl)
    Add-Row "3. a light taskbar shows the light art ($lightTaskbar)" ($l -gt 20 -and $l -gt $ld)
} finally {
    Invoke-InSession "cleanup" @"
Set-ItemProperty '$themeKey' SystemUsesLightTheme $originalTheme
Get-Process $appName -ErrorAction SilentlyContinue | Stop-Process
Get-AppxPackage | Where-Object { `$_.Name -like '*iconprobe*' } | Remove-AppxPackage
"@ | Out-Null
    Get-ChildItem Cert:\LocalMachine\TrustedPeople, Cert:\CurrentUser\My |
        Where-Object Subject -eq "CN=$appId" | Remove-Item
}

$rows | ForEach-Object { Write-Host $_ }
$passed = @($rows | Where-Object { $_ -like 'PASS*' }).Count
if ($Control) {
    Write-Host "== control: $passed passed (rows 1 and 2 must fail) =="
    if ($rows[0] -like 'FAIL*' -and $rows[1] -like 'FAIL*') { exit 0 } else { exit 1 }
}
if ($passed -eq $rows.Count) { Write-Host "PASS: every row held." -ForegroundColor Green; exit 0 }
Write-Host "FAIL: see above." -ForegroundColor Red
exit 1
