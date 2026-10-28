# Android 客户端

Agent Roundtable 的第二原生客户端。与 iOS 共用同一份协议契约（`docs/protocol.md`），不新增、不修改任何接口字段。

## 模块

| 模块 | 类型 | 职责 |
| --- | --- | --- |
| `:app` | Android Application | Compose 界面、平台能力、依赖注入 |
| `:core` | Android Library | 协议解码、事件投影、游标、缓存序列化、Provider 客户端、资料库与检索 |

`:core` 不依赖 Android 框架类，核心行为可在纯 JVM 上测试，因此 CI 无需启动模拟器即可覆盖。
分层对应 iOS 的 `ios/RoundtableCore`。

## 环境要求

- JDK 17
- Android SDK Platform 37、Build Tools 36
- Gradle 由 wrapper 提供（9.6.0），无需本地安装

首次构建前创建 `android/local.properties`（已被忽略，不会入库）：

```properties
sdk.dir=/path/to/Android/sdk
```

## 常用命令

```bash
cd android
./gradlew :core:test              # 协议层与检索的单元测试
./gradlew :app:testDebugUnitTest  # 应用层状态逻辑测试
./gradlew :app:assembleDebug      # 构建调试包
./gradlew :app:connectedDebugAndroidTest  # 需要已连接设备/模拟器，并先下载模型资产
```

模型资产通过 `scripts/fetch_embedding_model.sh` 下载（不入库）；上面的纯 JVM
单测不依赖模型。

调试包只包含 `arm64-v8a`，`minSdk 26`，包名 `com.agentroundtable.app`。

## 连接后端

默认后端地址是 `http://10.0.2.2:8000`（Android 模拟器访问宿主机的固定地址）。用其他地址构建：

```bash
./gradlew :app:assembleDebug -PbackendBaseUrl=http://127.0.0.1:8000
```

配合 `adb reverse tcp:8000 tcp:8000` 可以在真机上直接连本机后端。

## Provider 与密钥

API Key 只写入 Android Keystore（AES-GCM 加密后再存入私有偏好文件），
非秘密配置（类型 / BaseURL / 模型）单独保存，两者不混在一起。
修改 BaseURL 时必须重新输入密钥——旧密钥属于另一个服务商。

## 资料库

用户从系统文件选择器导入 PDF、TXT 或 Markdown 文档，文档在本机解析、切分为
**文档块（chunk）**并存入 `knowledge.db`。资料库界面展示每篇文档的名称与文档块数量，
删除文档时其全部文档块在同一事务内删除。

资料库完全本地：文档内容不经过 Django、不上传 Provider，也不在设备之间同步。
这符合 `docs/adr/0006-on-device-rag-in-client.md` 的端侧检索决定。

### 为什么 DOCX 不支持

`.docx` 是 ZIP 容器内的 OOXML，抽取文本需要额外的 OOXML 解析组件。本期只引入
纯 Java 的 `pdfbox-android` 处理 PDF，不引入依赖 AWT 的库，因此 DOCX 明确不支持；
界面会提示用户先另存为 PDF、TXT 或 Markdown。

### 分块规则

分块器 `DocumentChunker` 是 `:core` 中的纯函数：

1. 优先以空行分隔的段落为边界，能放进一个块的相邻段落会合并。
2. 单个段落超过 500 字符时，先按句末标点（`。！？!?；;…`、英文句点）切分。
3. 单句仍超过 500 字符时按上限硬切，不丢失内容。
4. 每个文档块最多 500 字符，相邻文档块重叠 50 字符，首块不重叠。

### 本地嵌入与检索

导入完成后，文档块在后台线程逐块转换成 512 维向量并保存到 `knowledge.db`。
资料库界面展示可感知的向量化进度；完成后展示端侧推理实测数据（模型加载、单条
文本推理、最近一篇文档的向量化耗时）。

- **模型**：`bge-small-zh-v1.5` int8 ONNX（`onnxruntime-android`），随安装包分发，
  不做运行时下载。模型文件不入库，首次构建前运行
  `scripts/fetch_embedding_model.sh` 下载并校验 SHA256。
- **检索器**：`:core` 中的纯函数 `Retriever`，输入查询向量与文档块向量，返回
  相似度达到 **0.45** 的检索结果，按相似度降序最多 **3** 条。
- **空资料库**：返回空检索结果，不报错；空资料库不会调用嵌入后端。
- **降级**：模型缺失、初始化失败或推理异常时，向量化返回失败结果，App 展示
  「端侧检索不可用」提示，资料库列表、导入、删除与圆桌功能不受影响。
- **测试**：`:core` 使用可预测的假嵌入后端验证检索逻辑，不依赖真实模型；
  `:app` 的 instrumented test 在模拟器/真机上加载真实模型做自检并打印实测数据。

模型加载与推理都在后台 dispatcher 上执行，不阻塞主线程。发布构建会通过
`verifyEmbeddingModel` 任务检查模型资产是否存在，防止漏带模型发版。

在 `Medium_Phone`（API 37，arm64）模拟器上的实测数据：

| 指标 | 实测 |
| --- | --- |
| 模型加载耗时 | 131–226 ms |
| 单条文本推理耗时 | 7–27 ms |
| 3 个文档块向量化（模型已加载） | 16–50 ms |
| 首次导入 1 个文档块（含模型加载） | 326 ms |
| 相关查询最高相似度 | 0.666 |
| 3 条无关查询的检索结果数 | 0 / 0 / 0 |

数据来自 `OnnxEmbeddingInstrumentedTest`（真实模型自检）与模拟器上的首次导入；
不同设备的 CPU、调度与磁盘缓存会让数值有波动。界面会在资料库中展示当前设备
最近一次的实际数值。

### 模块边界

- `:core`：`DocumentChunker`、`KnowledgeBase`、`DocumentStore`、`DocumentParser`、
  `EmbeddingBackend`、`Retriever`、`DocumentIndexer`、`KnowledgeSearch` 与文档模型，
  全部可在纯 JVM 单测中运行。
- `:app`：`AndroidDocumentParser` 负责 PDF 文本抽取（PDFBox-Android）与 TXT /
  Markdown 解码；`OnnxEmbeddingBackend` + `BertTokenizer` 负责 ONNX 推理，
  均通过接口注入 `:core`。
- `DocumentStore` 与 `ChunkVectorStore` 由 Room 实现（`RoomDocumentStore`），文档、
  文档块与向量共享一个数据库，删除文档时外键级联清理。

PDF 解析依赖 `com.tom-roush:pdfbox-android:2.0.27.0`（Apache License 2.0，
传递依赖 Bouncy Castle，MIT 风格许可），没有 AWT 依赖；AAR 约 3 MB，会增大安装包。

## 依赖解析说明

若构建时出现 `Remote host terminated the handshake`，属于本机到 Maven 仓库的瞬时 TLS 失败，重试即可；Gradle 会缓存已完成的下载。

## 当前进度

Android 客户端已实现圆桌核心闭环（创建、实时讨论、用户控制、恢复与删除）以及
本机资料库的导入、分块、列表、删除、端侧向量化与检索。
