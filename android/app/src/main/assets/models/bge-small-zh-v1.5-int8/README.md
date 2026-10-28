# bge-small-zh-v1.5 int8 模型资产

这个目录存放端侧嵌入模型，文件**不入库**：

- `model_int8.onnx`：BAAI/bge-small-zh-v1.5 的 int8 量化 ONNX 转换（512 维、4 层、约 22.8 MB）
- `vocab.txt`：BERT WordPiece 词表

在仓库根目录运行：

```bash
scripts/fetch_embedding_model.sh
```

脚本会从 Xenova/bge-small-zh-v1.5 的固定 commit 下载并校验 SHA256。发布构建
（`:app:assembleRelease`）会通过 `verifyEmbeddingModel` 任务确认两个文件存在；
debug 构建允许缺失，此时 App 自动降级为无检索。

模型许可：BAAI/bge-small-zh-v1.5 为 MIT。
