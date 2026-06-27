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
  CPU-only for now (a deliberate MVP — not a ggml/Vulkan limitation; a
  Vulkan/Adreno build is a follow-up once the SDK's arm64 link tooling is sorted),
  so it needs NEITHER glslc NOR the Vulkan SDK, just the arm64 MSVC toolset (run
  from an arm64 / amd64_arm64 developer shell so cl.exe + lib.exe target arm64).
  The produced asset is named per arch (llama-windows-<arch>.lib).

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

# Vulkan is the x64 GPU backend; arm64 ships CPU-only for now (MVP — a
# Vulkan/Adreno arm64 build is a follow-up). This single switch drives every
# Vulkan-specific step.
$Gpu = ($Arch -eq 'x64')

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
# Vulkan toolchain (glslc + SDK) is only needed for the x64 GPU build; the arm64
# CPU-only build skips it entirely.
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
# fast and single-config - so `cl` must be on PATH (it is inside vcvars). The
# LLAMA_BUILD_APP=OFF is REQUIRED: this commit's new app/ dir needs `common`
# headers we don't build.
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
if ($Gpu) {
    $CMakeArgs += "-DVulkan_GLSLC_EXECUTABLE=$Glslc"
    if ($env:VULKAN_SDK) { $CMakeArgs += "-DCMAKE_PREFIX_PATH=$env:VULKAN_SDK" }
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
