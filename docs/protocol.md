# Agent Roundtable 协议 v1

**状态：** MVP v0.1.0 已实现
**传输：** REST（HTTP/JSON）+ WebSocket（JSON 文本帧）

本文件是 iOS 与 Django 的唯一接口契约。改动接口时同步更新本文件，并在 Issue 中说明兼容性。

## 1. 约定

- 所有时间戳为 UTC ISO 8601，毫秒精度，`Z` 结尾：`2026-10-26T01:02:03.456Z`。
- 所有 ID 为 UUID 字符串。
- 未特别说明时，请求与响应均为 `application/json`。
- 字段命名使用 `snake_case`，与后端模型和 PRD 术语一致。
- 除健康检查、读取预设 Agent 和创建匿名会话外，REST 请求都需要 `X-Guest-Session`。
- 文档中的 `...` 只表示被省略的字段，不是实际响应中的字面值。

## 2. REST

### 2.0 Endpoint 索引

| Method | Path | 成功状态 |
| --- | --- | --- |
| `GET` | `/api/v1/health` | `200` |
| `POST` | `/api/v1/guest-sessions` | `201` |
| `GET` | `/api/v1/agent-profiles` | `200` |
| `POST` | `/api/v1/roundtables` | `201` |
| `GET` | `/api/v1/roundtables/{id}` | `200` |
| `DELETE` | `/api/v1/roundtables/{id}` | `204` |
| `POST` | `/api/v1/roundtables/{id}/messages` | `201` |
| `POST` | `/api/v1/roundtables/{id}/turns/next` | `200` |
| `POST` | `/api/v1/roundtables/{id}/turns/pass` | `201` |
| `POST` | `/api/v1/roundtables/{id}/turns/fail` | `201` |
| `POST` | `/api/v1/roundtables/{id}/user-messages` | `201` |
| `POST` | `/api/v1/roundtables/{id}/pause` | `200` |
| `POST` | `/api/v1/roundtables/{id}/resume` | `200` |
| `POST` | `/api/v1/roundtables/{id}/end` | `200` |
| `GET` | `/api/v1/roundtables/{id}/summary` | `200` |
| `POST` | `/api/v1/roundtables/{id}/summary` | `201`，幂等重试 `200` |
| `POST` | `/api/v1/roundtables/{id}/follow-ups` | `201` |
| `POST` | `/api/v1/roundtables/{id}/messages/{message_id}/reports` | `201`，幂等重复 `200` |

当前没有“列出圆桌历史”的 `GET /roundtables`；iOS 历史恢复以本地 SwiftData 缓存和最近圆桌为入口。

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
| `active_roundtable_limit` | 429 | 同一匿名会话已有 3 个进行中的圆桌 |
| `mock_daily_limit` | 429 | 同一匿名会话在本 UTC 日已创建 10 个 Mock 圆桌 |
| `summary_version_conflict` | 409 | 结论提交的 `expected_version` 已过期 |
| `not_found` | 404 | 路由不存在（由 Django 404 处理器返回 JSON） |
| `method_not_allowed` | 405 | HTTP 方法不被该路由支持 |
| `server_error` | 500 | 未处理异常（由 Django 500 处理器返回 JSON） |

`code` 由具体异常类决定，上表是当前实现会产生的主要取值；客户端遇到未知 `code` 时按通用错误处理。`DEBUG=0` 时上述处理器对所有 API 响应生效；本地 `DEBUG=1` 时 Django 会返回调试页面。

### 2.2 健康检查

`GET /api/v1/health` → `200 {"status": "ok", "service": "agent-roundtable"}`

该接口是进程存活检查。Compose 另用 PostgreSQL/Redis healthcheck 和启动依赖保证依赖就绪。

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

创建限额：

- 同一匿名会话同时最多保留 3 个 `ready | running | paused | summarizing` 圆桌；完成后可以继续创建。
- 省略 `provider` 的 Mock 圆桌，每匿名会话每 UTC 日最多创建 10 个。
- 真实 Provider 圆桌没有每日创建上限。
- 限额检查在锁定 `GuestSession` 的事务内完成，并发请求不能穿透。

