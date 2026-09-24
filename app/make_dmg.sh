#!/bin/zsh
# 打包成可分发的 DMG：./make_dmg.sh [版本号]
set -e
cd "${0:A:h}"
export VERSION="${1:-1.0}"
./build.sh
DIST="../dist"; STAGE="$DIST/stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "../Qwen Image Studio.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp 安装说明.txt "$STAGE/"
DMG="$DIST/QwenImageStudio-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Qwen Image Studio" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
rm -rf "$STAGE"
echo "✅ $(du -h "$DMG" | cut -f1)  ${DMG:A}"
