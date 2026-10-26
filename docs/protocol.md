# Agent Roundtable 协议 v1

**状态：** 实现中（Issue #5）
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
  "agent_profile_ids": ["1111...", "2222...", "3333..."],
  "provider": {
    "kind": "deepseek",
    "base_url": "https://api.deepseek.com/v1",
    "model": "deepseek-chat"
  }
}
```

- `topic`：必填，去除首尾空白后 1-500 字符。
- `agent_profile_ids`：恰好 3 个、互不重复、必须存在。数组顺序即 `position` 顺序。
- `provider`：可选，省略或 `null` 表示尚未配置 Provider（Mock 演示）。提交时是**非秘密**元数据快照：
  - `kind`：`qwen | deepseek | custom`。
  - `base_url`：必须是 `http`/`https` 地址，不能带查询参数或片段；服务端会去掉末尾 `/` 再保存。
  - `model`：1-120 字符，去除首尾空白后不能为空。

**API Key 不上传。** 请求体任何层级出现 `api_key` / `apiKey` / `provider_api_key` 字段都会被拒绝：

```json
{
  "error": {
    "code": "validation_error",
    "message": "不得向后端提交 API Key。",
    "details": {"provider": ["不得向后端提交 API Key。"]}
  }
}
```

这样客户端一旦误传密钥会立刻失败，而不是被静默忽略后写进日志或数据库。Provider 元数据只用于展示与可观测性，后端不会用它发起模型请求。

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
  "active_turn": null,
  "provider": {
    "kind": "deepseek",
    "base_url": "https://api.deepseek.com/v1",
    "model": "deepseek-chat"
  },
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
`active_turn`：当前待执行的 turn；没有在途 turn 时为 `null`。字段形状见 2.8，重连客户端用 `turn_id` 继续或拒绝过期回报。
`provider`：创建时提交的 Provider 元数据快照，未配置时为 `null`。快照**永远不含** API Key。

### 2.7 提交结构化发言

`POST /api/v1/roundtables/{id}/messages`，需要 `X-Guest-Session`，且必须是创建者：

```json
{
  "turn_id": "<turn.id>",
  "roundtable_agent_id": "d00d...",
  "message_type": "proposal",
  "claim": "先用一个两周的验证性实验确认假设。",
  "body": "我建议把议题拆成一个两周内可验证的最小实验……",
  "stance": null,
  "references": ["<message.id>"],
  "confidence": 0.7
}
```

- `turn_id`：必填，必须是服务端签发给该圆桌且仍为 `pending` 的 turn。
- `roundtable_agent_id`：必须同时是该圆桌的参与者和该 turn 的 Agent。
- `message_type`：`proposal | support | challenge | supplement | question | summary`。`pass` 不能作为普通发言提交，必须使用 2.9。
- `claim`：1-80 字符，去除首尾空白。
- `body`：不能超过该 Agent 的 `max_reply_chars`（预设 Agent 为 180），同时受 2000 字符的硬上限保护；必填。
- `stance`：`support | challenge | supplement | question | null`；空字符串视同 `null`。
- `references`：最多 3 条，必须是**同一圆桌**已持久化的消息。
- `confidence`：0-1，默认 `0.6`。
- 请求体任意层级出现 `api_key` → `400 validation_error`，`details` 形如 `{"provider": ["不得向后端提交 API Key。"]}`（与 2.5 相同）。

客户端会按上述上限截断模型输出（`MessageComposer`），这只是一种体验优化：后端始终按同一组上限校验，任何超限请求都会被拒绝。

`201` 返回该消息对应的 `message.completed` 事件信封（与 WebSocket 广播的是同一条，客户端按 `event_id` 去重）：

```json
{
  "event_id": "0f9a...",
  "room_id": "c0de...",
  "sequence": 7,
  "created_at": "2026-10-26T01:02:03.456Z",
  "event_type": "message.completed",
  "payload": {"message": {"...": "..."}}
}
```

服务端在同一事务里：写入消息、把该 Agent 的状态置为 `completed`、必要时把圆桌从 `ready` 或 `paused` 推进到 `running`、`event_sequence` 加一、写入 `room_event`。提交成功后还会通过 channel layer 广播给该房间已连接的 WebSocket。

turn 同时被关闭为 `completed`。重复提交、其他 Agent 提交或使用过期 `turn_id` 都会返回 `400 validation_error`，不会写入第二条消息或事件。

> 当前 channel layer 是 Django Channels 的 `InMemoryChannelLayer`，只在单进程内广播；跨进程广播仍需接入 Redis。

**为什么由客户端提交**：模型请求由 iOS 直连 Provider（ADR 0001），Django 只负责签发 turn、校验与持久化，所以消息一定经过一次 HTTP 提交。调度事件由服务端持久化和广播；实际逐字流仍只存在于发起请求的客户端。

### 2.8 获取下一位发言人

`POST /api/v1/roundtables/{id}/turns/next`，需要 `X-Guest-Session`，且必须是创建者。请求体为空。

```json
{
  "round": 1,
  "turn": {
    "turn_id": "a11c...",
    "round": 1,
    "roundtable_agent_id": "d00d...",
    "position": 0,
    "agent_key": "advocate",
    "agent_name": "方案派"
  },
  "events": [
    {
      "event_id": "0f9a...",
      "room_id": "c0de...",
      "sequence": 1,
      "created_at": "2026-10-26T01:02:03.456Z",
      "event_type": "round.started",
      "payload": {"round": 1, "max_rounds": 2, "topic": "..."}
    },
    {
      "event_id": "0f9b...",
      "room_id": "c0de...",
      "sequence": 2,
      "created_at": "2026-10-26T01:02:03.456Z",
      "event_type": "agent.thinking",
      "payload": {
        "turn_id": "a11c...",
        "round": 1,
        "agent_id": "d00d...",
        "agent_name": "方案派"
      }
    }
  ]
}
```

- 服务端在一个事务内锁定圆桌、选择下一位 Agent、写入 `Turn` 和持久化事件，再通过统一服务入口广播。
- 同一圆桌最多存在一个 `pending` turn。iOS 重复请求时返回同一个 `turn_id` 和空 `events`，不会重复签发。
- 当前所有 Agent 已 `completed` 或 `passed` 时，`turn` 为 `null`，`events` 中包含唯一的 `round.completed`；重复请求不再追加事件。
- `turn_id` 是后续消息完成、失败或 pass 的唯一回合身份。iOS 不得自行生成或替换。
- `agent.thinking` 表示服务端已把该 turn 签发给客户端；`agent.typing` 和逐字 delta 仍是本地临时状态。

### 2.9 Agent 选择沉默

`POST /api/v1/roundtables/{id}/turns/pass`，需要 `X-Guest-Session`，且必须是创建者：

```json
{
  "turn_id": "a11c...",
  "roundtable_agent_id": "d00d..."
}
```

两个字段必须属于当前 `pending` turn。成功时 `201` 返回该 turn 对应的 `agent.passed` 事件：

```json
{
  "event_id": "0f9c...",
  "room_id": "c0de...",
  "sequence": 3,
  "created_at": "2026-10-26T01:02:03.456Z",
  "event_type": "agent.passed",
  "payload": {
    "turn_id": "a11c...",
    "round": 1,
    "agent_id": "d00d...",
    "agent_name": "方案派"
  }
}
```

`pass` 只关闭 turn 并改变参与者状态，**不会创建普通 `Message`**，也不会被当作有效观点参与引用或后续调度。重复 pass 返回 `400 validation_error`，不会重复产生事件。

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
3. 之后的实时事件沿用同一连接推送。REST 签发 turn、提交发言和 pass 产生的事件都经统一服务入口广播到该连接。

### 3.4 事件类型

| event_type | payload | 说明 |
| --- | --- | --- |
| `room.joined` | `{"roundtable": <快照>, "messages": [<Message>]}` | 进入圆桌；`messages` 为该圆桌已持久化的发言，按创建时间升序，用于首次渲染 |
| `round.started` | `{"round": 1, "max_rounds": 2, "topic": "..."}` | 一轮开始 |
| `agent.thinking` | `{"turn_id": "<Turn.id>", "round": 1, "agent_id": "<RoundtableAgent.id>", "agent_name": "方案派"}` | 服务端已签发本轮 turn |
| `agent.typing` | `{"agent_id": "<RoundtableAgent.id>"}` | Agent 输入中 |
| `agent.passed` | `{"turn_id": "<Turn.id>", "round": 1, "agent_id": "<RoundtableAgent.id>", "agent_name": "方案派"}` | Agent 明确选择沉默，不产生普通消息 |
| `message.delta` | `{"message_id": "...", "delta": "..."}` | 流式片段（Mock 切片暂不产生） |
| `message.completed` | `{"message": <Message>}` | 一条结构化发言完成 |
| `round.completed` | `{"round": 1}` | 一轮结束 |
| `summary.started` / `summary.delta` / `summary.completed` | 预留 | 结论阶段（Issue #9） |
| `room.failed` | `{"reason": "..."}` | 圆桌级失败（预留） |

`Message`：

```json
{
  "id": "6f0e...",
  "turn_id": "a11c...",
  "round_number": 1,
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

`message_type`：`proposal | support | challenge | supplement | question | summary`
`stance`：`support | challenge | supplement | question | null`

真实 Agent 的普通消息必须带服务端签发的 `turn_id`；Mock 消息的 `turn_id` 为 `null`，但仍带 `round_number`。

### 3.5 客户端命令与第一轮流程

真实第一轮由 REST 握手驱动：

1. iOS 调用 `POST /turns/next` 取得唯一 `turn_id`。
2. iOS 直连 Provider，仅由当前被调度的 Agent 生成内容。
3. 有有效观点时调用 `POST /messages`；无独立观点时调用 `POST /turns/pass`。
4. iOS 再次调用 `POST /turns/next`，直到返回 `turn: null` 和 `round.completed`。

客户端在任一时刻只执行一个 turn。Provider 失败时保留待处理 turn，用户重试后重新请求 `turns/next`，服务端返回同一个 `turn_id`。

Mock 演示仍支持一条 WebSocket 命令：

```json
{"event_type": "mock.run"}
```

服务端执行一轮脚本化 Mock 讨论（11 个事件），每个事件都已持久化并经同一服务入口广播。达到 `max_rounds` 后再发送不会产生任何事件。

> `mock.run` 仅用于确定性演示和 UI 测试，不参与真实 Provider 的 turn 调度。未知命令一律忽略，便于客户端向前兼容地探测能力。

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
- 重连后优先使用快照中的 `active_turn.turn_id` 恢复在途回合，不得自行创建替代 turn。
