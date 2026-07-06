#!/usr/bin/env bash
# 合同雷达 · bge-reranker-v2-m3 重排服务一键部署（在 Rerank/ 根目录运行：./deploy.sh）。
# 幂等：模型已在则跳过下载；docker/.env 缺则从示例建；最后起容器 + 冒烟自检。
#
# 模型来源可覆盖（默认从 HuggingFace 拉 Q8_0；换源/换量化档时设环境变量再跑）：
#   MODEL_HF_REPO=... MODEL_HF_FILE=... ./deploy.sh
# 离线机：先手动把 GGUF 放到 models/bge-reranker-v2-m3/ 即可，脚本会跳过下载。
set -euo pipefail
cd "$(dirname "$0")"

MODEL_HF_REPO="${MODEL_HF_REPO:-gpustack/bge-reranker-v2-m3-GGUF}"
MODEL_HF_FILE="${MODEL_HF_FILE:-bge-reranker-v2-m3-Q8_0.gguf}"
MODEL_DIR="models/bge-reranker-v2-m3"
MODEL_PATH="$MODEL_DIR/$MODEL_HF_FILE"
PORT="${RERANK_SERVER_PORT:-8082}"

echo "==> [1/5] 环境检查"
command -v docker >/dev/null || { echo "!! 未装 docker"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "!! 需要 docker compose v2（docker compose ...）"; exit 1; }

echo "==> [2/5] 准备模型（幂等）"
mkdir -p "$MODEL_DIR"
if [ -f "$MODEL_PATH" ]; then
  echo "    已存在：$MODEL_PATH（跳过下载）"
else
  echo "    需下载：$MODEL_HF_REPO / $MODEL_HF_FILE"
  if command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli download "$MODEL_HF_REPO" "$MODEL_HF_FILE" \
      --local-dir "$MODEL_DIR" --local-dir-use-symlinks False
  else
    URL="https://huggingface.co/${MODEL_HF_REPO}/resolve/main/${MODEL_HF_FILE}"
    echo "    （无 huggingface-cli，用 curl 拉 $URL）"
    curl -fL --retry 3 -o "$MODEL_PATH.part" "$URL" && mv "$MODEL_PATH.part" "$MODEL_PATH" || {
      rm -f "$MODEL_PATH.part"
      echo "!! 下载失败。可能原因：仓库/文件名不对、需代理、或该源不可达。"
      echo "   办法 A：设正确来源后重跑，如"
      echo "           MODEL_HF_REPO=<repo> MODEL_HF_FILE=<xxx.gguf> ./deploy.sh"
      echo "   办法 B：手动把 GGUF 放到 $MODEL_DIR/ 再重跑（会跳过下载）。"
      echo "   注意：llama.cpp --reranking 需带分类头的 rerank GGUF（BGE 系转换普遍带；勿用缺头的版本）。"
      exit 1; }
  fi
  echo "    完成：$MODEL_PATH（$(du -h "$MODEL_PATH" | cut -f1)）"
fi

echo "==> [3/5] 准备 docker/.env（缺则从示例建）"
[ -f docker/.env ] || { cp docker/.env.docker.example docker/.env; echo "    已建 docker/.env（默认值，可按需改端口/GPU）"; }

echo "==> [4/5] 构建并启动容器"
( cd docker && docker compose up -d )

echo "==> [5/5] 等待就绪 + 冒烟自检"
for i in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && { echo "    /health OK"; break; }
  [ "$i" = 60 ] && { echo "!! 60s 未就绪，查：cd docker && docker compose logs --tail=80"; exit 1; }
  sleep 2
done
echo "    重排打分自检（'25人'那条分应更高）："
curl -fsS "http://127.0.0.1:${PORT}/v1/rerank" -H 'Content-Type: application/json' -d '{
  "model":"bge-reranker-v2-m3","query":"培训人数超过20人",
  "documents":["某某培训项目","本次培训人数为25人"]}' | head -c 500; echo
echo
echo "✅ 完成 → 在 contract_radar 的 .env 设："
echo "     RERANK_BASE_URL=http://<本机或局域网IP>:${PORT}/v1"
echo "   再 docker compose up -d backend，即启用「深度」档片段重排。"
