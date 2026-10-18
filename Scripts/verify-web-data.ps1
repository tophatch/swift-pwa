<#
.SYNOPSIS
  Verify SWIFT_PWA_WEB_DATA=ephemeral on Windows (#303). The twin of
  Scripts/verify-web-data.sh.

.DESCRIPTION
  An ephemeral launch has to start empty, keep what it writes while it runs,
  share nothing with another launch, and leave the persistent store as it found
  it. Rows, each reading and writing both localStorage and IndexedDB:

    1. CONTROL, must hold: a normal launch writes, a second normal launch reads
       it back. Without it, "ephemeral reads nothing" could mean the probe
       can't see storage at all.
    2. Two ephemeral launches in turn: each starts empty and reads back its own
       write.
    3. Two ephemeral launches at once: neither sees the other's write. Every
       launch of an app shares one WebView2 user data folder, and with it one
       browser process, so this is the row a shared InPrivate profile fails.
    4. A normal launch afterwards still reads the control's value.

  Nothing can be driven over SSH, so each launch is told what to do by
  SWIFT_PWA_INITIAL_ROUTE (read, write, hold open) and reports what it read by
  exit code. Launched through a scheduled task with /IT: an SSH session lands
  in Session 0, where a WebView2 controller can't be created.

.PARAMETER Repo
  The swift-pwa checkout to build against. Default: this script's repo.

.PARAMETER Packages
  Directory holding the restored WebView2 + WIL NuGet packages. Default: the
  `packages` folder in -Repo.

.PARAMETER Released
  Build against the last release instead: the control for the fix, where rows
  2 and 3 have to fail.

.EXAMPLE
  powershell -File Scripts\verify-web-data.ps1 -Packages C:\src\swift-pwa\packages
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Packages,
    [string]$WorkDir = "$env:TEMP\swift-pwa-web-data",
    [switch]$Released
)

$ErrorActionPreference = "Stop"
if (-not $Repo) { $Repo = (Resolve-Path "$PSScriptRoot\..").Path }
if (-not $Packages) { $Packages = Join-Path $Repo "packages" }
$appName = "WebDataCheck"
$appDir = Join-Path $WorkDir $appName
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
# What a read can find, by its position in the exit code (see the page).
$values = @("null", "persistent", "eph1", "par1")

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

# The page does what its query asks and exits 100 + 10 * (what localStorage
# held) + (what IndexedDB held), each the index in $values, 9 for anything else.
# `clear` empties both after reading; `write=<v>` stores v after that; `after` makes
# the reported read the one after the write; `hold=<ms>` stays open that long
# before quitting, so a second launch can run beside it.
$page = @'
<!doctype html><meta charset="utf-8"><title>web data check</title>
<body style="font:14px system-ui;padding:24px">checking web data...</body>
<script>
(async function () {
  const values = [null, 'persistent', 'eph1', 'par1'];
  const q = new URLSearchParams(location.search);
  const code = v => { const i = values.indexOf(v); return i < 0 ? 9 : i; };
  const db = await new Promise((ok, fail) => {
    const open = indexedDB.open('probe', 1);
    open.onupgradeneeded = () => open.result.createObjectStore('kv');
    open.onerror = () => fail(open.error);
    open.onsuccess = () => ok(open.result);
  });
  const store = mode => db.transaction('kv', mode).objectStore('kv');
  const done = req => new Promise(ok => { req.onsuccess = () => ok(req.result); });
  const read = async () => [localStorage.getItem('probe'), (await done(store('readonly').get('probe'))) ?? null];
  let found = await read();
  if (q.has('clear')) { localStorage.clear(); await done(store('readwrite').clear()); }
  if (q.has('write')) {
    localStorage.setItem('probe', q.get('write'));
    await done(store('readwrite').put(q.get('write'), 'probe'));
    if (q.has('after')) found = await read();
  }
  db.close();
  document.body.textContent = JSON.stringify(found);
  await new Promise(ok => setTimeout(ok, Number(q.get('hold') || 0)));
  __SWIFT_PWA__.invoke('app.quit', { exitCode: 100 + 10 * code(found[0]) + code(found[1]) });
})().catch(e => { document.body.textContent = String(e); __SWIFT_PWA__.invoke('app.quit', { exitCode: 1 }); });
</script>
'@

