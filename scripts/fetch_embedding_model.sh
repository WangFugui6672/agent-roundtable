#!/usr/bin/env bash
#
# 下载端侧嵌入模型（bge-small-zh-v1.5 int8 ONNX）与词表，并校验 SHA256。
#
# 模型文件不入库。发布包需要这两个文件：
#   android/app/src/main/assets/models/bge-small-zh-v1.5-int8/model_int8.onnx
#   android/app/src/main/assets/models/bge-small-zh-v1.5-int8/vocab.txt
#
# 用法：
#   scripts/fetch_embedding_model.sh [输出目录]
#
# 若要从 GitHub Release 资产分发，设置 EMBEDDING_MODEL_BASE_URL 指向资产目录
# （脚本会拼接 /model_int8.onnx 与 /vocab.txt）：
#   EMBEDDING_MODEL_BASE_URL=https://github.com/WangFugui6672/agent-roundtable/releases/download/<tag>/embedding \
#     scripts/fetch_embedding_model.sh
#
# 模型：BAAI/bge-small-zh-v1.5（MIT），int8 ONNX 转换来自 Xenova/bge-small-zh-v1.5。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${1:-$ROOT_DIR/android/app/src/main/assets/models/bge-small-zh-v1.5-int8}"
BASE_URL="${EMBEDDING_MODEL_BASE_URL:-https://huggingface.co/Xenova/bge-small-zh-v1.5/resolve/75c43b069aac4d136ba6bc1122f995fedcfd2781}"

MODEL_FILE="model_int8.onnx"
MODEL_SHA256="b9837c19ce154ff0726d398ee77abbc03a7faf0476c6f93016c84e531be7ebb5"
VOCAB_FILE="vocab.txt"
VOCAB_SHA256="45bbac6b341c319adc98a532532882e91a9cefc0329aa57bac9ae761c27b291c"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

fetch() {
    local name="$1"
    local expected="$2"
    local target="$DEST_DIR/$name"

    if [[ -f "$target" ]] && [[ "$(sha256_of "$target")" == "$expected" ]]; then
        printf '已存在且校验通过：%s\n' "$target"
        return
    fi

    mkdir -p "$DEST_DIR"
    local temporary="$target.download"
    printf '下载 %s ...\n' "$name"
    curl -fL --retry 5 --retry-delay 2 -o "$temporary" "$BASE_URL/$name"

    local actual
    actual="$(sha256_of "$temporary")"
    if [[ "$actual" != "$expected" ]]; then
        rm -f "$temporary"
        printf 'SHA256 校验失败：%s\n期望：%s\n实际：%s\n' "$name" "$expected" "$actual" >&2
        exit 1
    fi

    mv "$temporary" "$target"
    printf '校验通过：%s\n' "$target"
}

fetch "$MODEL_FILE" "$MODEL_SHA256"
fetch "$VOCAB_FILE" "$VOCAB_SHA256"

cat <<'NOTE'

模型已就绪。文件不会进入 Git；发布构建会通过 verifyEmbeddingModel 任务确认它们存在。
模型许可：BAAI/bge-small-zh-v1.5 为 MIT。若要随 GitHub Release 分发，请把
model_int8.onnx 与 vocab.txt 作为 Release 资产上传，并设置 EMBEDDING_MODEL_BASE_URL。
NOTE
