param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("CPU", "CUDA", "Vulkan")]
    [string]$Backend = "CUDA",
    [string]$Ref = "master"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$DependencyRoot = Join-Path $ProjectRoot "build\dependencies"
$SourceRoot = Join-Path $DependencyRoot "stable-diffusion.cpp"
$BuildRoot = Join-Path $ProjectRoot ("build\engine-" + $Backend.ToLowerInvariant())
$Destination = Join-Path $ProjectRoot "bin"

foreach ($Tool in @("git", "cmake")) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "找不到 $Tool。请先安装 Git 与 CMake，并重新打开 PowerShell。"
    }
}

New-Item -ItemType Directory -Force -Path $DependencyRoot, $Destination | Out-Null
if (-not (Test-Path (Join-Path $SourceRoot ".git"))) {
    git clone --recursive https://github.com/leejet/stable-diffusion.cpp.git $SourceRoot
} else {
    git -C $SourceRoot fetch --tags origin
    git -C $SourceRoot submodule update --init --recursive
}
git -C $SourceRoot checkout $Ref
git -C $SourceRoot submodule update --init --recursive

$Defines = @(
    "-DSD_BUILD_SHARED_LIBS=ON",
    "-DSD_BUILD_SHARED_GGML_LIB=ON",
    "-DGGML_BACKEND_DL=ON",
    "-DGGML_NATIVE=OFF"
)
switch ($Backend) {
    "CUDA" { $Defines += "-DSD_CUDA=ON" }
    "Vulkan" {
        if (-not $env:VULKAN_SDK) { throw "Vulkan 构建需要先安装 LunarG Vulkan SDK。" }
        $Defines += "-DSD_VULKAN=ON"
    }
}

cmake -S $SourceRoot -B $BuildRoot -A x64 @Defines
cmake --build $BuildRoot --config Release --parallel

$Candidates = @(
    (Join-Path $BuildRoot "bin\Release"),
    (Join-Path $BuildRoot "bin")
)
$Output = $Candidates | Where-Object { Test-Path (Join-Path $_ "sd-cli.exe") } | Select-Object -First 1
if (-not $Output) { throw "编译完成，但没有找到 sd-cli.exe。" }
Copy-Item (Join-Path $Output "*") $Destination -Recurse -Force
Copy-Item (Join-Path $SourceRoot "LICENSE") (Join-Path $Destination "stable-diffusion.cpp-LICENSE.txt") -Force
Write-Host "推理引擎已复制到 $Destination" -ForegroundColor Green

