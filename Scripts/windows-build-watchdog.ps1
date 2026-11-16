<#
.SYNOPSIS
    Run a Windows build command, and kill and retry it if SwiftPM's planner
    stalls.

.DESCRIPTION
    On GitHub's hosted Windows runners any `swift build` can sit on
    "[Pre-planning 1 / N]" for tens of minutes, compiling nothing
    (swiftlang/swift-build#1883). Stacks taken during the stall show the
    planner's clang tool-discovery processes (`clang -v -E -dM ... -c NUL`)
    blocked writing to a stdout pipe the planner has stopped reading. This
    project's own samples show the same thing from outside: three clang
    processes at zero CPU while the build process spins on four cores. One CI
    job lost 63 minutes to it in one build and was cancelled in the next.

    So this watches the command's process tree. A clang that has been alive
    for -StallMinutes without using any CPU is stuck: a real compile always
    uses CPU, and a discovery clang normally exits within a second. When it
    sees one, it prints the stuck processes' command lines, kills the clang's
    parent and everything under it, and runs the command again, up to
    -Retries times. A command that fails on its own fails as it would have,
    with its own exit code.

    Only processes descended from this one are considered, so a watchdog on a
    developer's machine can't touch an unrelated build.

.PARAMETER StallMinutes
    How long a clang may sit at zero CPU before it counts as stuck. Default 3.

.PARAMETER Retries
    How many times to rerun the command after a stall. Default 1.

.EXAMPLE
    ./Scripts/windows-build-watchdog.ps1 -- swift build -c release @flags
#>
# No param() block: the command's own flags (`--product`, `-c`) must reach it
# untouched, and PowerShell's binder tries to match them against this script's
# parameters (under `powershell -File` it rejected `--product` as ambiguous).
# So the two options are read off the front of $args by hand.
$ErrorActionPreference = "Continue"
$StallMinutes = 3.0
$Retries = 1
$rest = @($args)
while ($rest.Count -gt 0) {
    $word = [string]$rest[0]
    if ($word -eq "-StallMinutes" -and $rest.Count -gt 1) { $StallMinutes = [double]$rest[1]; $rest = @($rest | Select-Object -Skip 2) }
    elseif ($word -eq "-Retries" -and $rest.Count -gt 1) { $Retries = [int]$rest[1]; $rest = @($rest | Select-Object -Skip 2) }
    elseif ($word -eq "--") { $rest = @($rest | Select-Object -Skip 1); break }
    else { break }
}
$Command = $rest
if (-not $Command) { Write-Error "usage: windows-build-watchdog.ps1 [-StallMinutes m] [-Retries n] -- <command> [args]"; exit 2 }
$exe = [string]$Command[0]
$arguments = @($Command | Select-Object -Skip 1 | ForEach-Object { [string]$_ })

# The watcher runs as its own process so it keeps running while this one is
# blocked streaming the build's output, and so a build that takes the console
# with it can't take the watcher too. It reports through a marker file.
$watcher = {
    param($rootPid, $stallSeconds, $marker)
    $seen = @{}
    while ($true) {
        Start-Sleep -Seconds 20
        $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $children = @{}
        foreach ($p in $all) {
            $key = [int]$p.ParentProcessId
            if (-not $children.ContainsKey($key)) { $children[$key] = @() }
            $children[$key] += $p
        }
        # Everything under the watchdog's own process.
        $descendants = @()
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue([int]$rootPid)
        while ($queue.Count -gt 0) {
            $parent = $queue.Dequeue()
            if ($children.ContainsKey($parent)) {
                foreach ($c in $children[$parent]) {
                    if ([int]$c.ProcessId -ne [int]$rootPid) { $descendants += $c; $queue.Enqueue([int]$c.ProcessId) }
                }
            }
        }
        $now = Get-Date
        $stuck = @()
        foreach ($p in $descendants | Where-Object { $_.Name -eq "clang.exe" }) {
            $id = [int]$p.ProcessId
            $cpu = [double]($p.KernelModeTime + $p.UserModeTime) / 1e7
            if (-not $seen.ContainsKey($id) -or $seen[$id].Cpu -lt $cpu - 0.05) {
                $seen[$id] = @{ Since = $now; Cpu = $cpu }
            } elseif (($now - $seen[$id].Since).TotalSeconds -ge $stallSeconds) {
                $stuck += $p
            }
        }
        if ($stuck.Count -gt 0) {
            $byId = @{}
            foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
            $lines = @()
            $parents = @($stuck | ForEach-Object { [int]$_.ParentProcessId } | Sort-Object -Unique)
            foreach ($s in $stuck) {
                $lines += "  stuck: clang pid $($s.ProcessId) under pid $($s.ParentProcessId): $($s.CommandLine)"
            }
            foreach ($id in $parents) {
                $p = $byId[$id]
                if ($p) {
                    $cpu = [double]($p.KernelModeTime + $p.UserModeTime) / 1e7
                    $lines += ("  parent: {0} pid {1}, {2:N0} s CPU: {3}" -f $p.Name, $id, $cpu, $p.CommandLine)
                }
            }
            Set-Content -Path $marker -Value $lines -Encoding UTF8
            foreach ($id in $parents) { taskkill /PID $id /T /F 2>&1 | Out-Null }
            return
        }
    }
}

$attempt = 0
while ($true) {
    $marker = Join-Path ([IO.Path]::GetTempPath()) ("swift-pwa-watchdog-{0}.txt" -f [guid]::NewGuid())
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(
        "& { $($watcher.ToString()) } $PID $([int]($StallMinutes * 60)) '$marker'"))
    $watch = Start-Process powershell -NoNewWindow -PassThru -ArgumentList "-NoProfile", "-EncodedCommand", $encoded

    & $exe @arguments 2>&1 | ForEach-Object {
        # A native stderr line arrives as an ErrorRecord; print the line.
        if ($_ -is [System.Management.Automation.ErrorRecord]) { "$($_.TargetObject)" } else { "$_" }
    } | Write-Host
    $code = $LASTEXITCODE

    Stop-Process -Id $watch.Id -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $marker)) { exit $code }

    $reason = "watchdog: a clang sat at zero CPU for $StallMinutes min, so the build was stalled " +
        "(swiftlang/swift-build#1883). Killed it:"
    Write-Host $reason
    Get-Content $marker | Write-Host
    Remove-Item $marker -ErrorAction SilentlyContinue
    if ($attempt -ge $Retries) {
        Write-Host "watchdog: no retries left ($Retries)."
        exit 1
    }
    $attempt++
    Write-Host "watchdog: retrying ($attempt of $Retries)."
}
