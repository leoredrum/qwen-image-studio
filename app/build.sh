#!/bin/zsh
# 构建 Qwen Image Studio.app
set -e
cd "${0:A:h}"
APP="../Qwen Image Studio.app"

[[ -f vendor/sd-cli ]] || ./build_engine.sh
swift build -c release

# 图标
if [[ -f icon/art.png && ( ! -f icon/AppIcon.icns || icon/art.png -nt icon/AppIcon.icns ) ]]; then
  swift icon/make_icon.swift "$PWD/icon"
  rm -rf icon/AppIcon.iconset && mkdir icon/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s icon/icon_1024.png --out icon/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) icon/icon_1024.png --out icon/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns icon/AppIcon.iconset -o icon/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/QwenImageStudio "$APP/Contents/MacOS/"
[[ -f icon/AppIcon.icns ]] && cp icon/AppIcon.icns "$APP/Contents/Resources/"
# 内置推理引擎（从源码编译，最低 macOS 14，静态链接 + 内嵌 Metal shader）
mkdir -p "$APP/Contents/Resources/bin" "$APP/Contents/Resources/licenses"
cp vendor/sd-cli "$APP/Contents/Resources/bin/"
cp vendor/licenses/* "$APP/Contents/Resources/licenses/"
codesign --force --sign - "$APP/Contents/Resources/bin/sd-cli"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Qwen Image Studio</string>
  <key>CFBundleDisplayName</key><string>Qwen Image Studio</string>
  <key>CFBundleIdentifier</key><string>local.qwen-image-studio</string>
  <key>CFBundleExecutable</key><string>QwenImageStudio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-1.0}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP"
touch "$APP"
echo "✅ 已构建: ${APP:A}"
