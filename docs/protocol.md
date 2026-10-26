# Agent Roundtable 协议 v1（Mock 纵向切片）

**状态：** 实现中（Issue #2）
**传输：** REST（HTTP/JSON）+ WebSocket（JSON 文本帧）

本文件是 iOS 与 Django 的唯一接口契约。改动接口时同步更新本文件，并在 Issue 中说明兼容性。

## 1. 约定

- 所有时间戳为 UTC ISO 8601，毫秒精度，`Z` 结尾：`2026-10-26T01:02:03.456Z`。
- 所有 ID 为 UUID 字符串。
- 未特别说明时，请求与响应均为 `application/json`。
- 字段命名使用 `snake_case`，与后端模型和 PRD 术语一致。

## 2. REST

### 2.1 错误信封

所有非 2xx 响应：

```json
{
  "error": {
    "code": "validation_error",
    "message": "必须选择 3 个不同的 Agent。",
    "details": {"agent_profile_ids": ["..."]}
  }
}
```

`code` 是稳定值，客户端按它做分支；`message` 只用于展示：

| code | HTTP | 含义 |
| --- | --- | --- |
| `guest_session_required` | 401 | 缺少 `X-Guest-Session` 头，或会话不存在 |
| `roundtable_not_found` | 404 | 圆桌不存在，或不属于当前会话 |
| `validation_error` | 400 | 请求体校验失败 |
| `not_found` | 404 | 路由不存在（由 Django 404 处理器返回 JSON） |
| `method_not_allowed` | 405 | HTTP 方法不被该路由支持 |
| `server_error` | 500 | 未处理异常（由 Django 500 处理器返回 JSON） |

`code` 由具体异常类决定，上表是当前实现会产生的主要取值；客户端遇到未知 `code` 时按通用错误处理。`DEBUG=0` 时上述处理器对所有 API 响应生效；本地 `DEBUG=1` 时 Django 会返回调试页面。

### 2.2 健康检查

`GET /api/v1/health` → `200 {"status": "ok", "service": "agent-roundtable"}`

### 2.3 创建匿名会话

`POST /api/v1/guest-sessions` → `201`

```json
{"id": "8a1f...", "created_at": "2026-10-26T01:02:03.456Z"}
```

MVP 中 UUID 本身即能力凭据：持有它的客户端可以读写该会话的圆桌。客户端把 `id` 存本地，并在后续请求中作为 `X-Guest-Session` 头发送。

### 2.4 读取预设 Agent

`GET /api/v1/agent-profiles` → `200 [AgentProfile]`

```json
{
  "id": "1111...",
  "key": "advocate",
  "name": "方案派",
  "tagline": "先给出可执行的方案，再谈权衡。",
  "expertise": "方案设计与执行拆解",
  "goal": "提出清晰、可执行的方案和下一步行动。",
  "default_stance": "倾向推进，优先寻找可落地的路径。",
  "style": "直接、结构化，先结论后理由。",
  "banned_behaviors": ["空泛表态", "引用未出现的观点", "重复已有主张"],
  "max_reply_chars": 180
}
```

顺序固定为 `advocate`、`skeptic`、`experience`。

### 2.5 创建圆桌

`POST /api/v1/roundtables`，需要 `X-Guest-Session` 头：

```json
{
  "topic": "该不该把验证周期压缩到两周？",
  "agent_profile_ids": ["1111...", "2222...", "3333..."]
}
```

- `topic`：必填，去除首尾空白后 1-500 字符。
- `agent_profile_ids`：恰好 3 个、互不重复、必须存在。数组顺序即 `position` 顺序。

`201` 返回圆桌快照（见 2.6）。

### 2.6 圆桌快照

`GET /api/v1/roundtables/{id}`（需要 `X-Guest-Session`，且必须是创建者）→ `200`

```json
{
  "id": "c0de...",
  "topic": "该不该把验证周期压缩到两周？",
  "status": "ready",
  "mode": "decision",
  "max_rounds": 2,
  "current_round": 0,
  "last_sequence": 0,
  "created_at": "2026-10-26T01:02:03.456Z",
  "updated_at": "2026-10-26T01:02:03.456Z",
  "participants": [
    {
      "id": "d00d...",
      "position": 0,
      "state": "waiting",
      "agent": {"id": "1111...", "key": "advocate", "name": "方案派", "...": "..."}
    }
  ]
}
```

`status`：`draft | ready | running | paused | summarizing | completed | failed | archived`
`state`：`waiting | thinking | typing | passed | completed | failed`
`last_sequence`：该圆桌已持久化的最大事件序号，客户端用它初始化游标。

## 3. WebSocket

### 3.1 连接

