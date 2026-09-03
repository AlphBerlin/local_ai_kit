<#
.SYNOPSIS
  Builds the llama.cpp shared library this adapter loads at runtime (Windows).

.DESCRIPTION
  Produces mtmd.dll plus the llama/ggml DLLs it links against. `mtmd` is
  llama.cpp's multimodal tool library; it re-exports the whole llama API and
  its name is what `LlamaCppRuntime.defaultLibraryName` expects on Windows.
  Build it even though this adapter does not use vision yet, or override the
  name at runtime with `LlamaCppRuntime.useLibrary(...)`.

  See README.md in this directory for where to place the result.

.PARAMETER Ref
  llama.cpp revision to build. Pin this to the revision the installed
  llama_cpp_dart's bindings were generated against.

.PARAMETER Backend
  cpu | vulkan | cuda. Defaults to vulkan.

.EXAMPLE
  .\build_llama.ps1 -Backend vulkan
#>
param(
  [string]$Ref = $(if ($env:LLAMA_CPP_REF) { $env:LLAMA_CPP_REF } else { "master" }),
  [ValidateSet("cpu", "vulkan", "cuda")][string]$Backend = "vulkan",
  [string]$Out = ""
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceDir = Join-Path $scriptDir "llama.cpp"
$buildDir = Join-Path $scriptDir "build\cmake-windows"
if (-not $Out) { $Out = Join-Path $scriptDir "build\windows" }
$repo = if ($env:LLAMA_CPP_REPO) { $env:LLAMA_CPP_REPO } else { "https://github.com/ggml-org/llama.cpp.git" }

if (-not (Test-Path (Join-Path $sourceDir ".git"))) {
  Write-Host "==> cloning llama.cpp into $sourceDir"
  git clone --recursive $repo $sourceDir
}
Write-Host "==> checking out $Ref"
git -C $sourceDir fetch --tags origin
git -C $sourceDir checkout --detach $Ref
git -C $sourceDir submodule update --init --recursive

$flags = @(
  "-DBUILD_SHARED_LIBS=ON",
  "-DLLAMA_BUILD_TESTS=OFF",
  "-DLLAMA_BUILD_EXAMPLES=OFF",
  "-DLLAMA_BUILD_SERVER=OFF",
  "-DLLAMA_BUILD_TOOLS=ON",
  "-DLLAMA_CURL=OFF",
  "-DGGML_NATIVE=OFF"
)
switch ($Backend) {
  "vulkan" { $flags += "-DGGML_VULKAN=ON" }
  "cuda" { $flags += "-DGGML_CUDA=ON" }
}

cmake -S $sourceDir -B $buildDir @flags
cmake --build $buildDir --config Release

New-Item -ItemType Directory -Force -Path $Out | Out-Null
Get-ChildItem -Path $buildDir -Recurse -Include "mtmd.dll", "llama.dll", "ggml*.dll" |
  ForEach-Object { Copy-Item $_.FullName -Destination $Out -Force }

Write-Host "==> artifacts in ${Out}:"
Get-ChildItem $Out | ForEach-Object { Write-Host "    $($_.Name)" }
