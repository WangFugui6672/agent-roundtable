# Agent Roundtable

Agent Roundtable 是一个 iOS 原生的 AI 多智能体圆桌应用。用户提出议题并选择三个不同立场的 AI Agent，Agent 之间按照受控规则讨论、互相引用，最终收敛为共识、分歧和建议。

**当前版本：** MVP `v0.1.0`。发布说明见 [`docs/releases/v0.1.0.md`](docs/releases/v0.1.0.md)。

[观看完整演示](docs/assets/demo-v0.1.0.mp4) · [演示封面（结论卡）](docs/assets/demo-v0.1.0-poster.png) · [三个演示议题与录制脚本](docs/demo.md) · [架构说明](docs/architecture.md)

| 空圆桌 | Mock 一轮 |
| --- | --- |
| ![空圆桌](docs/assets/mock-empty-roundtable.png) | ![Mock 一轮](docs/assets/mock-round-events.png) |

截图来自 iPhone 17 模拟器上的 UI 测试（`AgentRoundtableUITests`），走的是真实本地 Django + WebSocket。

## 平台能力矩阵

同一套协议（`docs/protocol.md`）、两个原生客户端。下表说明每项能力当前在哪些端可用。

| 能力 | iOS | Android |
| --- | :---: | :---: |
| 创建圆桌、选择三位 Agent | ✅ | ✅ |
| WebSocket 实时讨论、游标补发、事件去重 | ✅ | ✅ |
| 断线重连与进程重启恢复 | ✅ | ✅ |
| 用户控制：暂停 / 继续 / 插话 / 点名 / 结束 | ✅ | ✅ |
| BYOK 直连 Provider 的真实 Turn 执行 | ✅ | ✅ |
| 第二轮引用式互评 | ✅ | ✅ |
| 结论生成与展示 | ✅ | ✅ |
| Mock 演示 | ✅ | ✅ |
| 结论卡保存与分享 | ✅ | — |
| 消息举报、本地隐藏、关键观点、重新生成 | ✅ | — |
| 继续追问（follow-up） | ✅ | — |
| 资料库：本地文档导入与文档块切分 | — | ✅ |
| 端侧向量化检索（RAG） | — | ✅ |
| 端侧大模型推理（llama.cpp + 量化） | — | ✅ |

各端细节：[`ios/README.md`](ios/README.md) · [`android/README.md`](android/README.md)

资料库与端侧推理是 Android 独有能力，不作为跨端功能宣传；原因见 [`docs/adr/0006-on-device-rag-in-client.md`](docs/adr/0006-on-device-rag-in-client.md)。

## 端侧实测数据

以下数据来自 **Android 模拟器**（Medium_Phone，arm64-v8a，API 37，4 GB RAM），**不是真机**，仅用于验证链路可用性：

| 指标 | 数值 |
| --- | --- |
| 模型加载（Qwen2.5 0.5B Instruct Q4_K_M） | 828 ms |
| 首字延迟 | 1140–1957 ms |
| 解码速度 | 16.96–27.78 tokens/s |
| 推理峰值内存 | 762 MB |
| 模型体积（Q4_K_M / FP16） | 468.6 MiB / 1.18 GiB |
| 嵌入模型加载（bge-small-zh-v1.5 int8） | 131–226 ms |
| 单条文本向量化 | 7–27 ms |

真机数据尚未采集；模型文件不入库，需运行 `scripts/fetch_embedding_model.sh` 或从 Release 资产下载。

## 已完成的能力（切片）

### Android 客户端

- Kotlin + Jetpack Compose，`:app` 与 `:core` 两模块，`:core` 为纯 JVM 协议层。
- 创建圆桌、WebSocket 实时讨论、事件投影与按游标补发、进程重启恢复、删除墓碑。
- Provider 配置与探测；API Key 经 Android Keystore 加密后存入私有偏好，配置与密钥分离。
- 真实 Turn 执行：客户端组装 prompt、直连 Provider 流式生成、提交发言或选择沉默。
- 第二轮引用式互评：结构化 JSON 解析，校验类型、立场、引用归属与质疑目标。
- 用户控制：暂停（在途发言完成后生效）、继续、插话、点名、提前结束。
- 结论生成与展示，模型失败时规则化降级并明确标注。
- 资料库：PDF / TXT / Markdown 导入与文档块切分；端侧向量化与检索；检索结果注入 system prompt。
- 端侧推理：llama.cpp + Qwen2.5 0.5B Q4_K_M，展示加载耗时、首字延迟、解码速度与峰值内存。

