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

## 端侧推理（llama.cpp）

首页右上角的「端侧」进入本地推理页：加载 GGUF 模型、发起一次本地生成、逐字显示输出，
并展示模型体积、加载耗时、首字延迟、解码速度与推理峰值内存。

### 分层与接口

`:core` 只定义与框架无关的接口和规则，UI 与 ViewModel 均不引用 llama.cpp：

| 类型 | 作用 |
| --- | --- |
| `LocalInferenceEngine` | 加载、流式生成、取消、卸载 |
| `LocalModel` / `LocalModelCatalog` | 模型清单：文件名、体积、SHA256、下载地址 |
| `LocalInferencePolicy` | 设备内存 / 32 位检查，决定入口是否可用 |
| `LocalInferenceMetrics` | 加载耗时、首字延迟、token 数、解码耗时、峰值内存 |
| `Sha256` | 模型下载后的完整性校验 |

`:app` 提供 `LlamaCppEngine`（JNI 实现）、`AndroidLocalModelStore`（下载 / 导入 / 校验）
与 `AndroidDeviceMemoryProbe`（`ActivityManager` 与 `VmHWM`）。替换推理框架时只改 `:app`。

JNI 封装位于 `app/src/main/cpp/llama_bridge.cpp`，改编自 llama.cpp 官方
`examples/llama.android`（MIT），文件头已注明来源与许可证。llama.cpp 源码不入库：
`scripts/fetch_llama_cpp.sh` 从固定的源归档拉取 v0.5.0，`./gradlew :app:assembleDebug`
会先执行 `:app:fetchLlamaCpp`。

所需环境：NDK `29.0.14206865`、CMake `3.31.6`（均可由 `sdkmanager` 安装）。

### 模型与分发

- 模型：Qwen2.5 0.5B Instruct（Apache-2.0），中文 Instruct，0.5B。
- 量化：GGUF Q4_K_M，491,400,032 字节（468.6 MiB）。
- 模型文件不入库、不打进 APK。`LocalModelCatalog` 首选本仓库 Release 资产
  `models-v1`，不可用时回退到 ModelScope 上游镜像；两种来源都必须通过清单中的
  SHA256 才允许加载。**当前分支尚未上传 `models-v1` Release 资产，实际下载会走镜像**；
  也可以把同一份 GGUF 用系统文件选择器导入（按 SHA256 匹配清单）。
- 校验入口：下载完成后写入 `.sha256` 标记；已有文件在首次打开页面时重新计算 SHA256。
- 维护者发布资产（不在本分支执行，仅记录部署步骤）：

  ```bash
  gh release create models-v1 --title "端侧模型" --notes "Qwen2.5 0.5B Instruct GGUF"
  gh release upload models-v1 qwen2.5-0.5b-instruct-q4_k_m.gguf
  ```

  资产的文件名和 SHA256 必须与 `LocalModelCatalog` 一致；否则客户端会拒绝加载。

### 实测数据（模拟器数据，非真机）

测试环境：Android Emulator `Medium_Phone`，arm64-v8a，Android 17（API 37），
Google APIs Play Store 16K page 镜像，模拟器报告 4 GB RAM；主机为 Apple Silicon macOS。
llama.cpp 使用 2 线程、`n_ctx = 2048`、`n_batch = 512`，采样温度 0.7 / top_k 40 / top_p 0.95。
**以下均为模拟器数据，未在真机验证。**

| 指标 | Q4_K_M | FP16 |
| --- | --- | --- |
| 模型体积 | 468.6 MiB（491,400,032 B） | 1.18 GiB（1,266,425,696 B） |
| 模型加载耗时 | 828 ms | 未验证 |
| 首字延迟 | 1957 ms（另一次运行 1140 ms） | 未验证 |
| 解码速度 | 16.96 tokens/s（另一次运行 27.78 tokens/s） | 未验证 |
| 推理峰值内存（VmHWM） | 762 MB | 未验证 |

量化对比：FP16 体积约为 Q4_K_M 的 2.58 倍（+160.5%）。FP16 的解码速度本轮未验证：
该文件约 1.18 GiB，本轮没有下载并加载它，因此不把体积差异外推成速度结论。
Q4_K_M 两次运行的解码速度差异较大，是因为默认 prompt 的输出长度不同（7–30 个 token）；
表中保留两次实测值，不做平均。体积来自模型清单与上游文件元数据，不是估算值。

指标定义：首字延迟从调用生成到第一个输出 token 出现（含 prompt 预填充）；
解码速度只统计首 token 之后的解码阶段，`(token 数 - 1) / 解码耗时`；
峰值内存取进程 `/proc/self/status` 的 `VmHWM`。

### 失败时的行为

- 32 位设备、系统低内存、或「可用内存 < 模型体积 + 384 MiB 工作集」时，
  页面顶部显示不可用原因，下载/加载按钮禁用。
- 模型下载失败、SHA256 不匹配、原生库加载失败或模型加载失败时，
  只在本页展示错误；Provider 配置和圆桌讨论不读取端侧引擎，失败互不影响。
- 端侧引擎不参与服务端 Turn 执行，也不上报端侧数据。

## 依赖解析说明

若构建时出现 `Remote host terminated the handshake`，属于本机到 Maven 仓库的瞬时 TLS 失败，重试即可；Gradle 会缓存已完成的下载。

## 当前进度

已交付：工程骨架、匿名会话、实时讨论、Provider 配置与密钥、真实 Turn 执行与流式发言，
以及端侧推理切片（Qwen2.5 0.5B Instruct Q4_K_M + llama.cpp + JNI + 指标展示）。
后续切片见 Issue #20。
