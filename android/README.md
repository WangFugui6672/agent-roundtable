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

## 依赖解析说明

若构建时出现 `Remote host terminated the handshake`，属于本机到 Maven 仓库的瞬时 TLS 失败，重试即可；Gradle 会缓存已完成的下载。

## 当前进度

首个切片（工程骨架与 CI）已交付：App 可安装启动并展示首页空态，支持深色模式与系统字体缩放。
后续切片见 Issue #20。
