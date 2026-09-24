#!/bin/zsh
# Qwen-Image-2.1 文生图 / 改图（stable-diffusion.cpp + Metal）
#
# 文生图: ./gen.sh "提示词" [宽 高] [步数] [seed]
# 改图:   REF=原图.png ./gen.sh "把背景换成海边" [宽 高]
#         多张参考图: REF="a.png,b.png" ./gen.sh "..."
# 可选环境变量: CFG(默认6.0)  NEG(负面提示词)  OUT(输出路径)
set -e
DIR="${0:A:h}"
M="$DIR/models"

PROMPT="${1:?用法: ./gen.sh \"提示词\" [宽 高] [步数] [seed]}"
W="${2:-1024}"; H="${3:-1024}"; STEPS="${4:-20}"; SEED="${5:--1}"
OUT="${OUT:-$DIR/outputs/$(date +%Y%m%d-%H%M%S).png}"

REF_ARGS=()
if [[ -n "$REF" ]]; then
  for r in ${(s:,:)REF}; do REF_ARGS+=(-r "$r"); done
fi

"$DIR/bin/sd-cli" \
  --diffusion-model "$M/qwen-image-2.1-Q8_0.gguf" \
  --vae "$M/vae/qwen_image_2.1_vae_bf16.safetensors" \
  --llm "$M/Qwen3-VL-8B-Instruct-UD-Q4_K_XL.gguf" \
  -p "$PROMPT" ${NEG:+-n "$NEG"} "${REF_ARGS[@]}" \
  --steps "$STEPS" --cfg-scale "${CFG:-6.0}" --sampling-method euler \
  -W "$W" -H "$H" -s "$SEED" --diffusion-fa \
  -o "$OUT"

echo "✅ 已保存: $OUT"
[[ -z "$NO_OPEN" ]] && open "$OUT"
