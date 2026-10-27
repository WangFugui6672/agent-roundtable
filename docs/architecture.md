# Agent Roundtable 架构

**版本：** MVP v0.1.0

```mermaid
flowchart LR
    subgraph Device["用户设备"]
        UI["SwiftUI App"]
        Core["RoundtableCore<br/>投影 / 游标 / Provider Client"]
        Store["SwiftData<br/>圆桌快照与事件游标"]
        Keychain["iOS Keychain<br/>API Key"]
    end

    subgraph Provider["用户选择的 Provider"]
        LLM["Qwen / DeepSeek /<br/>OpenAI-compatible API"]
    end

    subgraph Backend["Django 后端"]
        REST["REST API"]
        WS["Django Channels WebSocket"]
        Scheduler["Turn Scheduler"]
        Events["持久化事件日志"]
    end

    Postgres[("PostgreSQL")]
    Redis[("Redis Channel Layer")]
    Celery["Celery worker + beat"]

    UI --> Core
    Core --> Store
    Core --> Keychain
    Core -->|"HTTPS + Bearer API Key<br/>不经过 Django"| LLM
    Core -->|"HTTP / WebSocket"| REST
    Core -->|"HTTP / WebSocket"| WS
    REST --> Scheduler
    WS --> Scheduler
    Scheduler --> Events
    Events --> Postgres
    REST --> Postgres
    Scheduler -->|"跨进程广播"| Redis
    Redis --> WS
    Celery -->|"每日保留清理"| Postgres
    Celery --> Redis
```

## 信任边界

- API Key 只在 SwiftUI/`RoundtableCore` 的 Provider 调用路径和 iOS Keychain 中出现。
- Django 只接收 Provider 类型、BaseURL、Model 等非秘密元数据；发现任何 `api_key` 形态字段会直接拒绝请求。
- 真实模型请求由 iOS 直连 Provider。用户内容进入 Provider 前会经过本地内容策略和首次第三方数据提示。
- Django 是圆桌状态、turn 签发、消息顺序、事件日志和结论版本的服务端权威。
- PostgreSQL 保存圆桌、消息、turn、事件、用量、结论和举报；Redis 只承担 Channels 跨进程广播，不替代持久化事件补发。

## 一次真实 Turn 的顺序

1. iOS 调用 `POST /turns/next`，Django 在事务中签发唯一 pending turn 并持久化 `agent.thinking`。
2. iOS 直连 Provider，流式内容只在当前设备临时展示。
3. iOS 将结构化消息提交到 `POST /messages`，或通过 `/turns/pass`、`/turns/fail` 关闭 turn。
4. Django 校验 turn、Agent、引用和预算，写入 PostgreSQL，并通过 Redis 广播事件。
5. iOS 按 `event_id` 去重、按 `sequence` 推进游标，同时写入 SwiftData。
6. 断线后 iOS 携带最后游标重连；服务端从事件日志补发，游标过期时发送完整 `room.joined` 快照。

## 部署拓扑

`docker-compose.yml` 定义六个服务，其中五个常驻：

- `db`：PostgreSQL 16。
- `redis`：Redis 7，启用 AOF。
- `backend`：Daphne + Django ASGI，启动前自动执行迁移。
- `worker`：Celery worker，执行保留清理等后台任务。
- `beat`：Celery beat，每日把 `purge_expired_roundtables_task` 投递到 Redis broker。
- `purge`：可选 `ops` profile，执行 90 天保留清理。

`purge` 是一次性运维容器，不计入常驻服务。本地单元测试默认不要求 Redis；设置 `REDIS_URL` 后才启用 `channels_redis`。Compose 始终设置 Redis，避免多进程广播失效，并为 Celery 提供 broker。

## 历史与删除墓碑

iOS 首页合并 `GET /roundtables` 与 SwiftData 历史。打开缓存圆桌时先恢复完整消息、失败、结论、游标和最近可见消息，再连接 WebSocket 补发增量。

服务端删除圆桌成功后，Repository 先向 SwiftData 写入持久删除墓碑，再删除缓存。此后即使本地物理删除失败或进程崩溃，恢复路径也必须跳过该圆桌；墓碑优先于旧缓存，防止已删除内容复活。
