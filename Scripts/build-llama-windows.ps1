#requires -Version 5.1
<#
.SYNOPSIS
  Build the llama.cpp Windows static lib (Vulkan GPU backend) that SwiftPWALlama
  links on Windows.

.DESCRIPTION
  The Windows analogue of Scripts/build-llama-linux.sh: CI builds it from the
  same pinned llama.cpp commit, publishes the raw `llama-windows-x64.lib` + its
  SHA-256 to a stable release, and the CLI downloads it and points `LIB` at it
  for the child `swift build` (Package.swift links `llama.lib` via
  `.linkedLibrary` - NO unsafeFlags, which would poison dependency resolution).

  Like the Linux slice, the GPU backend is Vulkan (GGML_VULKAN=ON): one artifact
  covers NVIDIA + AMD + Intel via the driver's Vulkan ICD, with CPU fallback. The
  compute shaders are compiled to SPIR-V at build (glslc) and embedded in the
  static lib, so the only runtime dependency is the Vulkan loader (vulkan-1.dll),
  which the GPU driver provides.

  Must run inside an MSVC build environment (cl.exe + lib.exe on PATH, e.g. a
  Visual Studio Developer PowerShell, or after `ilammy/msvc-dev-cmd` in CI). The
  Vulkan SDK must be installed and $env:VULKAN_SDK set (the SDK provides
  SPIRV-Headers' cmake config + glslc + vulkan-1.lib - none of which ship with a
  bare driver). The committed headers under Vendor/llama-headers are produced by
  the Linux build (platform-agnostic, same llama.cpp pin) and are NOT touched
  here, to avoid CRLF churn.

  Architecture: pass -Arch x64 (default) or -Arch arm64. x64 builds the Vulkan
  GPU backend (needs the Vulkan SDK, as above). arm64 (Snapdragon X Copilot+) is
  CPU-only by default (correct + shipped) and compiles with clang-cl (ggml-cpu
  refuses MSVC on ARM), so it needs no Vulkan SDK. EXPERIMENTAL: set
  LLAMA_WIN_ARM64_VULKAN=1 to build the arm64 Adreno Vulkan variant — it builds
  and runs but the Adreno X1's Vulkan compute currently returns INCORRECT output
  (Qualcomm driver / ggml shader immaturity), so it's for re-testing only, not
  shipping; that path needs the warm (Windows-ARM) Vulkan SDK for glslc +
  vulkan-1.lib. The produced asset is named per arch (llama-windows-<arch>.lib).

.EXAMPLE
  pwsh Scripts/build-llama-windows.ps1
  pwsh Scripts/build-llama-windows.ps1 -Arch arm64
  $env:LLAMA_COMMIT='<sha>'; pwsh Scripts/build-llama-windows.ps1
#>
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Arch = $(if ($env:LLAMA_WIN_ARCH) { $env:LLAMA_WIN_ARCH } else { 'x64' })
)
$ErrorActionPreference = 'Stop'

# GPU (Vulkan) build selection, per arch:
#   x64   → Vulkan by default (mature NVIDIA/AMD/Intel drivers); LLAMA_WIN_CPU_ONLY=1 forces CPU.
#   arm64 → CPU by default (correct + shipped). The Adreno Vulkan build is
#           EXPERIMENTAL: it builds, links, and runs, but the Adreno X1's Vulkan
#           compute currently returns INCORRECT output (Qualcomm driver / ggml
#           shader immaturity — the CPU path is fine; see docs/windows-setup.md).
#           Opt in with LLAMA_WIN_ARM64_VULKAN=1 to build the GPU variant for
#           re-testing as the driver / ggml matures.
# This switch drives every Vulkan-specific step.
if ($Arch -eq 'arm64') {
    $Gpu = [bool]$env:LLAMA_WIN_ARM64_VULKAN
} else {
    $Gpu = -not $env:LLAMA_WIN_CPU_ONLY
}
# arm64 MUST compile with clang-cl regardless of GPU: ggml's CPU backend
# hard-errors "MSVC is not supported for ARM, use clang" at configure. x64 uses
# the MSVC `cl` default. Independent of $Gpu (an arm64 CPU-only build still needs it).
$UseClangCl = ($Arch -eq 'arm64')

# Pinned llama.cpp commit - keep in lockstep with build-llama-linux.sh /
# build-llama-xcframework.sh so all three backends expose the same ABI/headers.
$LlamaRepo   = 'https://github.com/ggml-org/llama.cpp.git'
$LlamaCommit = if ($env:LLAMA_COMMIT) { $env:LLAMA_COMMIT } else { '5a6a0dd' }

