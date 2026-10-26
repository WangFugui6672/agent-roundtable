# Agent Roundtable

Agent Roundtable 是一个 iOS 原生的 AI 多智能体圆桌应用。用户提出议题并选择三个不同立场的 AI Agent，Agent 之间按照受控规则讨论、互相引用，最终收敛为共识、分歧和建议。

**当前阶段：** Issue #8「断线与进程恢复」—— 本地游标补发、乱序缓冲、SwiftData 恢复、离线只读和前后台连接管理已落地。

| 空圆桌 | Mock 一轮 |
| --- | --- |
| ![空圆桌](docs/assets/mock-empty-roundtable.png) | ![Mock 一轮](docs/assets/mock-round-events.png) |

截图来自 iPhone 17 模拟器上的 UI 测试（`AgentRoundtableUITests`），走的是真实本地 Django + WebSocket。

## 已完成的能力（切片）

- iOS 输入议题，选择固定的三个预设 Agent（方案派 / 质疑派 / 体验派）。
- Django 提供匿名会话、预设 Agent、圆桌、turn 和用户控制 REST 接口。
- PostgreSQL 持久化圆桌、参与者与事件日志。
- iOS 通过 WebSocket 进入空圆桌，展示参与者与连接状态。
- `mock.run` 触发一轮 11 个事件的 Mock 讨论，客户端解码并渲染。
- 事件带 `sequence` 与 `event_id`，支持按游标补发与客户端去重。
- Provider 设置页：三个预设、BaseURL / Model / API Key、验证连接、删除配置。
- API Key 只写入 Keychain（`WhenUnlockedThisDeviceOnly`）；非秘密配置存 `UserDefaults`。
- 创建圆桌时提交 Provider 元数据快照，后端拒绝任何携带 API Key 的请求。
- 真实 Agent 第一轮：服务端依次签发唯一 turn，iOS 直连 Provider 的 `/chat/completions`（SSE 流式）并执行单一在途 turn。
- turn 握手：`POST /turns/next` 返回稳定 `turn_id`；消息与 `pass` 必须回报当前 turn，重复或过期回报会被拒绝。
- `pass` 只产生可观察的 `agent.passed` 事件，不创建普通观点消息。
- 圆桌快照与 `room.joined` 携带 `active_turn`，重连后可识别在途 turn。
- 流式状态：思考 → 输入（逐字渲染）→ 提交 → 完成；Provider 401/403、402、404、429、超时、网络和空回复会映射为稳定失败码。
- Provider 失败会调用 `POST /turns/fail` 回报一次，保留 partial 和已完成消息；服务端关闭当前 turn 后可继续调度其他 Agent，客户端不会静默换 Provider、Model 或 Mock。
- SSE `usage` 与 `finish_reason` 会被解析；成功 message/pass 和失败回报都会携带可取得的 Token、延迟与重试数据。
- 服务端强制执行最多两轮、6 条 Agent 消息、单 turn 60 秒和整场 90 秒；客户端上报 Token 上限为 2400。
- `room.joined` 可恢复 `failures`，`agent.failed` 与 `budget.exhausted` 只产生一次；圆桌页展示简化预算、失败卡和结束原因。
- 同一匿名会话最多 3 个进行中圆桌；Mock 每 UTC 日最多 10 个，创建事务使用会话行锁防止并发穿透。
- 结构化消息提交：`POST /roundtables/{id}/messages`，后端校验类型、长度、引用归属后落库并广播 `message.completed`。
- 重新进入圆桌时，`room.joined` 会带回已持久化的发言。
- 用户消息使用独立 `user` 作者持久化，不再伪装成 Agent；`room.joined` 会恢复完整消息流。
- 用户可通过显式 `mentioned_agent_ids` 点名最多 3 个 Agent；正文中的 `@名字` 仅作展示，调度器优先选择有效被点名人。
- 用户插话后当前 Provider turn 会完成，服务端在安全边界进入 `paused`；暂停、继续和结束命令均可重复调用而不重复产生事件。
- 提前结束会取消服务端 pending turn，并取消 iOS 本地 Provider Task，结束后的消息和 turn 写入被拒绝。
- 圆桌页提供用户输入、mention 选择、暂停/继续/结束控件。
- 第一轮结束后，服务端在同一次 `turns/next` 事务中写入唯一的 `round.completed`，并立即签发第二轮 turn；客户端无需额外操作。
- 第二轮每位参与者最多一个 turn，只接受 `support / challenge / supplement / question`，且 `message_type` 必须与 `stance` 一致。
- 第二轮引用必须指向同一圆桌中更早产生的其他参与者有效观点；用户消息、自身、pass、summary、未知和跨圆桌消息都会被拒绝。
- `challenge` 必须携带 `challenge_target_agent_id`，目标必须是被引用观点的作者；其他立场不能携带挑战目标。
- iOS 第二轮要求 Provider 返回结构化 JSON，由 `StructuredReplyParser` 校验引用 ID/索引、挑战关系与置信度；格式错误只重试一次。
- 消息卡展示被引用观点的作者和原内容，并用文字与颜色区分四种立场；VoiceOver 会读出立场、引用内容和挑战对象。
- 第二轮结束后只产生一次 `round.completed`，圆桌进入 `completed`；`room.joined` 可恢复两轮完整消息和引用关系。
- WebSocket 使用可取消的指数退避重连，每次重连携带本机最后已处理游标。
- `room.joined.replay` 返回 90 天补发窗口；游标过期时使用完整快照重置，不会永久跳过缺口。
- iOS 按 `event_id` 和连续 `sequence` 去重/缓冲乱序事件，未知事件也会推进游标。
- SwiftData 保存最近圆桌、消息、失败、游标、有界去重状态和最近可见消息；App 重启直接恢复缓存。
- 断网时已有消息继续可读；App 进入后台会取消本地 Provider Task、暂停连接，回前台只恢复连接并要求用户显式继续。
- `AppModel` 已通过 `RoundtableRepository` 收口 REST、WebSocket、SwiftData 和游标编排；API Key 不进入 Repository 持久化状态。
- 后端单元/集成测试、iOS 解码/状态机/Provider/流式客户端测试、Keychain 集成测试、最小 GitHub Actions。

