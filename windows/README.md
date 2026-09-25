<p align="center">
  <img src="assets/icon.png" width="112" alt="Qwen Image Studio">
</p>

# Qwen Image Studio · Windows

在 Windows 10/11 本地运行 Qwen-Image-2.1 的桌面生图 / 改图应用。界面和工作流参考了
[leoredrum/qwen-image-studio](https://github.com/leoredrum/qwen-image-studio)，Windows 版使用
Qt for Python，并通过 `stable-diffusion.cpp` 的 `sd-cli.exe` 完成本地推理。

## 已实现

- 对话式生图、生成队列、进度、剩余时间和实时预览
- **接着改**：同一段对话里默认以上一张为底图继续修改；上一张还在生成时发的话，会等它画完再接着改；「画新图」只对下一次生效
- 也可加入最多 10 张参考图
- **Qwen 官方提示词改写模型**（PE-T2I / PE-I2I，经 Ollama 运行）：文生图时扩写成详细描述并自动选画面比例；改图时模型能看到上一张图
- **去除 VAE 网格**：出图后自动精确去除 Qwen-Image VAE 留下的 2px 网格
- 草稿 / 标准 / 2K 三档分辨率与 7 种画面比例
- 步数、CFG、采样器、调度器、Seed、批量、负面提示词
- EasyCache、VAE 分块解码、透明背景 PNG（预览带棋盘格）
- 本地历史记录、复制、另存、打开位置、复用为参考图
- 内置模型管理器：按内存推荐量化档位，并从 Hugging Face 下载
- 可选 Ollama 提示词助手；Ollama 不可用时自动按原提示词生成
- CUDA、Vulkan 和 CPU 三种 Windows 推理引擎构建方式
- PyInstaller 绿色版与 Inno Setup 安装包脚本

## 系统要求

- Windows 10 22H2 或 Windows 11，64 位
- Python 3.10–3.13（只在源码运行或打包时需要）
- 内存 16 GB 起步，推荐 32 GB；模型约占 15–30 GB 磁盘空间
- NVIDIA 显卡：推荐 CUDA 后端；AMD / Intel 显卡：可尝试 Vulkan；没有兼容显卡时可用 CPU

显存不足不是一定无法运行：`stable-diffusion.cpp` 可以把部分工作卸载到系统内存，但速度会明显下降。

## 最快启动

1. 在 PowerShell 中进入本目录。
2. 下载官方预编译推理引擎（根据显卡三选一，推荐）：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\download-engine.ps1 -Backend CUDA    # NVIDIA
   powershell -ExecutionPolicy Bypass -File .\scripts\download-engine.ps1 -Backend Vulkan  # AMD / Intel
   powershell -ExecutionPolicy Bypass -File .\scripts\download-engine.ps1 -Backend CPU     # 兼容模式
   ```

   Windows 默认禁止直接运行 `.ps1` 脚本，所以要加 `-ExecutionPolicy Bypass`（只对这一次运行生效，不改系统设置）。
   CUDA 版会额外下载约 540MB 的 CUDA 运行库，没装 CUDA Toolkit 也能用。下载完引擎后**重新启动 app**，它会自动把引擎复制到工作目录。

   如果希望自己编译，则改用：

   ```powershell
   # NVIDIA，需先安装 Visual Studio 2022 C++、CMake、CUDA Toolkit
   .\scripts\build-engine.ps1 -Backend CUDA

   # AMD / Intel，需先安装 Visual Studio 2022 C++、CMake、Vulkan SDK
   .\scripts\build-engine.ps1 -Backend Vulkan

   # 无独显或用于兼容性测试
   .\scripts\build-engine.ps1 -Backend CPU
   ```

3. 启动开发版：

   ```powershell
   .\run.ps1
   ```

   第一次运行会自动建立虚拟环境并安装界面依赖。

4. 点击右上角“模型”→“一键安装推荐组合”。模型很大，下载可能需要较长时间。
5. 输入提示词并按 Enter。

如果已经有官方或自行编译的 Windows `sd-cli.exe`，可以把它及同目录 DLL 全部复制到：

```text
文档\Qwen Image Studio\bin\
```

也可以先复制到本项目的 `bin\`，再用下面的打包脚本把引擎随程序分发。

## 构建 Windows 程序

生成绿色目录版：

```powershell
.\scripts\build-app.ps1 -Clean
```

输出：

```text
dist\Qwen Image Studio\Qwen Image Studio.exe
```

如果系统已安装 Inno Setup 6，还可生成安装包：

```powershell
.\scripts\build-app.ps1 -Clean -Installer
```

输出到 `dist\installer\`。若构建前本项目 `bin\` 中已有 `sd-cli.exe`，引擎会打进程序，并在首次启动时复制到用户可写工作目录；模型权重不会打包。

## 模型目录

默认工作目录是 `%USERPROFILE%\Documents\Qwen Image Studio`：

```text
Qwen Image Studio\
├─ bin\
│  ├─ sd-cli.exe
│  └─ 推理后端所需 DLL
├─ models\
│  ├─ qwen-image-2.1-Q4_K_M.gguf
│  ├─ Qwen3-VL-8B-Instruct-UD-Q4_K_XL.gguf
│  ├─ mmproj-BF16.gguf
│  └─ vae\qwen_image_2.1_vae_bf16.safetensors
├─ outputs\
│  ├─ refs\
│  └─ history.json
└─ settings.json
```

工作目录可在“设置 → 存储”中修改。

## 提示词助手（Ollama）

安装并启动 [Ollama](https://ollama.com/)，然后在“设置 → 高级 → 提示词助手”里点「安装 Qwen 官方改写模型」（约 12GB），也可以在终端手动下载：

```powershell
ollama pull hf.co/prithivMLmods/Qwen-Image-2.1-PE-T2I-GGUF:Q4_K_M
ollama pull hf.co/prithivMLmods/Qwen-Image-2.1-PE-I2I-GGUF:Q4_K_M
```

装好后，输入框下勾选“助手”即可：发送后先由官方模型思考再改写（文生图约 30 秒，改图约 1~1.5 分钟），改图时它能看到上一张图。官方 system prompt 采用 Qwen Research License，首次使用时从官方仓库下载并缓存到 `models\pe\`。

没装官方模型时，会使用“通用模型（备用）”里填写的任意 Ollama 模型（例如 `qwen3.5:9b`）。没有运行 Ollama 时，生成不会中断，只会回退到用户原话。

## 测试

核心逻辑测试不依赖显卡或模型：

```powershell
python -m unittest discover -s tests -v
```

界面冒烟测试：

```powershell
$env:QT_QPA_PLATFORM = "offscreen"
python -m qwen_studio
```

## 常见问题

**提示缺少 `sd-cli.exe`**  
先运行 `powershell -ExecutionPolicy Bypass -File .\scripts\download-engine.ps1 -Backend CUDA`（最简单，AMD/Intel 显卡把 CUDA 换成 Vulkan），然后重启 app；或 `scripts\build-engine.ps1`，也可把可用的 Windows 引擎及其 DLL 放入工作目录的 `bin\`。

**CUDA 构建找不到编译器**  
在 Visual Studio Installer 中安装“使用 C++ 的桌面开发”，并勾选 Windows SDK；安装 CUDA Toolkit 后重新打开 PowerShell。

**Vulkan 构建失败**  
安装 LunarG Vulkan SDK，并确认新的 PowerShell 中存在 `VULKAN_SDK` 环境变量。

**生成时直接退出或内存不足**  
换用更小的 Q3/Q4 模型，先用“草稿”分辨率，并启用 VAE 分块解码。Windows 页面文件也应留有足够空间。

**模型下载中断**  
删除对应的 `.part` 文件后重试，或用浏览器 / Hugging Face CLI 下载到相同目录。

## 许可

应用代码采用 MIT License。`stable-diffusion.cpp`、Qt、Qwen 模型和各量化模型遵循其各自许可；详见
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
