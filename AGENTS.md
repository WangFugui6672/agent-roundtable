# Agent 行为规范

## 通用规则

1. 所有面向用户的回复统一使用中文。
2. 编写 Git Commit Message 时使用“英文类型 + 中文描述”，例如：`fix：修复 WebSocket 重连后消息重复`。本项目不要求提交前人工审核 commit message。
3. 读取、搜索和编辑文件时使用 harness 提供的 `read` / `grep` / `glob` / `edit` 工具；批量脚本只在必要时使用，并检查退出码。
4. 需要浏览器操作时使用外部浏览器。
5. 只有用户明确要求时才操作 IDE；默认通过文件系统工具和命令行完成工作。
6. 不盲目附和，发现需求、架构或实现风险时直接指出并给出可执行建议。

## 本地环境速查

- 后端：`make db-up` 起 PostgreSQL，`make backend-run` 起 `127.0.0.1:8000`；首次运行先 `make backend-migrate`。
- iOS 工程由 `ios/project.yml` 生成且不入库；增删文件后运行 `make ios-project` 再开 Xcode。
- iOS 单元测试：`make ios-test`；SwiftLint：`make ios-lint`（首次需 `brew install swiftlint`）。UI 测试需要本地后端，命令见 `README.md`「测试与检查」。
- Android：`make android-test`、`make android-lint`、`make android-core-purity`；JDK 与 SDK 要求见 `android/README.md`「环境要求」。
- 完整步骤与故障排查见 `README.md`「快速开始」。

## Git 提交类型

- `feat`：新增功能
- `fix`：修复 Bug
- `docs`：文档变更
- `style`：代码格式调整
- `refactor`：代码重构
- `perf`：性能优化
- `test`：新增或修改测试
- `chore`：杂项更新
- `revert`：回滚操作
- `build`：构建系统或外部依赖
- `ci`：CI/CD 配置

## 项目范围

- 实现与评审细则见 `docs/agents/coding-standards.md`。
- 产品需求以 `docs/PRD.md` 为准。
- 领域术语以 `GLOSSARY.md` 为准。
- iOS（`ios/`）与 Android（`android/`）客户端共用 `docs/protocol.md` 契约；Android 细则见 `android/README.md`。
- iOS 使用 SwiftUI、Swift Concurrency、URLSessionWebSocketTask 和 SwiftData。
- 后端使用 Django、Django REST Framework、Django Channels、PostgreSQL、Redis 和 Celery。
- 真实模型调用由 iOS 直接访问用户选择的 Provider，API Key 保存在 iOS Keychain。
- Django 不接触模型 API Key，也不代理用户自定义 BaseURL。
- MVP 不引入第二后端、跨平台 UI 框架或无限自动对话。
- LLM API Key 和签名密钥不得提交到仓库。

## Agent skills

### Issue tracker

GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary mapped one-to-one. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout. See `docs/agents/domain.md`.
