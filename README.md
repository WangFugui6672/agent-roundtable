# Agent Roundtable

Agent Roundtable 是一个 iOS 原生的 AI 多智能体圆桌应用。用户提出议题并选择三个不同立场的 AI Agent，Agent 之间按照受控规则讨论、互相引用，最终收敛为共识、分歧和建议。

**当前阶段：** Issue #2「Mock 圆桌纵向切片」—— 无真实模型调用，用确定性 Mock 打通「创建圆桌 → 进入圆桌 → 实时事件往返」的完整链路。

| 空圆桌 | Mock 一轮 |
| --- | --- |
| ![空圆桌](docs/assets/mock-empty-roundtable.png) | ![Mock 一轮](docs/assets/mock-round-events.png) |

截图来自 iPhone 17 模拟器上的 UI 测试（`AgentRoundtableUITests`），走的是真实本地 Django + WebSocket。

## 已完成的能力（切片）

- iOS 输入议题，选择固定的三个预设 Agent（方案派 / 质疑派 / 体验派）。
- Django 提供匿名会话、预设 Agent、创建圆桌、读取圆桌四个 REST 接口。
- PostgreSQL 持久化圆桌、参与者与事件日志。
- iOS 通过 WebSocket 进入空圆桌，展示参与者与连接状态。
- `mock.run` 触发一轮 11 个事件的 Mock 讨论，客户端解码并渲染。
- 事件带 `sequence` 与 `event_id`，支持按游标补发与客户端去重。
- 后端单元/集成测试、iOS 解码与状态机测试、最小 GitHub Actions。

真实 Provider、流式输出、轮次调度器、总结、结论卡、断线重连见后续 Issue。

## 目录结构

```text
backend/                  Django + DRF + Channels
  roundtable/             项目配置（settings / asgi / urls）
  apps/roundtables/       领域模型、REST、WebSocket consumer、Mock 脚本、测试
ios/
  project.yml             XcodeGen 工程定义（生成的 .xcodeproj 不入库）
  AgentRoundtable/        SwiftUI App（创建页、圆桌页、AppModel）
  RoundtableCore/         SwiftPM 包：模型、事件解码、REST/WS 客户端、圆桌状态机与测试
docs/
  PRD.md                  产品需求
  protocol.md             REST + WebSocket 协议（唯一接口契约）
  adr/                    架构决策记录
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

进入 App 后：输入议题 → 确认三个参与者 → 开始讨论 → 在空圆桌点击「播放 Mock 一轮」查看实时事件。

## 测试与检查

```bash
make verify       # ruff + pytest + RoundtableCore 编译
make backend-test # 30 个后端测试（含 WebSocket 集成测试）
make ios-test     # RoundtableCore 单元测试（需要 Xcode 提供 XCTest）
```

UI 测试会真实创建圆桌并播放一轮 Mock，默认连 `http://localhost:8000`。先启动后端，再运行：

```bash
cd backend && DJANGO_DEBUG=1 uv run python manage.py runserver 0.0.0.0:8000
cd ios && xcodebuild test -project AgentRoundtable.xcodeproj -scheme AgentRoundtable \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

iOS 单元测试使用 XCTest，必须由带 Xcode 的工具链执行（纯 Command Line Tools 不包含 XCTest）。CI 的 `iOS` job 在 `macos-15` 上执行 `swift test` 与模拟器编译。

## 协议

接口细节以 [`docs/protocol.md`](docs/protocol.md) 为准，包括：

- REST 错误信封与状态码。
- 事件信封（`event_id` / `sequence` / `created_at`）与时间戳格式。
- `room.joined` 的序号为 0、不推进游标的约定。
- `mock.run` 临时命令与一轮 Mock 的事件顺序。

## 设计要点

- **事件日志而非纯广播**：实时事件落库，重连按游标补发（[ADR 0002](docs/adr/0002-persisted-event-log-with-resume-cursor.md)）。
- **核心逻辑独立成包**：解码、去重、游标与 REST 客户端可在 macOS 上快速测试，SwiftUI 只做展示（[ADR 0003](docs/adr/0003-xcodegen-project-and-core-package.md)）。
- **密钥不进后端**：BYOK 的 API Key 只存 iOS Keychain、请求由 iOS 直连 Provider（[ADR 0001](docs/adr/0001-byok-keychain-direct-provider.md)）。

## 已知边界

- `mock.run` 由客户端触发，是切片阶段的临时驱动；Issue #5 的调度器落地后改由服务端自动推进。
- Redis 与 Celery 尚未接入：当前切片没有跨进程广播与异步任务的需要，等调度器/总结阶段再引入。
- iOS 端暂未接入 SwiftData 本地缓存与断线重连退避策略（Issue #8）。
- PRD 18.5 要求的 SwiftLint/SwiftFormat 尚未接入：CI 目前覆盖后端检查、RoundtableCore 测试、iOS 编译与 UI 测试编译（`build-for-testing`），不执行 UI 测试（需要本地后端）。
- AppModel 暂时直接持有 `APIClient`；PRD 12.3 的 Repository/UseCase 分层随本地缓存与断线恢复（Issue #8）一起引入。
- 匿名会话 ID 目前存 `UserDefaults`，它只是能力凭据、不含模型密钥；会话轮换与安全存储随隐私 Issue（#11）处理。

## 开发约定

- 产品需求以 `docs/PRD.md` 为准，领域术语以 `GLOSSARY.md` 为准。
- 所有功能改动通过 Pull Request；提交信息使用「英文类型 + 中文描述」。
- 不提交 LLM API Key、签名密钥和真实 `.env`。