超过限额时分别返回 `429 active_roundtable_limit` 或 `429 mock_daily_limit`，错误消息包含对应上限，客户端应直接展示而不自动重试。

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
  "pause_pending": false,
  "active_turn": null,
  "provider": {
    "kind": "deepseek",
    "base_url": "https://api.deepseek.com/v1",
    "model": "deepseek-chat"
  },
  "parent_roundtable_id": null,
  "source_summary_id": null,
  "follow_up_context": null,
  "budget": {
    "max_rounds": 2,
    "max_agent_messages": 6,
    "agent_messages_used": 0,
    "max_reported_tokens": 2400,
    "reported_tokens": 0,
    "max_duration_seconds": 90,
    "started_at": null,
    "elapsed_seconds": 0,
    "exhausted_reason": null,
    "token_source": "client_reported"
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
`last_sequence`：该圆桌已持久化的最大事件序号。已有本地缓存时，客户端必须继续使用本地已处理游标；只有没有本地记录或服务端明确要求快照重置时，才用该值建立新游标。
`pause_pending`：用户要求在安全边界暂停，但仍有在途 turn。仅在 `status = running` 时可能为 `true`。
`active_turn`：当前待执行的 turn；没有在途 turn 时为 `null`。字段形状见 2.8，重连客户端用 `turn_id` 继续或拒绝过期回报。
`provider`：创建时提交的 Provider 元数据快照，未配置时为 `null`。快照**永远不含** API Key。
`parent_roundtable_id` / `source_summary_id`：继续追问创建的新圆桌会显式保存父圆桌与原结论关系，否则为 `null`。
`follow_up_context`：继续追问时返回 `{"parent_topic": "...", "summary": <RoundSummary>}`；普通圆桌为 `null`。
`budget`：服务端实际执行的轮数、消息数、时间和客户端上报 Token 上限。`token_source = client_reported` 表示 Token 不是服务端计量或计费事实；Django 不接触 Provider 请求。

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
  "challenge_target_agent_id": null,
  "confidence": 0.7,
  "usage": {
    "input_tokens": 380,
    "output_tokens": 120,
    "latency_ms": 2450,
    "retry_count": 0
  }
}
```

- `turn_id`：必填，必须是服务端签发给该圆桌且仍为 `pending` 的 turn。
- `roundtable_agent_id`：必须同时是该圆桌的参与者和该 turn 的 Agent。
- `message_type`：`proposal | support | challenge | supplement | question | summary`。`pass` 不能作为普通发言提交，必须使用 2.9。
- `claim`：1-80 字符，去除首尾空白。
- `body`：不能超过该 Agent 的 `max_reply_chars`（预设 Agent 为 180），同时受 2000 字符的硬上限保护；必填。
- `stance`：`support | challenge | supplement | question | null`；空字符串视同 `null`。第二轮非 pass 发言必须提供立场。
- `references`：最多 3 条，且不能重复。第二轮至少 1 条，每条都必须指向**同一圆桌**中更早产生的有效 Agent 观点；该观点必须来自其他参与者，不能被用户消息、自身、`pass`、`summary`、未知消息或跨圆桌消息替代。
- `challenge_target_agent_id`：可选参与者 ID。`challenge` 时必填，且必须是被引用观点的作者；其他立场时必须省略或为 `null`。
- `confidence`：0-1，默认 `0.6`。
- `usage`：可选、仅用于可观测性和客户端上报 Token 预算。字段全部可选；`retry_count` 为 0-10，默认 0。后端只保存模型快照、Token、延迟、重试和失败码，不保存 Prompt 或 Provider 请求头。

第一轮允许 `proposal | support | challenge | supplement | question | summary` 且可以不引用。第二轮只接受 `support | challenge | supplement | question`，并要求 `message_type` 与 `stance` 相同、`claim` 非空、引用合法；`proposal`、`summary`、`pass` 和 `user_message` 不能伪装成第二轮互评。
- 请求体任意层级出现 `api_key` → `400 validation_error`，`details` 形如 `{"provider": ["不得向后端提交 API Key。"]}`（与 2.5 相同）。

第一轮纯文本由 `MessageComposer` 组装；第二轮 Provider 必须返回结构化 JSON，再由 `StructuredReplyParser` 校验、映射引用并组装提交。客户端只允许对格式错误做一次有限重试，第二次仍非法时进入失败状态。后端始终按同一组上限重新校验，任何超限或非法请求都会被拒绝。

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

若请求带 `usage`，服务端同时写入该 turn 的 `UsageRecord`，并把可取得的 `input_tokens + output_tokens` 累加到房间的 `reported_tokens`。这些数字来自客户端，不是服务端精确计费依据。

turn 同时被关闭为 `completed`。重复提交、其他 Agent 提交或使用过期 `turn_id` 都会返回 `400 validation_error`，不会写入第二条消息或事件。

> Compose 和生产部署设置 `REDIS_URL`，使用 `channels_redis.core.RedisChannelLayer` 跨进程广播。单元测试和单进程本地开发不设置该变量，默认使用内存层。

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
    },
    {
      "event_id": "0f9e...",
      "room_id": "c0de...",
      "sequence": 4,
      "created_at": "2026-10-26T01:02:03.457Z",
      "event_type": "room.pause_pending",
      "payload": {"turn_id": "a11c..."}
    }
  ]
}
```

