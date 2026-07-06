#!/usr/bin/env bash
# 合同雷达 · bge-reranker-v2-m3 重排服务一键部署（在 Rerank/ 根目录运行）。
# 幂等：模型已在则直接起服务；docker/.env 缺则从示例建；最后起容器 + 冒烟自检。
#
# 模型两种准备方式：
#   ① 手动上传（默认，最稳）：./deploy.sh
#       模型缺时只创建目录并打印上传路径后停下——你把 GGUF 传进去，再跑一次 ./deploy.sh 即起服务。
#   ② 自动下载：./deploy.sh --download   或   AUTO_DOWNLOAD=1 ./deploy.sh
#       从 HuggingFace 拉 GGUF（源可覆盖：MODEL_HF_REPO=... MODEL_HF_FILE=... ./deploy.sh --download）。
set -euo pipefail
cd "$(dirname "$0")"

AUTO_DOWNLOAD="${AUTO_DOWNLOAD:-0}"
[ "${1:-}" = "--download" ] && AUTO_DOWNLOAD=1

MODEL_HF_REPO="${MODEL_HF_REPO:-gpustack/bge-reranker-v2-m3-GGUF}"
MODEL_HF_FILE="${MODEL_HF_FILE:-bge-reranker-v2-m3-Q8_0.gguf}"
MODEL_DIR="models/bge-reranker-v2-m3"
MODEL_PATH="$MODEL_DIR/$MODEL_HF_FILE"
PORT="${RERANK_SERVER_PORT:-8082}"

echo "==> [1/5] 环境检查"
command -v docker >/dev/null || { echo "!! 未装 docker"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "!! 需要 docker compose v2（docker compose ...）"; exit 1; }

echo "==> [2/5] 准备模型"
mkdir -p "$MODEL_DIR"
if [ -f "$MODEL_PATH" ]; then
  echo "    已就位：$MODEL_PATH（$(du -h "$MODEL_PATH" | cut -f1)），继续起服务"
elif [ "$AUTO_DOWNLOAD" = "1" ]; then
  echo "    自动下载：$MODEL_HF_REPO / $MODEL_HF_FILE"
  if command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli download "$MODEL_HF_REPO" "$MODEL_HF_FILE" \
      --local-dir "$MODEL_DIR" --local-dir-use-symlinks False
  else
    URL="https://huggingface.co/${MODEL_HF_REPO}/resolve/main/${MODEL_HF_FILE}"
    echo "    （无 huggingface-cli，用 curl 拉 $URL）"
    curl -fL --retry 3 -o "$MODEL_PATH.part" "$URL" && mv "$MODEL_PATH.part" "$MODEL_PATH" || {
      rm -f "$MODEL_PATH.part"
      echo "!! 下载失败（仓库/文件名不对、需代理、或源不可达）。"
      echo "   换源重试：MODEL_HF_REPO=<repo> MODEL_HF_FILE=<xxx.gguf> ./deploy.sh --download"
      echo "   或改手动：把 GGUF 放到 $MODEL_DIR/ 后跑 ./deploy.sh"
      exit 1; }
  fi
  echo "    完成：$MODEL_PATH（$(du -h "$MODEL_PATH" | cut -f1)）"
else
  # 手动模式：只建目录、给清晰指引，不当错误退出（这是"等上传"的正常状态）。
  echo "    模型未就位——已创建目录，等你上传后重跑。"
  echo
  echo "    请把 rerank GGUF 放到（容器会挂载这里）："
  echo "        $(pwd)/$MODEL_DIR/"
  echo "    期望文件名（或改 docker/.env 的 MODEL_FILE 指向你的实际文件名）："
  echo "        $MODEL_HF_FILE"
  echo "    例：scp bge-reranker-v2-m3-Q8_0.gguf 用户@本机:$(pwd)/$MODEL_DIR/"
  echo
  echo "    要点：必须是带分类头的 rerank GGUF（BGE 系转换普遍带；缺头会打分为 0/垃圾值）。"
  echo "    上传后再跑：./deploy.sh        （若想让脚本代下：./deploy.sh --download）"
  exit 0
fi

echo "==> [3/5] 准备 docker/.env（缺则从示例建）"
[ -f docker/.env ] || { cp docker/.env.docker.example docker/.env; echo "    已建 docker/.env（默认值，可按需改端口/GPU/MODEL_FILE）"; }

echo "==> [4/5] 构建并启动容器"
( cd docker && docker compose up -d )

echo "==> [5/5] 等待就绪 + 冒烟自检"
for i in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && { echo "    /health OK"; break; }
  [ "$i" = 60 ] && { echo "!! 60s 未就绪，查：cd docker && docker compose logs --tail=80"; exit 1; }
  sleep 2
done
echo "    重排打分自检（'25人'那条分应更高；若都是 0/垃圾值＝GGUF 缺分类头）："
curl -fsS "http://127.0.0.1:${PORT}/v1/rerank" -H 'Content-Type: application/json' -d '{
  "model":"bge-reranker-v2-m3","query":"培训人数超过20人",
  "documents":["某某培训项目","本次培训人数为25人"]}' | head -c 500; echo
echo
echo "✅ 完成 → 在 contract_radar 的 .env 设："
echo "     RERANK_BASE_URL=http://<本机或局域网IP>:${PORT}/v1"
echo "   再 docker compose up -d backend，即启用「深度」档片段重排。"