总结与结论卡见后续 Issue。

## 目录结构

```text
backend/                  Django + DRF + Channels
  roundtable/             项目配置（settings / asgi / urls）
  apps/roundtables/       领域模型、REST、WebSocket consumer、Mock 脚本、测试
ios/
  project.yml             XcodeGen 工程定义（生成的 .xcodeproj 不入库）
  AgentRoundtable/        SwiftUI App（创建页、Provider 设置、圆桌页、AppModel）
  AgentRoundtableTests/   App 单元测试（Keychain 集成）
  AgentRoundtableUITests/ 端到端 UI 测试
  RoundtableCore/         SwiftPM 包：模型、事件解码、REST/WS 客户端、圆桌状态机、Provider 与流式客户端
docs/
  PRD.md                  产品需求
  protocol.md             REST + WebSocket 协议（唯一接口契约）
  adr/                    架构决策记录
  agents/coding-standards.md  编码与评审判例
docker-compose.yml        本地 PostgreSQL
```

## 快速开始

### 后端

需要 Docker 与 [uv](https://docs.astral.sh/uv/)（Python 3.12 由 uv 管理）。

```bash
cp .env.example .env  # 可选：本地配置（后端启动时会读取）
make db-up            # 启动 PostgreSQL
make backend-install  # uv sync
make backend-migrate  # 建表 + 写入三个预设 Agent
make backend-run      # http://127.0.0.1:8000
```

健康检查：`curl http://127.0.0.1:8000/api/v1/health`

### iOS

需要 Xcode 16+（含 iOS 17 模拟器）与 XcodeGen：

```bash
brew install xcodegen
make ios-project                 # 生成 ios/AgentRoundtable.xcodeproj
open ios/AgentRoundtable.xcodeproj
```

后端地址默认 `http://localhost:8000`，可在 scheme 的环境变量 `RT_API_BASE_URL` 覆盖（真机调试时填局域网地址）。Info.plist 只对 `localhost` / `127.0.0.1` 放开 HTTP（`NSExceptionDomains`），上线前必须移除；生产环境要求 HTTPS/WSS。

进入 App 后：输入议题 → 确认三个参与者 → 开始讨论 → 配置 Provider 后启动自动讨论，或点击 Mock 查看确定性演示事件。圆桌页底部可以发送普通消息、点名 Agent、暂停、继续或提前结束。

创建页的「模型 Provider」可以打开 Provider 设置：选 Qwen / DeepSeek / 自定义，填写 BaseURL、Model 与 API Key。API Key 只写入 Keychain，不会出现在 `UserDefaults`、日志或后端请求里；「验证连接」会调用该服务的 `GET /models` 判断 Key 与地址是否可用（不消耗 Token）。未配置 Provider 时仍可用 Mock 演示。

进入圆桌后，iOS 会向服务端获取下一位发言人并用已配置的 Provider 发起真实流式发言：思考 → 逐字输入 → 提交 turn → 获取下一位。用户插话或暂停不会中断正在生成的这一条消息，但完成后会停在暂停边界；继续只重新启动一条自动流程。模型不可达、Key 失效、限流等情况会直接显示稳定错误码、可重试范围和 partial，并回报一次失败；不会自动切换到 Mock 或其他模型。Provider Token 由 iOS 从 SSE usage 中读取并上报，后端只把它当作客户端观测值，不作为精确计费依据。

## 测试与检查

```bash
make verify       # ruff + pytest + RoundtableCore 编译 + SwiftLint
make backend-test # 后端测试（turn 调度、失败/预算/限流、用户控制、WebSocket、消息校验与广播）
make ios-test     # RoundtableCore 测试（需要 Xcode 提供 XCTest）
make ios-lint     # SwiftLint --strict（首次需 brew install swiftlint）
make ios-app-test # App 单元测试（Keychain、Provider、三 Agent turn 编排，需模拟器签名）
```

UI 测试会真实创建圆桌并播放一轮 Mock，默认连 `http://localhost:8000`。先启动后端，再运行：

```bash
cd backend && DJANGO_DEBUG=1 uv run python manage.py runserver 0.0.0.0:8000
cd ios && xcodebuild test -project AgentRoundtable.xcodeproj -scheme AgentRoundtable \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -collect-test-diagnostics never
```

`-collect-test-diagnostics never` 可以避免 Xcode 27 在测试结束后卡在模拟器诊断收集（表现为命令长时间不退出）。

iOS 单元测试使用 XCTest，必须由带 Xcode 的工具链执行（纯 Command Line Tools 不包含 XCTest）。Keychain 测试需要模拟器的 ad-hoc 签名（`CODE_SIGNING_ALLOWED=NO` 会让 Keychain 返回 `errSecMissingEntitlement`），所以用 `make ios-app-test` 或去掉该参数的 `xcodebuild test`。CI 的 `iOS` job 在 `macos-15` 上执行 SwiftLint、`swift test` 与模拟器编译（`build-for-testing`）。

## 协议

接口细节以 [`docs/protocol.md`](docs/protocol.md) 为准，包括：

- REST 错误信封与状态码。
- 事件信封（`event_id` / `sequence` / `created_at`）与时间戳格式。
- `room.joined` 的序号为 0、不推进游标的约定。
- 创建圆桌时的 Provider 元数据快照，以及后端拒绝 `api_key` 字段的约定。
- turn 握手、`active_turn` 恢复、消息/pass 的 turn 校验。
- 第二轮自动推进、四种立场、有效观点引用和 challenge target 校验。
- 用户消息、显式 mention、pause_pending、暂停/继续/结束和幂等语义。
- `turns/fail`、稳定 failure code、usage、`agent.failed` 与 `budget.exhausted` 的恢复语义。
- 两轮/消息数/时间/客户端上报 Token 预算，以及活跃圆桌和 Mock 每日限额。
- `mock.run` 确定性演示命令与一轮 Mock 的事件顺序。

## 设计要点

- **事件日志而非纯广播**：实时事件落库，重连按游标补发（[ADR 0002](docs/adr/0002-persisted-event-log-with-resume-cursor.md)）。
- **核心逻辑独立成包**：解码、去重、游标与 REST 客户端可在 macOS 上快速测试，SwiftUI 只做展示（[ADR 0003](docs/adr/0003-xcodegen-project-and-core-package.md)）。
- **密钥不进后端**：BYOK 的 API Key 只存 iOS Keychain、请求由 iOS 直连 Provider（[ADR 0001](docs/adr/0001-byok-keychain-direct-provider.md)）。后端收到任何 `api_key` 字段会直接返回 400，避免误上传被静默忽略。
- **Provider 逻辑与 Keychain 分离**：`SecretStore` 协议让 Provider 生命周期可以在没有 Keychain 的 CI 机器上测试；真实 Keychain 行为由模拟器上的集成测试覆盖。
- **流式在客户端、校验在服务端**：模型输出由 iOS 逐字渲染，协议信封（类型、立场、claim、conﬁdence）由 `MessageComposer` 组装；Django 只做校验与持久化，所以模型返回纯文本也不会破坏协议。
- **预算诚实分层**：服务端强制可观察的轮数、消息数、Turn 截止时间和整场时间；由于 BYOK 直连，Token 上限只能基于 iOS 上报的 Provider usage，不能伪装成服务端计费。

## 已知边界

- `mock.run` 保留为确定性演示与 UI 测试入口；真实两轮讨论由 turn REST 握手驱动。
- Redis 与 Celery 尚未接入：事件广播暂时使用 Channels 的 `InMemoryChannelLayer`，只在单进程内有效；事件日志补发本身已持久化。
- Provider Token 仍以客户端上报为权威观测值；Provider 未返回 usage 时只记录延迟与重试，不伪造 Token。
- 事件补发窗口默认 90 天；窗口外只返回完整圆桌快照并标记 `cursor_expired`。
- 两轮讨论都由服务端顺序签发 turn；第一轮结束时同一响应自动签发第二轮。
- `agent.thinking` 由服务端持久化；`agent.typing` 与逐字文本仍是客户端本地临时状态。
- 第一轮消息的 `message_type` / `stance` 由预设角色推导；第二轮由模型返回结构化字段，客户端校验后提交，后端再次校验。
- 第二轮引用与挑战关系已持久化并可恢复；引用卡展示原观点摘要，不额外加载被引用消息全文的历史版本。
- SwiftLint 已接入（`ios/.swiftlint.yml`，`make verify` 与 CI 都执行 `--strict`）；UI 测试仍未在 CI 执行（需要本地后端），CI 只做 `build-for-testing`。
- Keychain 集成测试依赖模拟器 ad-hoc 签名，目前只在本地执行；CI 只编译测试包。
- `RoundtableRepository` 持有圆桌 API、WebSocket、本地存储和游标；`AppModel` 只负责会话、Provider turn 与 UI 状态编排。
- 匿名会话 ID 目前存 `UserDefaults`，它只是能力凭据、不含模型密钥；会话轮换与安全存储随隐私 Issue（#11）处理。

## 故障排查

- **创建圆桌返回 500，但测试全绿**：本地 `manage.py runserver --noreload` 起的进程不会加载新代码，模型或序列化器改动后必须重启后端。
- **Keychain 操作返回 `-34018`（`errSecMissingEntitlement`）**：模拟器构建没有签名。去掉 `CODE_SIGNING_ALLOWED=NO`，或使用 `make ios-app-test`。

## 开发约定

- 产品需求以 `docs/PRD.md` 为准，领域术语以 `GLOSSARY.md` 为准。
- 所有功能改动通过 Pull Request；提交信息使用「英文类型 + 中文描述」。
- 不提交 LLM API Key、签名密钥和真实 `.env`。