- 服务端在一个事务内锁定圆桌、选择下一位 Agent、写入 `Turn` 和持久化事件，再通过统一服务入口广播。
- 同一圆桌最多存在一个 `pending` turn。iOS 重复请求时返回同一个 `turn_id` 和空 `events`，不会重复签发。
- 当前轮所有 Agent 已 `completed` 或 `passed` 时，服务端发送唯一的 `round.completed`。若还未达到 `max_rounds`，同一响应会立即追加下一轮的 `round.started` 和 `agent.thinking`，并返回新 turn，客户端无需额外请求即可自动进入第二轮。
- 达到 `max_rounds` 后返回 `turn: null`，追加唯一 `summary.started` 并进入 `summarizing`。完成结算后重复请求返回 `400 validation_error`，不会重复产生 `round.completed`。
- `turn_id` 是后续消息完成、失败或 pass 的唯一回合身份。iOS 不得自行生成或替换。
- `agent.thinking` 表示服务端已把该 turn 签发给客户端；`agent.typing` 和逐字 delta 仍是本地临时状态。

### 2.9 Agent 选择沉默

`POST /api/v1/roundtables/{id}/turns/pass`，需要 `X-Guest-Session`，且必须是创建者：

```json
{
  "turn_id": "a11c...",
  "roundtable_agent_id": "d00d...",
  "usage": {
    "input_tokens": 320,
    "output_tokens": 8,
    "latency_ms": 1800,
    "retry_count": 0
  }
}
```

`turn_id` 和 `roundtable_agent_id` 必须属于当前 `pending` turn；`usage` 可选且形状与 2.7 相同。成功时 `201` 返回该 turn 对应的 `agent.passed` 事件：

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

### 2.10 报告 Agent 失败

`POST /api/v1/roundtables/{id}/turns/fail`，需要 `X-Guest-Session`：

```json
{
  "turn_id": "a11c...",
  "roundtable_agent_id": "d00d...",
  "failure_code": "provider_timeout",
  "message": "请求超时，请稍后重试。",
  "retryable": true,
  "partial": "已经生成的半段观点",
  "usage": {
    "input_tokens": 210,
    "output_tokens": 35,
    "latency_ms": 60000,
    "retry_count": 1
  }
}
```

- `turn_id` 与 `roundtable_agent_id` 必须对应当前唯一 `pending` turn。
- `failure_code` 是稳定机器码；`message` 是用户可读原因，最多 500 字符。
- `retryable` 只描述该错误是否值得用户再次尝试，不表示服务端会自动重试。
- `partial` 可选，最多 2000 字符；客户端保留流式半成品供用户阅读。
- `usage` 可选，形状与 2.7 相同。

稳定 `failure_code`：

| code | 可重试 | 含义 |
| --- | --- | --- |
| `provider_unauthorized` | 否 | 401/403，Key 无效或没有权限 |
| `provider_insufficient_balance` | 否 | 402，余额不足或计费未开通 |
| `provider_model_not_found` | 否 | 404，接口或 Model 不存在 |
| `provider_rate_limited` | 是 | 429，Provider 限流 |
| `provider_timeout` | 是 | Provider 请求超时 |
| `provider_network` | 是 | 网络不可达或连接中断 |
| `provider_empty_reply` | 是 | Provider 返回空内容 |
| `provider_invalid_response` | 是 | SSE/结构化输出非法；格式化解析最多重试一次后仍失败 |
| `provider_server_error` | 是 | Provider 5xx |
| `provider_not_configured` | 否 | Keychain 中缺少可用 Key |
| `content_policy_blocked` | 否 | iOS 本地内容规则阻止了模型输出，消息未提交 |
| `scheduler_invalid_agent` | 否 | 服务端签发了未知参与者，属于契约错误 |
| `client_request_failed` | 视 HTTP 状态 | iOS 回报服务端时请求失败 |
| `provider_error` | 是 | 其他未知 Provider 错误 |
| `turn_timeout` | 是 | 服务端发现 pending turn 超过 60 秒 |

成功时 `201` 返回唯一 `agent.failed` 事件：

```json
{
  "event_id": "0f9c...",
  "room_id": "c0de...",
  "sequence": 4,
  "created_at": "2026-10-26T01:02:03.456Z",
  "event_type": "agent.failed",
  "payload": {
    "turn_id": "a11c...",
    "round": 1,
    "agent_id": "d00d...",
    "agent_name": "方案派",
    "failure_code": "provider_timeout",
    "message": "请求超时，请稍后重试。",
    "retryable": true,
    "partial": "已经生成的半段观点"
  }
}
```

失败只关闭当前 turn，不把整场圆桌标记为失败，也不删除已经完成的消息。之后调用 `turns/next` 会继续选择仍有资格的其他 Agent。重复、过期、错误 Agent 或已结束房间的失败回报全部返回 `400 validation_error`，不会重复写事件。