Write-Host "=== target arch: $Arch (GPU backend: $(if ($Gpu) { 'Vulkan' } else { 'CPU-only' })) ==="
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Work  = if ($env:WORK) { $env:WORK } else { Join-Path $Root '.build\llama-windows' }
$Out   = if ($env:OUT)  { $env:OUT }  else { Join-Path $Root 'Vendor\llama-windows' } # gitignored
$Src   = Join-Path $Work 'llama.cpp'
$Build = Join-Path $Work 'build'

New-Item -ItemType Directory -Force -Path $Work, $Out | Out-Null

# --- sanity: MSVC + Vulkan SDK ---
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    throw "cl.exe not on PATH. Run from a Visual Studio Developer PowerShell (vcvars64), or after ilammy/msvc-dev-cmd in CI."
}
if (-not (Get-Command lib.exe -ErrorAction SilentlyContinue)) {
    throw "lib.exe not on PATH. Run from a Visual Studio Developer PowerShell (vcvars64)."
}
# Avoid the PS7-only `?.` operator - this script must run under stock Windows
# PowerShell 5.1 (what ships with Windows), not just pwsh.
# Vulkan toolchain (glslc + SDK) is needed for any GPU build (both arches now);
# a CPU-only build (LLAMA_WIN_CPU_ONLY) skips it entirely.
$Glslc = $null
if ($Gpu) {
    $glslcCmd = Get-Command glslc.exe -ErrorAction SilentlyContinue
    $Glslc = if ($glslcCmd) { $glslcCmd.Source } else { $null }
    if (-not $Glslc -and $env:VULKAN_SDK) { $Glslc = Join-Path $env:VULKAN_SDK 'Bin\glslc.exe' }
    if (-not (Test-Path $Glslc)) {
        throw "glslc.exe not found. Install the Vulkan SDK and set `$env:VULKAN_SDK (system vulkan-1.dll alone is NOT enough - the SDK provides glslc + SPIRV-Headers)."
    }
    Write-Host "glslc: $Glslc"
}

# Compiler: x64 uses MSVC (`cl`, the CMake default inside vcvars). arm64 MUST use
# clang-cl - ggml's CPU backend hard-errors "MSVC is not supported for ARM, use
# clang" (its ARM NEON paths don't build under MSVC's ARM compiler). clang-cl is
# the MSVC-ABI clang driver, so it still links cleanly with the MSVC-built Swift
# runtime and lib.exe-combined archive; it ships with the Swift toolchain (same
# usr\bin as swift.exe), so derive it from `swift` when it isn't already on PATH.
$ClangCl = $null
if ($UseClangCl) {
    # Resolve a clang-cl. Prefer one already on PATH; else the Swift toolchain's
    # (same usr\bin as swift.exe - this is what verified on the Snapdragon box);
    # else a standard LLVM install. On an arm64 host each of these defaults its
    # target to arm64, so no explicit --target is needed.
    $clCmd = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
    $ClangCl = if ($clCmd) { $clCmd.Source } else { $null }
    if (-not $ClangCl) {
        $swiftCmd = Get-Command swift.exe -ErrorAction SilentlyContinue
        if ($swiftCmd) {
            $cand = Join-Path (Split-Path $swiftCmd.Source) 'clang-cl.exe'
            if (Test-Path $cand) { $ClangCl = $cand }
        }
    }
    if (-not $ClangCl) {
        $llvm = Join-Path $env:ProgramFiles 'LLVM\bin\clang-cl.exe'
        if (Test-Path $llvm) { $ClangCl = $llvm }
    }
    if (-not $ClangCl) {
        throw "clang-cl.exe not found - required for the arm64 build (ggml-cpu hard-errors 'MSVC is not supported for ARM, use clang'). It ships with the Swift toolchain (same usr\bin as swift.exe); ensure that's on PATH, or install LLVM."
    }
    Write-Host "clang-cl (arm64): $ClangCl"
}

