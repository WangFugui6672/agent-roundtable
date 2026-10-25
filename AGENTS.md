# Agent 行为规范

## 通用规则

1. 所有面向用户的回复统一使用中文。
2. 编写 Git Commit Message 时使用“英文类型 + 中文描述”，例如：`fix：修复 WebSocket 重连后消息重复`。
3. 执行 `git commit` 前，必须先将 Commit Message 交给用户审核。
4. 读取、搜索、分析和编辑本地文件时，直接使用文件系统工具，例如 `rg`、`sed`、`find`、`apply_patch`。
5. 需要浏览器操作时使用外部浏览器，不调用 Codex 内置浏览器。
6. 只有用户明确要求时才操作 IDE；默认通过文件系统工具和命令行完成工作。
7. 不盲目附和，发现需求、架构或实现风险时直接指出并给出可执行建议。

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

- 产品需求以 `docs/PRD.md` 为准。
- 领域术语以 `GLOSSARY.md` 为准。
- 客户端采用 iOS 先行、Android 后补的顺序。
- iOS 使用 SwiftUI、Swift Concurrency、URLSessionWebSocketTask 和 SwiftData。
- 后端使用 Django、Django REST Framework、Django Channels、PostgreSQL、Redis 和 Celery。
- 真实模型调用由 iOS 直接访问用户选择的 Provider，API Key 保存在 iOS Keychain。
- Django 不接触模型 API Key，也不代理用户自定义 BaseURL。
- MVP 不引入第二后端、跨平台 UI 框架或无限自动对话。
- LLM API Key 和签名密钥不得提交到仓库。

## Agent skills

### Issue tracker

GitHub Issues. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context layout. See `docs/agents/domain.md`.

