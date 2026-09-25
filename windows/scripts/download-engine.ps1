param(
    [ValidateSet("CPU", "CUDA", "Vulkan")]
    [string]$Backend = "CUDA"
)

$ErrorActionPreference = "Stop"
# Windows PowerShell 5.1 显示进度条时 Invoke-WebRequest 会慢好几倍
$ProgressPreference = "SilentlyContinue"
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Destination = Join-Path $ProjectRoot "bin"
$TemporaryRoot = Join-Path $ProjectRoot "build\engine-download"
$Headers = @{ "User-Agent" = "Qwen-Image-Studio-Windows" }

$Release = Invoke-RestMethod -Uri "https://api.github.com/repos/leejet/stable-diffusion.cpp/releases/latest" -Headers $Headers
$Suffix = switch ($Backend) {
    "CPU" { "-bin-win-cpu-x64.zip" }
    "CUDA" { "-bin-win-cuda12-x64.zip" }
    "Vulkan" { "-bin-win-vulkan-x64.zip" }
}
$Asset = $Release.assets | Where-Object { $_.name.EndsWith($Suffix) } | Select-Object -First 1
if (-not $Asset) { throw "最新版本中没有找到 $Backend Windows x64 预编译包。" }

New-Item -ItemType Directory -Force -Path $Destination, $TemporaryRoot | Out-Null
$Archive = Join-Path $TemporaryRoot $Asset.name
Write-Host ("正在下载 {0}（{1:N0} MB）..." -f $Asset.name, ($Asset.size / 1MB))
Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $Archive -Headers $Headers

$Extracted = Join-Path $TemporaryRoot "extracted"
if (Test-Path -LiteralPath $Extracted) { Remove-Item -LiteralPath $Extracted -Recurse -Force }
Expand-Archive -LiteralPath $Archive -DestinationPath $Extracted -Force
$Engine = Get-ChildItem -LiteralPath $Extracted -Filter "sd-cli.exe" -Recurse | Select-Object -First 1
if (-not $Engine) { throw "下载包中没有找到 sd-cli.exe。" }
Copy-Item (Join-Path $Engine.Directory.FullName "*") $Destination -Recurse -Force

# CUDA 包本身不含 CUDA 运行库（cudart / cublas），没装 CUDA Toolkit 的电脑必须额外下载，否则会退回 CPU 或无法启动
if ($Backend -eq "CUDA") {
    $Runtime = $Release.assets | Where-Object { $_.name -like "cudart-*-win-cu12-x64.zip" } | Select-Object -First 1
    if (-not $Runtime) { throw "最新版本中没有找到 CUDA 运行库包（cudart-*-win-cu12-x64.zip）。" }
    $RuntimeArchive = Join-Path $TemporaryRoot $Runtime.name
    Write-Host ("正在下载 CUDA 运行库 {0}（{1:N0} MB）..." -f $Runtime.name, ($Runtime.size / 1MB))
    Invoke-WebRequest -Uri $Runtime.browser_download_url -OutFile $RuntimeArchive -Headers $Headers
    $RuntimeExtracted = Join-Path $TemporaryRoot "cudart"
    if (Test-Path -LiteralPath $RuntimeExtracted) { Remove-Item -LiteralPath $RuntimeExtracted -Recurse -Force }
    Expand-Archive -LiteralPath $RuntimeArchive -DestinationPath $RuntimeExtracted -Force
    Get-ChildItem -LiteralPath $RuntimeExtracted -Filter "*.dll" -Recurse | Copy-Item -Destination $Destination -Force
}
Write-Host "已安装 $Backend 推理引擎：$Destination" -ForegroundColor Green

