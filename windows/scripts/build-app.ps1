param(
    [switch]$Clean,
    [switch]$Installer
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $ProjectRoot

if ($Clean) {
    foreach ($Path in @("build\pyinstaller", "dist\Qwen Image Studio")) {
        $Resolved = Join-Path $ProjectRoot $Path
        if (Test-Path -LiteralPath $Resolved) { Remove-Item -LiteralPath $Resolved -Recurse -Force }
    }
}

if (-not (Test-Path ".venv\Scripts\python.exe")) { python -m venv .venv }
& ".venv\Scripts\python.exe" -m pip install --upgrade pip
& ".venv\Scripts\python.exe" -m pip install -r requirements.txt

$Args = @(
    "--noconfirm", "--windowed", "--onedir",
    "--name", "Qwen Image Studio",
    "--distpath", "dist", "--workpath", "build\pyinstaller",
    "--add-data", "assets;assets"
)
if (Test-Path "bin\sd-cli.exe") { $Args += @("--add-data", "bin;bin") }
$Args += "launcher.py"
& ".venv\Scripts\python.exe" -m PyInstaller @Args

Copy-Item "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md" "dist\Qwen Image Studio" -Force
New-Item -ItemType Directory -Force -Path "dist\Qwen Image Studio\scripts" | Out-Null
Copy-Item "scripts\download-engine.ps1", "scripts\build-engine.ps1" "dist\Qwen Image Studio\scripts" -Force
Write-Host "Windows 程序位于：dist\Qwen Image Studio\Qwen Image Studio.exe" -ForegroundColor Green

if ($Installer) {
    $Compiler = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
    if (-not $Compiler) { throw "未找到 Inno Setup 6（ISCC.exe），无法生成安装包。" }
    & $Compiler.Source "scripts\installer.iss"
}