服务端也会在 `turns/next` 边界检查 pending turn 的截止时间；超过 60 秒时先写入一次 `turn_timeout` 的 `agent.failed`，再尝试调度下一位 Agent。失败发生在 `pause_pending` 边界时，客户端还会通过事件流收到 `room.paused`。

### 2.11 发送用户消息

`POST /api/v1/roundtables/{id}/user-messages`，需要 `X-Guest-Session`，且必须是创建者：

```json
{
  "body": "先补充一个约束：团队只有两个人。",
  "mentioned_agent_ids": ["d00d..."]
}
```

- `body`：必填，去除首尾空白后 1-2000 字符。
- `mentioned_agent_ids`：可选，最多 3 个、互不重复，且每个 ID 都必须是当前圆桌的参与者。
- 点名的唯一依据是 `mentioned_agent_ids`；正文里的 `@名字` 只用于展示，服务端不解析。
- 用户消息使用独立的 `author.type = "user"`，不会伪装成 Agent，也不要求 `turn_id`、`claim` 或结构化立场。

成功时 `201`：

```json
{
  "roundtable": {"status": "running", "pause_pending": true, "...": "..."},
  "events": [
    {
      "event_id": "0f9d...",
      "room_id": "c0de...",
      "sequence": 3,
      "created_at": "2026-10-26T01:02:03.456Z",
      "event_type": "message.completed",
      "payload": {
        "message": {
          "id": "7f0e...",
          "turn_id": null,
          "round_number": 1,
          "author": {"type": "user", "name": "用户"},
          "message_type": "user_message",
          "claim": null,
          "body": "先补充一个约束：团队只有两个人。",
          "stance": null,
          "references": [],
          "confidence": null,
          "mentioned_agent_ids": ["d00d..."],
          "created_at": "2026-10-26T01:02:03.456Z"
        }
      }
    }
  ]
}
```

用户消息一定持久化并广播。暂停边界规则：

- 无在途 turn：消息后直接进入 `paused`，追加唯一的 `room.paused` 事件。
- 有在途 turn：消息后设置 `pause_pending = true`，追加唯一的 `room.pause_pending` 事件；当前 Agent 的 `message.completed` 或 `agent.passed` 完成后，服务端才进入 `paused` 并追加 `room.paused`。
- 用户插话不会取消当前 Provider 生成；只有 `end` 或离开圆桌会由客户端取消本地生成 Task。
- 重复插话可以继续追加用户消息，但不会重复产生 `room.pause_pending`。

### 2.12 暂停

`POST /api/v1/roundtables/{id}/pause`，无请求体。

- 没有在途 turn 时立即进入 `paused`，产生 `room.paused`。
- 有在途 turn 时只设置 `pause_pending`，产生 `room.pause_pending`；当前 turn 完成后才进入 `paused`。
- 已暂停或已处于 `pause_pending` 时重复调用返回当前快照和空 `events`，不会重复产生事件。
- `completed | failed | archived | summarizing` 状态返回 `400 validation_error`。

### 2.13 继续

`POST /api/v1/roundtables/{id}/resume`，无请求体。

- `paused` 恢复为 `running`，产生 `room.resumed`。
- 尚未消费的 `pause_pending` 会被清除，并产生 `room.resumed`。
- 已处于正常运行状态时重复调用返回当前快照和空 `events`。
- 重复调用只用于幂等；客户端仍只启动一条自动 turn 流程。

### 2.14 提前结束

`POST /api/v1/roundtables/{id}/end`，无请求体。

- 圆桌进入 `summarizing`，清除 `pause_pending`，依次产生 `room.ended` 与 `summary.started`。
- 如有在途 turn，其状态改为 `cancelled`，此后使用该 `turn_id` 提交 message 或 pass 都返回 `400`。
- 重复调用返回当前快照和空 `events`。
- 结束后禁止写入用户消息、Agent 消息或签发新 turn；客户端继续生成并提交结论。总结保存后圆桌进入 `completed`。

以上三个控制命令与用户消息命令统一返回：

```json
{"roundtable": {"...": "..."}, "events": [<EventEnvelope>]}
```

即使命令是幂等空操作，客户端也应以 `roundtable` 快照校正本地状态。

### 2.15 失败、预算与结束优先级

服务端强制执行以下 MVP 默认值：

- 最多 2 轮。
- 最多 6 条有效 Agent 消息（三位参与者 × 两轮）。
- 单个 turn 最多 60 秒。
- 整场讨论最多 90 秒。
- 客户端上报 Token 上限 2400。

Token 的可信度边界：