```
ws(s)://<host>/ws/v1/roundtables/<roundtable_id>/?guest_session=<uuid>&cursor=<int>
```

- `guest_session`：必填，且必须拥有该圆桌。
- `cursor`：可选，默认 `0`；只补发 `sequence > cursor` 的事件。
- 未授权或圆桌不存在：服务端在 accept 前关闭，close code `4401`。
- `cursor` 非法（负数、非整数）：close code `4400`。
- 收到非 JSON 文本帧：close code `4400`。

### 3.2 事件信封

所有服务端事件：

```json
{
  "event_id": "0f9a...",
  "room_id": "c0de...",
  "sequence": 7,
  "created_at": "2026-10-26T01:02:03.456Z",
  "event_type": "message.completed",
  "payload": {}
}
```

- 持久化事件的 `sequence` 在单个圆桌内从 1 开始单调递增；唯一例外是 `room.joined`（见下一条）。
- `room.joined` 是连接时的临时快照，**不是**日志事件，`sequence` 固定为 `0`，不得推进客户端游标。
- 客户端按 `event_id` 去重；游标取已持久化事件的最大 `sequence`。

### 3.3 连接流程

1. 服务端接受连接后发送 `room.joined`。
2. 若请求带 `cursor`，随后按 `sequence` 升序补发 `sequence > cursor` 的历史事件。
3. 之后的实时事件沿用同一连接推送。

### 3.4 事件类型

| event_type | payload | 说明 |
| --- | --- | --- |
| `room.joined` | `{"roundtable": <快照>, "messages": []}` | 进入圆桌；`messages` 在切片中恒为空数组，为后续消息回放预留 |
| `round.started` | `{"round": 1, "max_rounds": 2, "topic": "..."}` | 一轮开始 |
| `agent.thinking` | `{"agent_id": "<RoundtableAgent.id>", "agent_name": "方案派"}` | Agent 思考中 |
| `agent.typing` | `{"agent_id": "<RoundtableAgent.id>"}` | Agent 输入中 |
| `agent.passed` | `{"agent_id": "<RoundtableAgent.id>"}` | Agent 选择沉默（Mock 切片暂不产生） |
| `message.delta` | `{"message_id": "...", "delta": "..."}` | 流式片段（Mock 切片暂不产生） |
| `message.completed` | `{"message": <Message>}` | 一条结构化发言完成 |
| `round.completed` | `{"round": 1}` | 一轮结束 |
| `summary.started` / `summary.delta` / `summary.completed` | 预留 | 结论阶段（Issue #9） |
| `room.failed` | `{"reason": "..."}` | 圆桌级失败（预留） |

`Message`：

```json
{
  "id": "6f0e...",
  "author": {"roundtable_agent_id": "d00d...", "agent_key": "skeptic", "name": "质疑派"},
  "message_type": "challenge",
  "claim": "一句话主张",
  "body": "正文",
  "stance": "challenge",
  "references": ["<message.id>"],
  "confidence": 0.64,
  "created_at": "2026-10-26T01:02:03.456Z"
}
```

`message_type`：`proposal | support | challenge | supplement | question | pass | summary`
`stance`：`support | challenge | supplement | question | null`

### 3.5 客户端命令

Mock 切片只需要一条命令：

```json
{"event_type": "mock.run"}
```

服务端执行一轮脚本化 Mock 讨论（11 个事件），每个事件都已持久化。达到 `max_rounds` 后再发送不会产生任何事件。

> Mock 命令是 Issue #2 的临时桥梁：轮次调度器（Issue #5）落地后，事件改由服务端自动驱动，客户端不再发送 `mock.run`。未知命令一律忽略，便于客户端向前兼容地探测能力。

### 3.6 Mock 一轮的事件序列

```text
round.started
agent.thinking(advocate)
agent.typing(advocate)
message.completed(proposal, references=[])
agent.thinking(skeptic)
agent.typing(skeptic)
message.completed(challenge, references=[proposal])
agent.thinking(experience)
agent.typing(experience)
message.completed(supplement, references=[proposal])
round.completed
```

首轮结束后圆桌为 `running`；达到 `max_rounds`（默认 2）后为 `completed`。

## 4. 客户端实现要求

- 断线重连时携带最后持久化游标（Issue #8 完整实现，本切片保存游标）。
- 事件按 `event_id` 去重，按 `sequence` 忽略重复/过期事件。
- 即使事件类型未知、payload 未被渲染，游标也要前进到该 `sequence`，否则重连会反复补发同一条事件。
- 未知 `event_type` 必须被忽略而不是报错，以支持服务端向前演进。
- `room.joined` 用于渲染参与者与空圆桌状态；`sequence == 0` 不参与游标计算。
