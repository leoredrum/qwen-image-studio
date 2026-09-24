#!/bin/zsh
# 从源码编译 stable-diffusion.cpp 推理引擎到 vendor/（最低 macOS 14，Apple 芯片，静态链接 + 内嵌 Metal shader）
set -e
cd "${0:A:h}"
COMMIT="${SD_COMMIT:-88411ef}"
SRC="${TMPDIR:-/tmp}/stable-diffusion.cpp"
[[ -d "$SRC" ]] || git clone --recursive https://github.com/leejet/stable-diffusion.cpp "$SRC"
git -C "$SRC" fetch -q origin && git -C "$SRC" checkout -q "$COMMIT" && git -C "$SRC" submodule update --init --recursive -q
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release -DSD_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DSD_BUILD_SHARED_LIBS=OFF -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF
cmake --build "$SRC/build" --config Release -j "$(sysctl -n hw.ncpu)" --target sd-cli
mkdir -p vendor/licenses
cp "$SRC/build/bin/sd-cli" vendor/sd-cli
cp "$SRC/LICENSE" vendor/licenses/stable-diffusion.cpp-LICENSE.txt
cp "$SRC/ggml/LICENSE" vendor/licenses/ggml-LICENSE.txt
echo "✅ vendor/sd-cli ($COMMIT)"