- Django 不代理 Provider 请求，因此不能看到真实 Token 或账单。
- 服务端只会累加 iOS 从 Provider SSE `usage` 中解析后上报的 `input_tokens + output_tokens`。
- `reported_tokens` 是客户端自报观测值，不是安全计费依据；超限时会停止后续调度，但不能证明 Provider 实际计费。
- 服务端可靠执行的是轮数、消息数、Turn 截止时间和整场时间。

结束事件优先级：

1. 用户 `end` 产生一次 `room.ended`，优先于后续所有预算检查。
2. 当前轮已经是最后一轮且所有参与者均已关闭时，产生一次 `round.completed`，随后追加一次 `summary.started` 并进入 `summarizing`；自然完成优先于预算耗尽。
3. 仍有后续发言空间，但时长、消息数或上报 Token 已达上限时，产生一次 `budget.exhausted` 并把圆桌置为 `completed`。
4. 单个 `agent.failed` 只关闭该 turn，不终止整场讨论。

若当前轮自然结束、仍有下一轮空间，但预算已经耗尽，同一响应先返回该轮的 `round.completed`，再返回唯一的 `budget.exhausted`，不会签发下一轮 turn。

`budget.exhausted` 只会写一次；圆桌完成后重复请求 `turns/next` 返回 `400 validation_error`。Mock 模式执行同一时间/消息预算检查。

### 2.16 读取与提交结论

`GET /api/v1/roundtables/{id}/summary` 返回 `{"summary": <RoundSummary|null>}`。尚未生成结论时为 `null`：

```json
{
  "id": "5a0e...",
  "version": 1,
  "degraded": false,
  "consensus": [
    {
      "text": "先完成可验证的小实验。",
      "reference_message_ids": ["6f0e..."]
    }
  ],
  "dissent": [],
  "recommendations": [],
  "unresolved": [],
  "created_at": "2026-10-26T01:05:03.456Z",
  "updated_at": "2026-10-26T01:05:03.456Z"
}
```

结论项规则：

- 每个 `text` 去除首尾空白后为 1-400 字符。
- 每个分组最多 8 项。
- 每项必须引用 1-3 条同一圆桌中已经存在的有效 Agent 观点；用户消息、pass、summary、未知消息和跨圆桌消息都不是合法来源。
- `degraded = true` 表示 Provider 不可用或严格结构校验连续失败，客户端已改用规则化摘要；引用仍然必须是真实已存在消息。
- 后端不提供直接编辑结论正文的接口。

`POST /api/v1/roundtables/{id}/summary` 需要 `X-Guest-Session`：

```json
{
  "expected_version": 0,
  "degraded": false,
  "consensus": [
    {
      "text": "先完成可验证的小实验。",
      "reference_message_ids": ["6f0e..."]
    }
  ],
  "dissent": [],
  "recommendations": [],
  "unresolved": []
}
```

- 首次提交必须使用 `expected_version = 0`，保存为版本 1，圆桌进入 `completed`。
- 重新生成使用当前版本作为 `expected_version`，成功保存为新版本并追加新的 `summary.completed`。
- 网络重试使用旧 `expected_version` 且内容完全相同时是幂等重试，返回 `200`、当前结论和空 `events`。
- 其他版本不匹配返回 `409 summary_version_conflict`，不会覆盖较新的结论。
- 只有第二轮已经完成且状态为 `summarizing | completed` 时才能提交；请求体任意层级出现 API Key 会返回 `400 validation_error`。

首次成功返回 `201`，幂等重试返回 `200`：

```json
{
  "roundtable": {"status": "completed", "...": "..."},
  "summary": {"version": 1, "...": "..."},
  "events": [
    {
      "event_id": "0f9f...",
      "room_id": "c0de...",
      "sequence": 23,
      "created_at": "2026-10-26T01:05:03.456Z",
      "event_type": "summary.completed",
      "payload": {"summary": {"version": 1, "...": "..."}}
    }
  ]
}
```

总结由 iOS 使用当前 Provider 生成：模型输出只包含 `text` 和候选观点 `reference_indexes`，客户端将索引映射为真实消息 ID。严格 schema 失败最多重试一次；再次失败或 Provider 不可用时，`RuleBasedSummary` 只用原消息 claim/正文生成本地降级项并设置 `degraded = true`。候选范围、强制引用和提示约束可以降低“引入新事实”的风险，但后端无法证明任意自然语言片段没有隐含新事实。

### 2.17 继续追问

`POST /api/v1/roundtables/{id}/follow-ups`，需要 `X-Guest-Session`：

```json
{"topic": "如果团队只有两个人，还应该马上扩大验证范围吗？"}
```

