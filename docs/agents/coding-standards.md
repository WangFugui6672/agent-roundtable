# 编码规范（判例）

本文件记录 code review 中反复出现的判断，避免同一条标准在不同 PR 里被反复讨论。产品需求以 `docs/PRD.md` 为准，领域术语以 `GLOSSARY.md` 为准；本文件只补充「怎么写」。

## 通用

- 面向用户的文案统一用中文；标识符、协议字段、日志用英文。
- 能用一个类型表达的「同一组字段」不要用三个参数传来传去（例如 `ProviderDraft` 代替 `kind/baseURL/model/apiKey` 四连参）。
- 不为「以后可能要用」加抽象；等真实调用点出现再加。
- 违反本文件某一条时，在 PR 描述里写明理由和补偿措施（测试、Issue 链接）。

## 协议

- `docs/protocol.md` 是唯一接口契约：改请求/响应/事件信封的同一个 PR 里必须同步。
- 文档示例必须是实际会返回的形状，包括错误 `details`（例如拒绝 `api_key` 时是 `{"provider": ["..."]}`，不是 `{}`）。
- 新增字段优先「可选 + 缺省语义明确」，避免破坏旧客户端。
- `room.joined` 的 `sequence = 0` 是游标语义的一部分，不能改成 1 或省略。
- 未知 `event_type` 必须被忽略，但游标仍要前进。
- 服务端只补发约定窗口内的事件；游标过期必须返回完整 `room.joined` 快照和 `replay.cursor_expired`，不能静默跳过缺口。

## 密钥与安全

- LLM API Key 只允许出现在两处：iOS Keychain，或直连 Provider 的请求头。禁止进入 `UserDefaults`、`SwiftData`、日志、崩溃上报和后端请求体。
- 后端收到任何 `api_key` 形态字段直接 400（`contains_secret`），不要静默忽略——静默会掩盖客户端泄漏。
- Keychain item 使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`；删除 Provider 必须同时删除 item。
- 修改 BaseURL 后不得复用旧 Key：旧 Key 可能属于另一个服务。
- 缺失 Key 时要求用户重新输入（`ProviderAvailability.incomplete`），不允许静默降级成 Mock。
- `SecureField` 不设置 `.textContentType(.password)`，避免进入系统密码 AutoFill / iCloud Keychain。

## iOS

- 展示层（SwiftUI）只做渲染与交互；解码、去重、游标、Provider 生命周期放在 `RoundtableCore`，可以在 macOS 上跑测试。
- 网络/存储通过协议注入（`HTTPTransport`、`SecretStore`、`ProviderConfigurationStorage`），测试用内存实现，不依赖真实 Keychain 或网络。
- 新增文件后运行 `make ios-project`；`.xcodeproj` 不入库。
- `AppModel` 是会话编排器；圆桌 REST、WebSocket、SwiftData 与游标由 `RoundtableRepository` 统一持有。`ProviderStore` / `ProviderProbe` 仍由 `AppModel` 的 Provider 扩展管理。
- 本地持久化以本机已处理游标为准；`room.joined` 的正常快照不能覆盖它。只有快照明确 `cursor_expired` 时才允许按完整快照重置。
- API Key 不得进入 `StoredRoomState`、SwiftData payload、日志或普通缓存。
- UI 标识符（accessibilityIdentifier）用 `feature.element` 形式，便于 UI 测试定位。

## 后端

- 错误统一走 `roundtable.exceptions` 的信封，`code` 稳定、`message` 只用于展示。
- 时间戳只用 `protocol.iso8601_millis`（毫秒 + `Z`）。
- 序列化器负责校验与归一化（例如 BaseURL 去尾斜杠）；模型不要塞展示逻辑。
- 用空串表示「未配置」是本项目的既定做法（`provider_kind = ""`），改成可空列需要独立迁移与协议兼容评估。

## 测试

- 先写测试再实现（红 → 绿 → 重构）；一个测试只验证一个行为。
- 断言可观察行为；只有「密钥不外泄」这类安全性质才允许断言存储内部结构。
- 测试替身放测试目标内；跨测试目标重复的小替身可以接受，不为此新建共享库。
- Keychain 相关测试需要模拟器 ad-hoc 签名（`CODE_SIGNING_ALLOWED=NO` 会得到 `errSecMissingEntitlement`）。
- UI 测试依赖本地后端（`http://localhost:8000`），CI 只编译不执行；新增 UI 测试时用 `-collect-test-diagnostics never` 避免 xcodebuild 在收尾阶段挂起。

## 工具与 CI

- Swift 代码必须通过 `make ios-lint`（SwiftLint `--strict`），配置见 `ios/.swiftlint.yml`。
- 后端必须通过 `ruff check` 与 `ruff format --check`。
- `make verify` 是本机提交前的最小验证：后端 lint + 测试 + iOS 编译 + SwiftLint。
- 生成物（`ios/AgentRoundtable.xcodeproj`、`ios/AgentRoundtable/Info.plist`、`.build`）不入库。
