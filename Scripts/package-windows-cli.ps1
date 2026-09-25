<#
.SYNOPSIS
  Package a built swift-pwa.exe with the Swift runtime it links, so it runs on
  a box whatever Swift that box has - or none (#261).

.DESCRIPTION
  A Swift executable on Windows loads swiftCore.dll, Foundation.dll and the rest
  from PATH rather than carrying them. The v0.11.2 CLI was built with Swift
  6.3.1, and on a box whose only runtime was 6.4 it exited 0xC0000139
  (STATUS_ENTRYPOINT_NOT_FOUND) before printing anything, even for --version.
  `--static-swift-stdlib` would be the tidy answer and is silently ignored on
  Windows (measured on Swift 6.4, both build systems). So the release ships the
  runtime beside the exe instead: Windows searches the exe's own folder before
  PATH, so these DLLs win over whatever toolchain the user has.

  The DLL set is the exe's dependency closure, walked with dumpbin, restricted
  to the Swift runtime folder (which also carries the matching VC++ runtime).
  Everything else it imports is part of Windows. Walked rather than listed,
  because the set changes when a dependency does, and a hand-kept list goes
  stale without failing.

  -Verify then proves it: the packaged exe runs `--version` and `init` with
  every Swift directory stripped from PATH. A package that only works because
  the build box has a toolchain is exactly the bug.

.PARAMETER Exe
  The built swift-pwa.exe.

.PARAMETER Out
  The .zip to write. Its folder is created if needed.

.PARAMETER Verify
  Unpack the zip and smoke-test it with no Swift on PATH.

.EXAMPLE
  powershell -File Scripts\package-windows-cli.ps1 -Exe .build\release\swift-pwa.exe -Out dist\swift-pwa-windows-x86_64.zip -Verify
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Exe,
    [Parameter(Mandatory)] [string]$Out,
    [switch]$Verify
)

$ErrorActionPreference = "Stop"
$Exe = (Resolve-Path $Exe).Path

$swiftCore = (where.exe swiftCore.dll 2>$null | Select-Object -First 1)
if (-not $swiftCore) { throw "swiftCore.dll isn't on PATH - run this where the exe was built." }
$runtimeDir = Split-Path $swiftCore
if (-not (Get-Command dumpbin -ErrorAction SilentlyContinue)) {
    throw "dumpbin isn't on PATH - run this from a Visual Studio developer shell (vcvars)."
}
Write-Host "runtime: $runtimeDir"

$stage = Join-Path ([IO.Path]::GetTempPath()) ("swift-pwa-cli-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory $stage | Out-Null
try {
    Copy-Item $Exe (Join-Path $stage "swift-pwa.exe")

    # Breadth-first over imports, following only what the runtime folder has.
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Exe)
    $bundled = @{}
    while ($queue.Count -gt 0) {
        $file = $queue.Dequeue()
        $imports = dumpbin /nologo /dependents $file | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^[\w.-]+\.dll$' }
        foreach ($dll in $imports) {
            $key = $dll.ToLowerInvariant()
            if ($bundled.ContainsKey($key)) { continue }
            $source = Join-Path $runtimeDir $dll
            if (-not (Test-Path $source)) { continue }
            $bundled[$key] = $true
            Copy-Item $source $stage
            $queue.Enqueue($source)
        }
    }
    if (-not $bundled.ContainsKey("swiftcore.dll")) {
        throw "the dependency walk didn't reach swiftCore.dll - is $Exe a Swift executable?"
    }
    $names = ($bundled.Keys | Sort-Object) -join ", "
    Write-Host "bundled $($bundled.Count) runtime DLLs: $names"

    $outDir = Split-Path $Out
    if ($outDir) { New-Item -ItemType Directory -Force $outDir | Out-Null }
    if (Test-Path $Out) { Remove-Item $Out }
    Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $Out
    Write-Host ("wrote {0} ({1:N1} MB)" -f $Out, ((Get-Item $Out).Length / 1MB))
} finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}

if (-not $Verify) { exit 0 }

# --- Verify: run the packaged CLI with no Swift anywhere on PATH -------------
$unpacked = Join-Path ([IO.Path]::GetTempPath()) ("swift-pwa-cli-verify-" + [guid]::NewGuid().ToString("N"))
Expand-Archive -Path $Out -DestinationPath $unpacked
$savedPath = $env:Path
try {
    # Keep Windows itself and nothing else: every Swift, VS and user entry goes.
    $env:Path = (@("$env:SystemRoot\System32", "$env:SystemRoot", "$env:SystemRoot\System32\Wbem") -join ';')
    # The control: the bare exe has to fail here, or a pass below would prove
    # nothing - it would mean the stripped PATH still finds a runtime.
    & $Exe --version *> $null
    if ($LASTEXITCODE -eq 0) { throw "control: the unpackaged exe ran with no Swift on PATH, so this check can't tell anything" }
    Write-Host ("ok  control: the unpackaged exe fails with no Swift on PATH (0x{0:X8})" -f $LASTEXITCODE)

    $cli = Join-Path $unpacked "swift-pwa.exe"
    $version = & $cli --version
    if ($LASTEXITCODE -ne 0) {
        throw ("--version exited 0x{0:X8} with no Swift on PATH (0xC0000135 = a DLL is missing, 0xC0000139 = an entry point is)" -f $LASTEXITCODE)
    }
    Write-Host "ok  --version with no Swift on PATH: $version"

    $scratch = Join-Path $unpacked "scratch"
    New-Item -ItemType Directory $scratch | Out-Null
    Push-Location $scratch
    try { & $cli init SmokeApp | Out-Null; $code = $LASTEXITCODE } finally { Pop-Location }
    if ($code -ne 0) { throw ("init exited 0x{0:X8} with no Swift on PATH" -f $code) }
    foreach ($rel in @('Package.swift', 'pwa.json', 'web\index.html', 'Sources\SmokeApp\App.swift')) {
        $p = Join-Path $scratch "SmokeApp\$rel"
        if (-not (Test-Path $p) -or (Get-Item $p).Length -lt 64) { throw "init didn't write a plausible $rel" }
    }
    Write-Host "ok  init with no Swift on PATH wrote a complete app"
} finally {
    $env:Path = $savedPath
    Remove-Item -Recurse -Force $unpacked -ErrorAction SilentlyContinue
}