- 父圆桌必须是 `completed` 且已有 `RoundSummary`。
- 服务端创建新的 `ready` 圆桌，复制父圆桌的三个参与者和 Provider 元数据。
- 新圆桌保存 `parent_roundtable_id` 与 `source_summary_id`，并在 `follow_up_context` 返回原议题和原结论。
- 原圆桌不被修改；所有后续消息、turn 和控制只作用于新圆桌。
- 新圆桌仍受活跃圆桌上限约束。

### 2.18 举报 AI 消息

`POST /api/v1/roundtables/{id}/messages/{message_id}/reports`，需要 `X-Guest-Session`：

```json
{"reason": "harassment", "details": "持续针对用户进行攻击"}
```

- `reason`：`harassment | hate | dangerous | sexual | impersonation | other`。
- `details`：可选，去除首尾空白后最多 500 字符。
- 被举报消息必须是当前会话拥有的圆桌中、`author.type = "agent"` 的消息。
- 同一个匿名会话对同一条消息只保留一条举报；重复请求不会重复写入。
- 举报状态固定为 `submitted`，表示用户已提交，不表示内容已被审核或判定违规。

首次成功返回 `201`；幂等重复返回 `200`：

```json
{
  "id": "9a0e...",
  "message_id": "6f0e...",
  "reason": "harassment",
  "details": "持续针对用户进行攻击",
  "state": "submitted",
  "created_at": "2026-10-26T01:02:03.456Z",
  "updated_at": "2026-10-26T01:02:03.456Z"
}
```

圆桌不属于当前会话时返回 `404 roundtable_not_found`；用户消息或不属于该圆桌的消息返回 `400 validation_error`。请求体任意层级出现 API Key 同样返回 `400`。

本地隐藏不是举报，也不调用服务端接口。隐藏和取消隐藏只修改当前设备的 SwiftData 投影。

### 2.19 删除圆桌

`DELETE /api/v1/roundtables/{id}`，需要 `X-Guest-Session`。

- 首次删除返回 `204`，立即级联删除消息、事件、回合、用量、结论和举报。
- 同一 URL 的重复删除也返回 `204`，因此客户端网络重试是幂等的。
- 已删除圆桌的详情、总结、消息、turn、举报和 WebSocket 访问均不可用。
- 其他匿名会话删除该圆桌返回 `404 roundtable_not_found`，不会删除数据。

客户端必须在服务端成功后清理该圆桌的 SwiftData 记录、消息、结论、本地隐藏/标记/举报状态和恢复游标。服务端已删除但本机清理失败时，应保留明确的可重试状态；不得删除 Keychain 中的 Provider API Key。

### 2.20 数据保留

- 服务端圆桌、消息、事件、回合、用量、结论和举报以圆桌 `last_activity_at` 为唯一 90 天保留锚点。
- 创建圆桌、打开圆桌 WebSocket、讨论消息、turn、pause/resume/end、举报和结论保存都会续期活动时间。
- `GuestSession.last_seen_at` 只用于清理已经没有任何圆桌的匿名会话，不作为圆桌内容保留依据。
- 边界语义为 `last_activity_at <= now - ROUNDTABLE_RETENTION_DAYS` 时到期，默认 `ROUNDTABLE_RETENTION_DAYS=90`。
- 清理任务逐桌删除全部关联数据，并删除已经没有圆桌且超过保留期的匿名会话。
- iOS Keychain 中的 API Key 不参与服务端或本地保留清理。

运维命令：

```bash
cd backend && uv run python manage.py purge_roundtables
cd backend && uv run python manage.py purge_roundtables --dry-run
```

## 3. WebSocket

### 3.1 连接

```
ws(s)://<host>/ws/v1/roundtables/<roundtable_id>/?guest_session=<uuid>&cursor=<int>
```

- `guest_session`：必填，且必须拥有该圆桌。
- `cursor`：可选，默认 `0`；只补发 `sequence > cursor` 的事件。
- 可补发窗口由 `ROOM_EVENT_REPLAY_WINDOW_DAYS` 配置，默认 90 天。
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

实时广播先进入 replay barrier：服务端先发送 `room.joined` 和补发事件，再发送订阅后产生的 live 事件。客户端仍必须按 `sequence` 缓冲乱序事件，不能只依赖连接顺序。

`room.joined.payload.replay` 明确描述本次补发窗口：

```json
{
  "requested_cursor": 12,
  "oldest_sequence": 40,
  "latest_sequence": 57,
  "window_days": 90,
  "cursor_expired": true
}
```

- `oldest_sequence`：窗口内最早可补发事件；窗口为空时为 `null`。
- `latest_sequence`：请求处理时圆桌的最大持久化序号。
- `cursor_expired = true`：请求游标与窗口之间存在缺失序号，或游标超前。此时服务端不发送部分 replay。
- 游标过期时，`room.joined` 的 `roundtable`、`messages`、`failures` 是完整权威快照。客户端必须清空该圆桌的本地投影，把游标重置为 `roundtable.last_sequence`，再接收同一连接上的 live 事件；不得永久保留旧游标并跳过后续消息。