### iOS 客户端

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
- 服务端强制执行最多两轮、6 条 Agent 消息、单 turn 60 秒和整场 600 秒；客户端上报 Token 只用于统计，不再作为结束条件。
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
- SwiftData 保存多桌历史、消息、失败、游标、有界去重状态、最近可见消息和删除墓碑；App 重启后从首页打开缓存圆桌。
- 首页合并服务端历史与本地 SwiftData 记录，展示进行中/已完成/已归档状态；打开缓存圆桌会恢复完整消息与滚动位置，离线仍可阅读。
- 断网时已有消息继续可读；App 进入后台会取消本地 Provider Task、暂停连接，回前台只恢复连接并要求用户显式继续。
- `AppModel` 已通过 `RoundtableRepository` 收口 REST、WebSocket、SwiftData 和游标编排；API Key 不进入 Repository 持久化状态。
- 第二轮或用户提前结束后进入 `summarizing`；服务端通过 `round.completed` / `room.ended` 与 `summary.started` 持久化该阶段，重连可恢复。
- iOS 使用当前 Provider 生成共识、分歧、建议、未决问题四组严格 JSON；每项映射到真实消息 ID，格式失败最多重试一次。
- Provider 不可用或连续两次结构非法时，客户端只从已有 claim/正文生成本地规则化摘要，并明确标记“降级总结”，不伪造引用。
- 后端使用独立 `RoundSummary` 实体保存结论，强制当前圆桌有效观点引用、长度和数量上限、API Key 拒绝与 `expected_version` 版本控制。
- 结论成功后圆桌进入只读 `completed`；Agent 消息、用户消息、turn 和暂停控制都会被服务端拒绝。
- 已完成圆桌可通过 `POST /follow-ups` 创建新圆桌，显式保存父圆桌、原总结和原议题上下文。
- 圆桌页按共识、分歧、建议、未决问题展示结论及引用原观点，并支持重新生成。
- 用户可把有效 AI 观点标记为关键观点，总结候选会优先排列这些观点；标记不修改正文，也不会删除消息。
- 用户可重新生成最近一条 AI 回复。服务端签发替代 turn，新消息通过 `supersedes_message_id` 关联旧消息；旧正文和既有引用保持可恢复。
- 结论卡由 SwiftUI 与 `ImageRenderer` 绘制，可保存相册并通过系统分享；卡片不含 API Key、内部 ID、Prompt、公开链接或二维码。
- `room.joined` 和 SwiftData 均持久化结论；进程重启后可恢复已完成圆桌与结论卡入口。
- 参与者、消息、生成状态和结论始终显示 AI 标识；只提供固定预设 Agent，不提供公众人物冒充或克隆。
- `RoundtableCore.ContentPolicy` 用可测试本地规则返回 `allow / block / flag`；阻断内容不会发送给 Django 或 Provider，标记内容会明确说明未经审核。
- 规则覆盖明显违法、危险、仇恨、未成年人性和公众人物冒充样本，并在 [`docs/content-safety.md`](docs/content-safety.md) 记录边界与误报策略。
- 真实 Provider 首次调用前显示第三方数据提示；取消不会发起 Provider 请求，确认状态只写 UserDefaults。
- 用户可举报当前圆桌的 AI 消息；举报服务端幂等保存为 `submitted`，不伪装成审核结论。
- 用户可在本机隐藏 AI 消息；隐藏、内容标记和举报状态保存到 SwiftData，不删除或改写服务端消息。
- `DELETE /roundtables/{id}` 幂等删除圆桌及消息、事件、回合、用量、结论和举报；iOS 同步清理本地缓存、隐藏状态和恢复游标，但保留 Keychain API Key。
- 服务端删除成功后，iOS 先落盘删除墓碑；即使后续本地清理失败，进程重启也不会恢复已删除圆桌。
- 圆桌按最后活动保留 90 天，`purge_roundtables` 清理任务支持 dry-run；匿名会话标识使用独立 Keychain item。
- 匿名会话支持轮换和整体删除：轮换后旧标识立即失效、已有圆桌归属新标识；删除会话级联清理服务端与本机数据，Provider API Key 保留。
- Celery worker 与 beat 每日执行保留清理任务，Redis 作为 broker；管理命令仍可用于手工 dry-run。
- GitHub Actions 执行后端全量检查、Compose 冷启动、secret scan、RoundtableCore、App 单测和完整 UI 回归。

