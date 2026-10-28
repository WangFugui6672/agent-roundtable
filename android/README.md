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
```

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

### 模块边界

- `:core`：`DocumentChunker`、`KnowledgeBase`、`DocumentStore`、`DocumentParser`
  与文档模型，全部可在纯 JVM 单测中运行。
- `:app`：`AndroidDocumentParser` 负责 PDF 文本抽取（PDFBox-Android）与 TXT /
  Markdown 解码，通过 `DocumentParser` 接口注入 `:core`。
- `DocumentStore` 由 Room 实现（`RoomDocumentStore`），文档与文档块在同一事务中
  写入或删除；后续检索（#32）复用同一接缝。

PDF 解析依赖 `com.tom-roush:pdfbox-android:2.0.27.0`（Apache License 2.0，
传递依赖 Bouncy Castle，MIT 风格许可），没有 AWT 依赖；AAR 约 3 MB，会增大安装包。

## 依赖解析说明

若构建时出现 `Remote host terminated the handshake`，属于本机到 Maven 仓库的瞬时 TLS 失败，重试即可；Gradle 会缓存已完成的下载。

## 当前进度

Android 客户端已实现圆桌核心闭环（创建、实时讨论、用户控制、恢复与删除）以及
本机资料库的导入、分块、列表与删除。本地嵌入与检索见 Issue #32。