### 3.4 事件类型

| event_type | payload | 说明 |
| --- | --- | --- |
| `room.joined` | `{"roundtable": <快照>, "messages": [<Message>], "failures": [<TurnFailure>], "summary": <RoundSummary|null>, "replay": <ReplayMetadata>}` | 进入圆桌；恢复完整消息、失败 turn、结论和补发窗口；新增字段缺失时旧客户端按兼容缺省处理 |
| `round.started` | `{"round": 1, "max_rounds": 2, "topic": "..."}` | 一轮开始 |
| `agent.thinking` | `{"turn_id": "<Turn.id>", "round": 1, "agent_id": "<RoundtableAgent.id>", "agent_name": "方案派"}` | 服务端已签发本轮 turn |
| `agent.typing` | `{"agent_id": "<RoundtableAgent.id>"}` | Mock 脚本的 Agent 输入状态；真实 turn 的逐字状态只在本机临时展示 |
| `agent.passed` | `{"turn_id": "<Turn.id>", "round": 1, "agent_id": "<RoundtableAgent.id>", "agent_name": "方案派"}` | Agent 明确选择沉默，不产生普通消息 |
| `agent.failed` | `{"turn_id": "<Turn.id>", "round": 1, "agent_id": "<RoundtableAgent.id>", "agent_name": "方案派", "failure_code": "provider_timeout", "message": "...", "retryable": true, "partial": "..."}` | 单个 Agent 失败；不影响已完成消息 |
| `message.completed` | `{"message": <Message>}` | 一条结构化发言完成 |
| `round.completed` | `{"round": 1}` | 一轮结束 |
| `budget.exhausted` | `{"reason": "duration | agent_messages | reported_tokens", "message": "...", "round": 1}` | 单次预算终态事件 |
| `room.pause_pending` | `{"turn_id": "<Turn.id>"}` | 已请求暂停，等待当前 turn 完成 |
| `room.paused` | `{"status": "paused"}` | 圆桌已暂停 |
| `room.resumed` | `{"status": "running"}` | 圆桌已继续 |
| `room.ended` | `{"status": "summarizing", "cancelled_turn_id": "<Turn.id>", "cancelled_agent_id": "<RoundtableAgent.id>"}` | 用户提前结束讨论并进入总结；无在途 turn 时两个取消字段为 `null` |
| `summary.started` | `{"round": <current_round>}` | 自然完成最后一轮或用户提前结束，圆桌进入 `summarizing` |
| `summary.completed` | `{"summary": <RoundSummary>}` | 结论已校验保存，圆桌进入 `completed` |

当前服务端不发送 `message.delta`、`summary.delta` 或 `room.failed`。真实 Provider 的文本 delta 和总结流只存在于生成设备，不写入事件日志；单个 Agent 失败使用 `agent.failed`，客户端必须忽略未来新增的未知事件类型。

`Message`：

```json
{
  "id": "6f0e...",
  "turn_id": "a11c...",
  "round_number": 1,
  "author": {
    "type": "agent",
    "roundtable_agent_id": "d00d...",
    "agent_key": "skeptic",
    "name": "质疑派"
  },
  "message_type": "challenge",
  "claim": "一句话主张",
  "body": "正文",
  "stance": "challenge",
  "references": ["<message.id>"],
  "challenge_target_agent_id": "<RoundtableAgent.id>",
  "confidence": 0.64,
  "mentioned_agent_ids": [],
  "created_at": "2026-10-26T01:02:03.456Z"
}
```

`message_type`：`proposal | support | challenge | supplement | question | summary | user_message`
`stance`：`support | challenge | supplement | question | null`
`author.type`：`agent | user`

真实 Agent 的普通消息必须带服务端签发的 `turn_id`；Mock 消息的 `turn_id` 为 `null`，但仍带 `round_number`。
`author.type = user` 时，`roundtable_agent_id`、`agent_key`、`turn_id`、`claim`、`stance` 和 `confidence` 均为 `null`，`message_type` 为 `user_message`。
第一轮消息的 `challenge_target_agent_id` 通常为 `null`。第二轮中，`support/challenge/supplement/question` 消息必须引用更早的其他 Agent 有效观点；`challenge` 消息还必须带有 `challenge_target_agent_id`，并与被引用观点的作者一致。

### 3.5 客户端命令与两轮流程

真实两轮讨论由 REST 握手驱动：