## 目录结构

```text
backend/                  Django + DRF + Channels
  roundtable/             项目配置（settings / asgi / urls）
  apps/roundtables/       领域模型、REST、WebSocket consumer、Mock 脚本、测试
android/
  app/                    Compose 界面、平台能力、Provider、资料库与端侧推理
  core/                   纯 JVM 协议层、事件投影、RAG 与失败分类
  scripts/                llama.cpp 源码拉取
ios/
  README.md               iOS 构建、测试与录屏说明
  project.yml             XcodeGen 工程定义（生成的 .xcodeproj 不入库）
  AgentRoundtable/        SwiftUI App（创建页、Provider 设置、圆桌页、AppModel）
  AgentRoundtableTests/   App 单元测试（Keychain 集成）
  AgentRoundtableUITests/ 端到端 UI 测试
  RoundtableCore/         SwiftPM 包：模型、事件解码、REST/WS 客户端、圆桌状态机、Provider 与流式客户端
docs/
  PRD.md                  产品需求
  protocol.md             REST + WebSocket 协议（唯一接口契约）
  architecture.md         信任边界、运行时和数据流
  demo.md                 三个演示议题与录制脚本（iOS）
  demo-android.md         Android / 双端并排录制脚本
  content-safety.md       本地内容规则与隐私边界
  releases/               版本发布说明
  adr/                    架构决策记录
  agents/coding-standards.md  编码与评审判例
scripts/                  发布、Compose smoke、录制与 artifact 检查
docker-compose.yml        PostgreSQL + Redis + Django/Channels
```

## 快速开始

### 完整后端（推荐）

需要 Docker 与 Docker Compose：

```bash
cp .env.example .env
docker compose up --build --detach --wait
curl http://127.0.0.1:8000/api/v1/health
```

Compose 会启动 PostgreSQL、Redis、Django/Channels、Celery worker 和 Celery beat，并在 Web 服务启动前执行迁移。默认宿主机端口是 `8000` 和 PostgreSQL `5432`；端口冲突时使用 `BACKEND_PORT` / `POSTGRES_PORT`。90 天清理由 beat 每日调度，也可按需手工执行：

```bash
docker compose --profile ops run --rm purge
docker compose down
```

中国大陆网络构建 Docker 镜像时，可在 `.env` 指定可选 PyPI 镜像，避免官方源超时：

```dotenv
UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
```

该参数只影响镜像构建，不写入运行时配置；CI 默认继续使用官方 PyPI。

### 本地开发后端