function Start-Launch([string]$Name, [bool]$Ephemeral, [string]$Query) {
    $runner = Join-Path $WorkDir "$Name.cmd"
    $lines = @("@echo off", "cd /d `"$script:ExeDir`"", "set `"SWIFT_PWA_INITIAL_ROUTE=/index.html?$Query`"")
    if ($Ephemeral) { $lines += "set SWIFT_PWA_WEB_DATA=ephemeral" }
    $lines += "$appName.exe"
    Write-Utf8NoBom $runner (($lines -join "`r`n") + "`r`n")
    $task = "swift-pwa-web-data-$Name"
    # Through cmd with output swallowed: PowerShell turns a native command's
    # stderr into a terminating error, and deleting a missing task writes some.
    cmd /c "schtasks /delete /tn $task /f >nul 2>&1"
    # /IT runs it in the logged-on user's session, where WebView2 can start.
    cmd /c "schtasks /create /tn $task /tr `"$runner`" /sc once /st 00:00 /it /f >nul 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "could not create the scheduled task (is a user logged on?)" }
    cmd /c "schtasks /run /tn $task >nul 2>&1"
    return $task
}

function Wait-Launch([string]$Task) {
    $deadline = (Get-Date).AddSeconds(120)
    Start-Sleep -Seconds 2
    while ((Get-Date) -lt $deadline) {
        $status = (schtasks /query /tn $Task /fo list /v | Select-String '^Status:').ToString()
        if ($status -match 'Ready') { break }
        Start-Sleep -Seconds 1
    }
    $line = (schtasks /query /tn $Task /fo list /v | Select-String '^Last Result:').ToString()
    cmd /c "schtasks /delete /tn $Task /f >nul 2>&1"
    if ($line -match '(-?\d+)\s*$') { return [int]$matches[1] }
    throw "could not read $Task's exit code"
}

# The exit code as "<localStorage>/<IndexedDB>", the same spelling as the bash twin.
function Format-Read([int]$Code) {
    if ($Code -lt 100 -or $Code -gt 199) { return "exit $Code" }
    $name = { param($i) if ($i -lt $values.Count) { $values[$i] } else { "other" } }
    return "$(& $name ([math]::Floor(($Code - 100) / 10)))/$(& $name (($Code - 100) % 10))"
}

$script:Failed = $false
function Test-Row([string]$Row, [int]$Code, [string]$Wanted) {
    $got = Format-Read $Code
    if ($got -eq $Wanted) { Write-Host "PASS $Row`: $got" -ForegroundColor Green }
    else { Write-Host "FAIL $Row`: got $got, wanted $Wanted" -ForegroundColor Red; $script:Failed = $true }
}
function Invoke-Launch([string]$Name, [bool]$Ephemeral, [string]$Query) {
    Wait-Launch (Start-Launch $Name $Ephemeral $Query)
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
Write-Utf8NoBom (Join-Path $appDir "web\index.html") $page
# The bundler looks for the NuGet packages beside or above the project.
New-Item -ItemType Directory "$appDir\packages" | Out-Null
foreach ($pkg in "Microsoft.Web.WebView2", "Microsoft.Windows.ImplementationLibrary") {
    Copy-Item -Recurse -Path (Join-Path $Packages $pkg) -Destination "$appDir\packages\$pkg"
}
Push-Location $appDir
try {
    & $cli build --target windows --configuration debug | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "app build failed" }
} finally { Pop-Location }
$script:ExeDir = Join-Path $appDir "build\windows\$appName"

Write-Host "== rows ==" -ForegroundColor Cyan
$null = Invoke-Launch "control1" $false "clear&write=persistent"
Test-Row "1. control: a normal launch reads the last one's write" `
    (Invoke-Launch "control2" $false "") "persistent/persistent"

Test-Row "2. ephemeral launch starts empty" (Invoke-Launch "eph1" $true "write=eph1") "null/null"
Test-Row "2. ephemeral launch reads its own write" (Invoke-Launch "eph1b" $true "write=eph1&after") "eph1/eph1"
Test-Row "2. next ephemeral launch starts empty" (Invoke-Launch "eph2" $true "") "null/null"

# par1 writes and stays open; par2 starts once par1 has had time to write.
$par1 = Start-Launch "par1" $true "write=par1&after&hold=20000"
Start-Sleep -Seconds 8
Test-Row "3. side by side, the other launch's write isn't visible" (Invoke-Launch "par2" $true "") "null/null"
Test-Row "3. side by side, each keeps its own" (Wait-Launch $par1) "par1/par1"

Test-Row "4. the persistent store is as the control left it" `
    (Invoke-Launch "after" $false "clear") "persistent/persistent"

Write-Host ""
if ($script:Failed) { Write-Host "FAIL: see above." -ForegroundColor Red; exit 1 }
Write-Host "PASS: every row held." -ForegroundColor Green
