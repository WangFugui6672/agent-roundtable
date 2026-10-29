# iOS 客户端

Agent Roundtable 的第一个原生客户端。与 Android 共用同一份协议契约（`docs/protocol.md`），不新增或修改任何接口字段。

## 模块

| 模块 | 职责 |
| --- | --- |
| `AgentRoundtable/` | SwiftUI App：创建页、Provider 设置、圆桌页、`AppModel` |
| `AgentRoundtableTests/` | App 单元测试（Keychain 集成等） |
| `AgentRoundtableUITests/` | 端到端 UI 回归 |
| `RoundtableCore/` | SwiftPM 包：模型、事件解码、REST/WS 客户端、圆桌状态机、Provider 与流式客户端 |

## 环境要求

- Xcode 16+（含 iOS 17 模拟器）
- XcodeGen：`brew install xcodegen`

## 构建与运行

```bash
make ios-project                 # 生成 ios/AgentRoundtable.xcodeproj（.xcodeproj 不入库）
open ios/AgentRoundtable.xcodeproj
```

后端地址默认 `http://localhost:8000`，可在 scheme 的环境变量 `RT_API_BASE_URL` 覆盖（真机调试时填局域网地址）。Info.plist 只对 `localhost` / `127.0.0.1` 放开 HTTP（`NSExceptionDomains`），上线前必须移除；生产环境要求 HTTPS/WSS。

## 测试

```bash
make ios-test      # RoundtableCore XCTest
make ios-lint      # SwiftLint --strict
make ios-app-test  # App 单测（Keychain、Provider、turn、总结、安全）
make ios-ui-test   # 完整 UI 回归（创建、控制、恢复、安全、结论卡与演示流程）
```

完整 UI 回归连接 `http://localhost:8000`，先启动后端：

```bash
make docker-up
make ios-ui-test
make docker-down
```

`-collect-test-diagnostics never` 已内置于 Makefile 和 CI，避免 Xcode 在测试结束后卡在诊断收集。Keychain 测试需要模拟器 ad-hoc 签名，不能设置 `CODE_SIGNING_ALLOWED=NO`。

## 录屏

```bash
make docker-up
make record-demo
make docker-down
```

## 行为说明

进入 App 后：首页可打开历史圆桌或新建讨论 → 确认三个参与者 → 开始讨论 → 配置 Provider 后启动自动讨论，或点击 Mock 查看确定性演示事件。圆桌页底部可以发送普通消息、点名 Agent、暂停、继续或提前结束；消息菜单可标记关键观点或重新生成最近一条 AI 回复。二轮结束或提前结束后自动进入结论阶段；Mock 无 Key 演示使用规则化降级摘要。

创建页的「模型 Provider」可以打开 Provider 设置：选 Qwen / DeepSeek / 自定义，填写 BaseURL、Model 与 API Key。API Key 只写入 Keychain，不会出现在 `UserDefaults`、日志或后端请求里；「验证连接」会调用该服务的 `GET /models` 判断 Key 与地址是否可用（不消耗 Token）。未配置 Provider 时仍可用 Mock 演示。

进入圆桌后，iOS 会向服务端获取下一位发言人并用已配置的 Provider 发起真实流式发言：思考 → 逐字输入 → 提交 turn → 获取下一位。用户插话或暂停不会中断正在生成的这一条消息，但完成后会停在暂停边界；继续只重新启动一条自动流程。模型不可达、Key 失效、限流等情况会直接显示稳定错误码、可重试范围和 partial，并回报一次失败；不会自动切换到 Mock 或其他模型。Provider Token 由 iOS 从 SSE usage 中读取并上报，后端只把它当作客户端观测值，不作为精确计费依据。

## 与 Android 的差异

iOS **没有**资料库、端侧向量化检索与端侧推理。原因见 [`docs/adr/0006-on-device-rag-in-client.md`](../docs/adr/0006-on-device-rag-in-client.md)：这些能力当前只在 Android 落地，若将来 iOS 接入，须复用 `GLOSSARY.md` 中同一套术语与同一阈值。