1. iOS 调用 `POST /turns/next` 取得唯一 `turn_id`。
2. iOS 直连 Provider，仅由当前被调度的 Agent 生成内容。
3. 有有效观点时调用 `POST /messages`；无独立观点时调用 `POST /turns/pass`；Provider 失败时调用 `POST /turns/fail`。
4. iOS 再次调用 `POST /turns/next`。第一轮最后一位完成后，该响应同时包含第一轮 `round.completed`、第二轮 `round.started` 和第二轮唯一 turn。
5. 第二轮 iOS 使用同一 Provider 生成结构化 JSON，解析并校验引用、立场和挑战对象；格式非法时最多重试一次。
6. 第二轮最后一位完成后返回第二轮唯一的 `round.completed`、`summary.started` 和 `turn: null`，圆桌进入 `summarizing`。
7. iOS 使用同一 Provider 生成严格结构化结论；失败时规则化降级，再调用 `POST /summary`。首次成功后圆桌进入 `completed`。
8. `completed` 圆桌只读：新 Agent 消息、用户消息、turn、pause/resume 均返回 `400 validation_error`。继续追问必须调用 `POST /follow-ups` 创建新圆桌。

客户端在任一时刻只执行一个 turn。Provider 失败必须按稳定错误码回报一次；服务端关闭该 turn 后，用户继续讨论时 `turns/next` 会调度下一位仍有资格的 Agent。客户端不得静默切换 Provider、Model 或 Mock。

用户控制补充：

1. 用户消息通过 REST 提交并持久化；消息中的 mention ID 是下一 turn 的调度输入。
2. 用户插话后，客户端允许当前 Provider 流完成并提交，但收到 `pause_pending` 后不得自动请求下一 turn。
3. `room.paused` 到达后，只有用户显式 `resume` 才能重新启动一条自动流程。
4. `end` 先取消客户端生成 Task，再调用服务端结束；服务端取消当前 turn 作为兜底。

Mock 演示仍支持一条 WebSocket 命令：

```json
{"event_type": "mock.run"}
```

服务端执行一轮脚本化 Mock 讨论（11 个事件），每个事件都已持久化并经同一服务入口广播。达到 `max_rounds` 后再发送不会产生任何事件。超过时间预算时只返回一次 `budget.exhausted`。

> `mock.run` 是 MVP 正式支持的确定性演示和 UI 测试入口，不参与真实 Provider 的 turn 调度。未知命令一律忽略，便于客户端向前兼容地探测能力。

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

首轮结束后圆桌为 `running`；第二轮 Mock 脚本结束后追加 `summary.started` 并进入 `summarizing`。没有真实 Provider 的 Mock 演示由 iOS 规则化摘要降级完成。

## 4. 客户端实现要求

- 断线重连时携带本机最后持久化游标；不能用新收到的 `room.joined.roundtable.last_sequence` 覆盖已有本地游标。
- 本地持久化最近圆桌快照、完整消息、失败、游标、有界事件 ID 去重集合和最近可见消息 ID。
- 事件按 `event_id` 去重，按 `sequence` 忽略重复/过期事件；高序号先到时先缓冲，只有缺失序号补齐后才投影并推进游标。
- 即使事件类型未知、payload 未被渲染，游标也要前进到该 `sequence`，否则重连会反复补发同一条事件。
- 未知 `event_type` 必须被忽略而不是报错，以支持服务端向前演进。
- `room.joined` 用于渲染参与者与空圆桌状态；`sequence == 0` 不参与游标计算。
- `replay.cursor_expired = true` 时使用完整 `room.joined` 快照重置本地投影和游标，再继续处理 live 事件。
- 重连后优先使用快照中的 `active_turn.turn_id` 恢复在途回合，不得自行创建替代 turn。
- `room.joined.summary` 与本地 SwiftData 都保留结论；已完成圆桌重启后必须恢复总结和只读状态。
- 结论卡只渲染议题、三个 Agent、主要观点、共识、分歧和建议，不包含 API Key、内部 ID、Prompt、公开链接、二维码或房间导入信息。
- 连接循环使用可取消的指数退避；App 进入后台时停止 Provider Task 和连接，回前台只恢复连接，不自动启动新的自动讨论，等待用户显式继续。
- 所有 Agent 在参与者卡片、消息、生成状态、总结与结论卡中始终显示 AI 标识；不提供自定义公众人物角色。
- 用户输入和 Provider 输出必须经过 `RoundtableCore.ContentPolicy`。`block` 不得发送到服务端或 Provider；`flag` 保留内容并显示“未经模型或人工审核”。
- 真实 Provider 首次调用前必须展示第三方数据提示。确认状态可以保存在 UserDefaults，但 API Key 不得进入 UserDefaults。
- 匿名会话标识使用独立 Keychain item；旧 UserDefaults 值只用于一次性迁移。
- 本地举报状态、隐藏状态和内容标记随 SwiftData 保存；删除圆桌时全部清除。