需要 PostgreSQL、Docker 与 [uv](https://docs.astral.sh/uv/)（Python 3.12 由 uv 管理）。不设置 `REDIS_URL` 时使用单进程内存 Channels；多进程或公网部署必须设置 Redis。

```bash
cp .env.example .env  # 可选：本地配置（后端启动时会读取）
make db-up            # 启动 PostgreSQL
make backend-install  # uv sync
make backend-migrate  # 建表 + 写入三个预设 Agent
make backend-run      # http://127.0.0.1:8000
make backend-purge    # 可选：删除最后活动超过 90 天的圆桌
```

健康检查：`curl http://127.0.0.1:8000/api/v1/health`

### iOS

需要 Xcode 16+ 与 XcodeGen，构建、运行、测试与录屏说明见 [`ios/README.md`](ios/README.md)。

### Android

需要 JDK 17 与 Android SDK 37，构建、Provider 配置与端侧能力说明见 [`android/README.md`](android/README.md)。

## 测试矩阵

```bash
```bash
make verify        # 提交前最小检查
make backend-check # Ruff、format、Django check、migration check、pytest
make ios-test      # RoundtableCore XCTest
make ios-lint      # SwiftLint --strict
make ios-app-test  # App 单测
make ios-ui-test   # 完整 UI 回归
make docker-smoke  # 隔离 Compose 冷启动 + 迁移 + Redis + health + guest session
make secret-scan   # 密钥、.env 与生成物扫描
make release-check # 发布静态、后端、Core、App 与 Compose 门禁

cd android && ./gradlew :core:test :app:testDebugUnitTest :app:assembleDebug
```

iOS 的测试细节、签名要求与录屏步骤见 [`ios/README.md`](ios/README.md)；Android 的模块划分与端侧能力见 [`android/README.md`](android/README.md)。

GitHub Actions 并行执行五个 job：后端检查、Compose 冷启动、仓库卫生扫描、Android 构建与单元测试、iOS 单测与完整 UI 回归。

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
- 两轮/消息数/时间预算、客户端上报 Token 统计，以及活跃圆桌和 Mock 每日限额。
- `summary.started` / `summary.completed`、结论项 schema、有效观点引用和版本冲突。
- `completed` 只读边界，以及带 parent/source 与 `follow_up_context` 的继续追问。
- 幂等 AI 消息举报、幂等圆桌删除、90 天保留语义与清理任务。
- 本地内容策略、第三方数据提示、AI 标识和匿名会话 Keychain 存储。
- `mock.run` 确定性演示命令与一轮 Mock 的事件顺序。

## 设计要点

- **客户端直连与后端编排分层**：iOS 负责 Provider 调用和本地密钥；Django 负责 turn、顺序、预算、验证和持久化。完整拓扑见 [`docs/architecture.md`](docs/architecture.md)。
- **事件日志而非纯广播**：实时事件落库，重连按游标补发（[ADR 0002](docs/adr/0002-persisted-event-log-with-resume-cursor.md)）。
- **核心逻辑独立成包**：解码、去重、游标与 REST 客户端可在 macOS 上快速测试，SwiftUI 只做展示（[ADR 0003](docs/adr/0003-xcodegen-project-and-core-package.md)）。
- **密钥不进后端**：BYOK 的 API Key 只存 iOS Keychain、请求由 iOS 直连 Provider（[ADR 0001](docs/adr/0001-byok-keychain-direct-provider.md)）。后端收到任何 `api_key` 字段会直接返回 400，避免误上传被静默忽略。
- **Provider 逻辑与 Keychain 分离**：`SecretStore` 协议让 Provider 生命周期可以在没有 Keychain 的 CI 机器上测试；真实 Keychain 行为由模拟器上的集成测试覆盖。
- **流式在客户端、校验在服务端**：模型输出由 iOS 逐字渲染，协议信封（类型、立场、claim、conﬁdence）由 `MessageComposer` 组装；Django 只做校验与持久化，所以模型返回纯文本也不会破坏协议。
- **预算诚实分层**：服务端强制可观察的轮数、消息数、Turn 截止时间和整场时间；由于 BYOK 直连，Token 仅记录 iOS 上报的 Provider usage，既不伪装成服务端计费，也不作为不可靠的终止阈值。
- **结论与普通消息分离**：`RoundSummary` 独立版本化保存，不向消息流写伪 summary 消息，避免污染引用与调度。
- **降级不伪造依据**：规则化摘要只复制已有观点并引用原消息；Provider 失败时仍允许完成，但 UI 和协议都保留 `degraded` 标记。
- **本地安全与本地隐藏分离**：内容规则在发送边界执行；隐藏只改变本机 SwiftData 投影，举报单独提交且不产生审核结论。
- **删除与保留可审计**：服务端以圆桌最后活动为 90 天锚点并级联删除，本机删除缓存与游标，但 API Key 只由用户主动删除 Provider 时移除。

## 已知边界

- `mock.run` 保留为确定性演示与 UI 测试入口；真实两轮讨论由 turn REST 握手驱动。
- Compose 与生产配置使用 Redis Channel Layer；本地测试和单进程开发默认使用内存层，以保持测试无外部依赖。
- 90 天清理由 Compose 中的 Celery beat 每日调度 worker；`purge_roundtables` 管理命令仍可供运维手工执行。
- Provider Token 仍以客户端上报为权威观测值；Provider 未返回 usage 时只记录延迟与重试，不伪造 Token。
- 事件补发窗口默认 90 天；窗口外只返回完整圆桌快照并标记 `cursor_expired`。
- 两轮讨论都由服务端顺序签发 turn；第一轮结束时同一响应自动签发第二轮。
- `agent.thinking` 由服务端持久化；`agent.typing` 与逐字文本仍是客户端本地临时状态。
- 第一轮消息的 `message_type` / `stance` 由预设角色推导；第二轮由模型返回结构化字段，客户端校验后提交，后端再次校验。
- 第二轮引用与挑战关系已持久化并可恢复；引用卡展示原观点摘要，不额外加载被引用消息全文的历史版本。
- CI 的完整 UI 回归主要使用 Mock 事件，不验证外部 Provider 账号、余额、地区限制或真实模型输出质量。
- Keychain 集成测试依赖模拟器 ad-hoc 签名；CI 在 macOS runner 的模拟器上执行。
- `RoundtableRepository` 持有圆桌 API、WebSocket、本地存储和游标；`AppModel` 只负责会话、Provider turn 与 UI 状态编排。
- 后端可以验证结构、引用归属和版本，但无法证明模型生成的自然语言绝对没有隐含新事实；MVP 通过候选范围、强制引用和降级规则降低风险。
- 结论重新生成保留版本号和新 `summary.completed` 事件，不做公开分享链接、二维码或可导入房间。
- 匿名会话 ID 存在独立 Keychain service；旧 `UserDefaults` 值会在下次启动时迁移后删除。
- 本地内容规则是有限第一道过滤，不能覆盖所有语义变体；服务端不做模型审核，举报仅进入人工处理队列。
- TestFlight 未配置，需要 Apple Developer Program、App Store Connect、签名证书和 Provisioning Profile，不阻塞 MVP。
- **资料库、端侧向量化检索与端侧推理目前只在 Android 实现**，iOS 未接入；见 [`docs/adr/0006-on-device-rag-in-client.md`](docs/adr/0006-on-device-rag-in-client.md)。
- Android v1 未实现结论卡导出、消息举报、本地隐藏、关键观点、重新生成与继续追问；协议已支持，属后续切片。
- 端侧性能数据来自 Android 模拟器（arm64-v8a），**未做真机标定**；模型文件不入库，需运行拉取脚本或从 Release 资产下载。
- Android 的圆桌缓存使用 Room 单表存 JSON；iOS 使用 SwiftData，两端字段对齐，改字段需同时更新两侧解码器。

## 部署与隐私

- API Key 只允许出现在 iOS Keychain 和直连 Provider 的 `Authorization` 请求头中；Django、日志、SwiftData、UserDefaults 和 Git 仓库都不得保存。
- Compose 默认凭据只用于本地运行。公开部署前必须替换 `DJANGO_SECRET_KEY` 与 PostgreSQL 密码、限制网络入口，并启用 HTTPS/WSS。
- 服务端以圆桌最后活动为锚点保留 90 天；删除圆桌会级联清理消息、事件、turn、用量、结论和举报。Keychain Key 不受圆桌删除或保留期影响。
- 内容规则、误报策略和举报语义见 [`docs/content-safety.md`](docs/content-safety.md)。

## 故障排查

- **创建圆桌返回 500，但测试全绿**：本地 `manage.py runserver --noreload` 起的进程不会加载新代码，模型或序列化器改动后必须重启后端。
- **Keychain 操作返回 `-34018`（`errSecMissingEntitlement`）**：模拟器构建没有签名。去掉 `CODE_SIGNING_ALLOWED=NO`，或使用 `make ios-app-test`。

## 开发约定

- 产品需求以 `docs/PRD.md` 为准，领域术语以 `GLOSSARY.md` 为准。
- 所有功能改动通过 Pull Request；提交信息使用「英文类型 + 中文描述」。
- 不提交 LLM API Key、签名密钥和真实 `.env`。