# --- fetch pinned source ---
# Full clone (no --depth) so every pinned commit is already present; the fetch
# below is only a safety net for bumping $LlamaCommit on an existing checkout.
if (-not (Test-Path (Join-Path $Src '.git'))) {
    git clone $LlamaRepo $Src
    if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
}
# Make the fetch non-fatal: fetching a bare SHA isn't supported by all servers,
# and under $ErrorActionPreference='Stop' git's stderr becomes a terminating
# error. We don't need it when the full clone already has the commit.
$ErrorActionPreference = 'Continue'
git -C $Src fetch --depth 1 origin $LlamaCommit 2>$null
if ($LASTEXITCODE -ne 0) { git -C $Src fetch origin 2>$null }
$ErrorActionPreference = 'Stop'
git -C $Src checkout -q $LlamaCommit
if ($LASTEXITCODE -ne 0) { throw "checkout of $LlamaCommit failed (not in the clone?)" }
Write-Host "=== llama.cpp at $(git -C $Src rev-parse --short HEAD) ==="

# CMake options mirror build-llama-linux.sh exactly (no examples/tools/server/
# app, static, GGML_NATIVE off for portability, Vulkan GPU). Ninja generator -
# fast and single-config - so the C/C++ compiler must be on PATH (it is inside
# vcvars). The LLAMA_BUILD_APP=OFF is REQUIRED: this commit's new app/ dir needs
# `common` headers we don't build.
$CMakeArgs = @(
    '-G', 'Ninja'
    '-DCMAKE_BUILD_TYPE=Release'
    '-DBUILD_SHARED_LIBS=OFF'
    "-DGGML_VULKAN=$(if ($Gpu) { 'ON' } else { 'OFF' })"
    '-DGGML_OPENMP=OFF'
    '-DGGML_NATIVE=OFF'
    '-DLLAMA_BUILD_COMMON=OFF'
    '-DLLAMA_BUILD_EXAMPLES=OFF'
    '-DLLAMA_BUILD_TESTS=OFF'
    '-DLLAMA_BUILD_TOOLS=OFF'
    '-DLLAMA_BUILD_SERVER=OFF'
    '-DLLAMA_BUILD_APP=OFF'
    '-DLLAMA_CURL=OFF'
)
# Vulkan toolchain (GPU build, either arch) and clang-cl (arm64, either GPU/CPU)
# are independent — an arm64 GPU build needs BOTH.
if ($Gpu) {
    $CMakeArgs += "-DVulkan_GLSLC_EXECUTABLE=$Glslc"
    if ($env:VULKAN_SDK) { $CMakeArgs += "-DCMAKE_PREFIX_PATH=$env:VULKAN_SDK" }
}
if ($UseClangCl) {
    # arm64: drive the build with clang-cl (ggml-cpu requires it on ARM). CMake
    # wants forward slashes in compiler paths even on Windows.
    $ClangFwd = $ClangCl -replace '\\', '/'
    $CMakeArgs += "-DCMAKE_C_COMPILER=$ClangFwd"
    $CMakeArgs += "-DCMAKE_CXX_COMPILER=$ClangFwd"
}

cmake -S $Src -B $Build @CMakeArgs
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }
cmake --build $Build --config Release -j $env:NUMBER_OF_PROCESSORS
if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }

# Combine all static slices into one llama.lib via lib.exe /OUT: - the MSVC
# analogue of Apple's `libtool -static` / GNU `ar -M`. lib.exe merges member
# objects across input .lib files; link order doesn't matter for a static lib.
$Combined = Join-Path $Out 'llama.lib'
Remove-Item -Force $Combined -ErrorAction SilentlyContinue
$Slices = Get-ChildItem -Path $Build -Recurse -Filter '*.lib' |
    Where-Object { $_.FullName -notmatch '\\CMakeFiles\\' } |
    Select-Object -ExpandProperty FullName -Unique | Sort-Object
if ($Slices.Count -eq 0) { throw "no static libs produced" }
Write-Host "=== combining $($Slices.Count) static libs ==="
$Slices | ForEach-Object { Write-Host $_ }
& lib.exe "/OUT:$Combined" @Slices
if ($LASTEXITCODE -ne 0) { throw "lib.exe combine failed" }
$SizeMB = [math]::Round((Get-Item $Combined).Length / 1MB, 1)
Write-Host "=== wrote $Combined ($SizeMB MB) ==="

# --- publishable asset (raw .lib, renamed per-arch) + checksum ---
# The CLI downloads this directly and verifies the SHA-256 - no client-side
# unzip needed, so the CLI carries no archive dependency. CI uploads it to the
# stable `llama-vendor-windows-<arch>` release and sed-pins the checksum.
$Asset = Join-Path $Out "llama-windows-$Arch.lib"
Copy-Item -Force $Combined $Asset
Write-Host "=== publishable asset: $Asset ==="
Write-Host "sha256:"
(Get-FileHash -Algorithm SHA256 $Asset).Hash.ToLower()
