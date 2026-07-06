# bge-reranker-v2-m3 重排服务（llama.cpp, Docker）

合同雷达「深度」检索的片段重排服务。粗排（BM25/向量）出候选后，用 cross-encoder 对每个
候选的命中片段与检索意图打相关度分、重排，让最相关的先深读/先冒出。

**为什么是 bge-reranker-v2-m3**：llama.cpp 原生支持（`--reranking --pooling rank` 直接暴露
`/v1/rerank`，BGE 系是其中最成熟的一族，零新增组件）；XLM-R 底座、中文强；0.6B（Q8 ~640MB）；
与规划中的 bge-m3 嵌入同家族、选型/调优经验可复用；MIT 许可可自托管。
（不选 Qwen3-Reranker：其 GGUF 在 llama.cpp 上目前缺分类头/RANK 元数据、打分输出垃圾值，
运维负担不必要；接口层都是 /v1/rerank，日后支持稳定再切换不迟。）

## 部署

**一键（推荐）**：在 `Rerank/` 根目录跑 `./deploy.sh`——建 .env + 起容器 + 冒烟自检。模型准备两种方式：
- **手动上传（默认）**：`./deploy.sh` 若发现模型缺失，只创建目录并打印上传路径后停下；
  你把 GGUF 传进 `models/bge-reranker-v2-m3/`，再跑一次 `./deploy.sh` 即起服务。
- **自动下载**：`./deploy.sh --download`（换源：`MODEL_HF_REPO=... MODEL_HF_FILE=... ./deploy.sh --download`）。

**手动**：

```bash
# 1) 放模型：把 bge-reranker-v2-m3-Q8_0.gguf 放到 ./models/bge-reranker-v2-m3/
# 2) 起服务
cd docker
cp .env.docker.example .env        # 按需改端口/模型路径
docker compose up -d
docker compose logs -f             # 见 "server listening" 即就绪
```

显存：0.6B Q8 加激活封顶 ~2GB，放 GPU 0 与 Qwen 共存（Qwen 占 ~6.8GB 后仍剩 ~7GB+）。

## 自检

```bash
curl -s http://127.0.0.1:8082/health
curl -s http://127.0.0.1:8082/v1/rerank -H 'Content-Type: application/json' -d '{
  "model":"bge-reranker-v2-m3",
  "query":"培训人数超过20人",
  "documents":["某某培训项目","本次培训人数为25人"]
}'
# 期望 results 里"25人"那条 relevance_score 明显更高
```

## 接入后端

在 `contract_radar` 的 `.env` 设：

```bash
RERANK_BASE_URL=http://<本机或局域网IP>:8082/v1
# 可选：RERANK_MODEL（默认 bge-reranker-v2-m3）、RERANK_TIMEOUT（默认 30）、RERANK_API_KEY
```

未设 `RERANK_BASE_URL` → 后端跳过重排、行为不变（`retrieval/rerank.py` 整批降级回 rank 序）。
重排只在「深度」档生效，「快速」档恒不重排。
