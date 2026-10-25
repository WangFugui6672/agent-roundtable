# 量子堆栈后端技术栈调研与 Agent Roundtable 选型建议

调研日期：2026-10-25

## 结论先行

如果目标是同时匹配公司当前 HC、Agent Roundtable 项目需要和入职后的多方向成长，最合适的主栈是：

> **Python + Django + Django REST Framework + Django Channels + PostgreSQL + Redis + Celery + Docker**

这不是为了堆技术名词，而是四个招聘方向在同一个项目中的交集：

- **Native**：Android 客户端通过 REST + WebSocket 接入。
- **Python-Django 后端**：Django/DRF 提供业务 API。
- **AI/LLM**：Python 侧负责 Agent 编排、模型调用、流式输出和日志。
- **IM/实时通信**：Channels + Redis 负责群聊、心跳、广播和断线恢复。

不建议把主后端写成 Java/Spring Boot，尽管这是你目前更熟的技术。公司公开在招岗位里没有出现 Java 后端 HC；Java 能让你更快完成项目，但不能最大化与公司岗位的匹配。

## 一手招聘证据

### 公司当前职位列表

来源：[量子堆栈 BOSS 直聘职位页](https://www.zhipin.com/gongsi/job/4fa053a6225044921nd90969FVU~.html)

公开页面显示 9 个在招职位，其中与后端和 AI 工程相关的包括：

- Python-Django 后端开发工程师。
- AI-Python-AIGC 研发工程师。
- 大模型开发工程师（IM 项目）。
- AI-JS 全栈工程师（AIGC/IM/工作流）。

这说明公司的人才需求不是单一移动端，而是围绕 Python、AI、全栈、IM 和 Native 的多方向组合。

### Python-Django 后端开发工程师

来源：[职位详情](https://www.zhipin.com/job_detail/6d0b032d7832bc090nZ73di8F1FT.html)

明确信息：

- 岗位名称直接包含 Python 和 Django。
- 工作地点厦门，公开要求 1-3 年、本科。
- 公开 JD 强调“可运行的代码、可演示的项目 demo 和 GitHub/Gitee 链接”，胜过只堆技术栈的简历。
- 公开 JS 数据中岗位更新时间显示为 2026-09-25。
- 未登录时更多技术关键词被隐藏，因此不把未公开内容当成事实。

判断：

- 这是后端方向最直接的 HC 信号。
- 该项目如果能提供可运行 Demo、源码和架构说明，会比只写“熟悉 Django”更有效。

### AI-Python-AIGC 研发工程师

来源：[职位详情](https://www.zhipin.com/job_detail/4a23296a57e453b71X1-2Nq7FFFT.html)

公开技能标签：

- Python。
- Django。
- PostgreSQL。
- PyTorch。
- TensorFlow。
- OpenCV。
- NumPy。
- LLM。
- 机器学习。

公开工作内容：

- AIGC 产品线研发。
- 图形、TTS 技术栈。
- 数据处理、模型训练、模型微调和推理链设计。

判断：

- 即使这个岗位偏模型方向，Django 和 PostgreSQL 仍然出现在公司公开标签中。
- Python 是公司 AI 和 Web 后端的共同语言。

### 大模型开发工程师（IM 项目）

来源：[职位详情](https://www.zhipin.com/job_detail/c12a2e7bfed018040nV529q0EldT.html)

公开信息：

- 可接收 2027 届本科或研究生实习。
- 无学历硬性要求，强调项目能力。
- 接受个人开源的 Vibe Coding 项目或 GitHub 链接。
- 涉及 IM 对话、实时文字和语音交互。
- 涉及 QWEN3、LoRA 微调、GPT-Sovits、MNN-Chat、TensorRT-LLM 和 vLLM。

判断：

- 该岗位偏模型推理与微调，不是普通业务后端。
- 但它明确把 IM、实时交互和 Python AI 生态放在同一条产品线上。
- Agent Roundtable 的 WebSocket、流式输出和 LLM Provider 抽象与这条方向相邻。

### AI-JS 全栈工程师（AIGC/IM/工作流）

来源：[职位详情](https://www.zhipin.com/job_detail/68b1fab8acd63ffe03d92ty4ElJS.html)

公开信息：

- 用 React 开发 Web/iOS/Android/桌面端应用。
- IM 长连接、消息队列、动态心跳。
- 百万级并发实时通信。
- Canvas.js 可视化工作流和高精度渲染。
- 接入 Claude 等 AI 编程工具。
- 涉及 MCP、文件解析和 TTS。

判断：

- 该岗位说明公司也重视 TypeScript/React 和 IM 架构。
- 但它是“JS 全栈”方向，不等于公司业务后端统一使用 Node.js。
- 不应据此把 Agent Roundtable 主后端改成 Node.js；更合理的是保留标准 JSON WebSocket 协议，未来可以由 TypeScript 客户端或服务接入。

## 外部面试题项目提供的间接证据

下面两个仓库不是公司官方源码，不能证明生产环境一定使用这些技术，但它们与公司公开招聘方向相互印证。

### GoldBadge/techlz_interview

来源：[GitHub 仓库](https://github.com/GoldBadge/techlz_interview)

可核验内容：

- 项目名为 `techlz_interview`。
- 使用 `Django 5.2.*`。
- 使用 `psycopg[binary]` 连接 PostgreSQL。
- `compose.yml` 使用 PostgreSQL 15。
- 提供 Docker Compose 启动方式。
- 创建于 2025-09-09。

证据强度：

- 属于候选人/外部技术测试实现，**不能当作公司内部架构事实**。
- 但可说明 Django + PostgreSQL 是相关技术面试中的实际使用方向。

### Akai-sky/Blog

来源：[GitHub 仓库](https://github.com/Akai-sky/Blog)

仓库描述：

> 量子堆栈 Python-Django 测试题 3.0

可核验内容：

- Django 4.2。
- Django REST Framework。
- django-redis。
- Celery。
- Redis。
- django-filter。
- MySQL/PostgreSQL 驱动依赖。
- 代码中包含 Celery 定时任务和 Redis 缓存。

证据强度：

- 同样是外部面试题实现，不是公司生产源码。
- 但说明 Django、DRF、Redis、Celery 和关系型数据库与公司后端考题方向高度一致。

## 为什么不优先选 Java/Spring Boot

你的现有简历有 Java、Spring Boot、RuoYi、MyBatis 和 MySQL 经验，用 Java 做后端本来最快。

但本次目标不是“最快完成”，而是同时满足：

- 项目能投 Native 实习。
- 未来能转 Python/Django 后端。
- 能接触 AI/LLM 和 IM。

公司公开岗位中：

- Java 后端没有出现。
- Node.js/TypeScript 出现在 AI-JS 全栈方向。
- Python/Django 有独立 HC。
- Python 同时覆盖 AIGC、大模型和 Django 后端。

因此 Java 更适合作为你的既有优势，而不是这个新项目的主栈。

## 推荐技术栈

| 层次 | 选型 | 作用 |
|---|---|---|
| 语言 | Python 3.12+ | 后端、Agent 编排、LLM 调用 |
| Web 框架 | Django 5.x | 业务模型、管理后台、鉴权 |
| API | Django REST Framework | Room、Agent、消息和总结 API |
| 实时通信 | Django Channels | WebSocket 群聊和流式事件 |
| Channel Layer | channels-redis | 多进程广播、房间订阅 |
| 数据库 | PostgreSQL | 用户、房间、Agent、消息、总结 |
| 缓存 | Redis | Channel Layer、缓存、限流 |
| 异步任务 | Celery + Redis | 总结、清理、离线任务 |
| API 文档 | drf-spectacular | OpenAPI 和客户端联调 |
| 测试 | pytest + pytest-django | 调度器、API、WebSocket 测试 |
| 部署 | Docker Compose | Django、PostgreSQL、Redis 本地一键启动 |
| LLM | OpenAI-compatible Provider + Mock Provider | 可替换模型并支持离线测试 |

## Agent Roundtable 后端架构

```text
Android Client
  REST: 创建房间、查询历史、获取总结
  WebSocket: 群聊事件、Agent 状态、流式输出
          |
          v
Django + DRF
  - Room CRUD
  - Agent 配置
  - 历史消息
  - 总结
          |
          +---- Django Channels
          |       - room group
          |       - typing / pass / message.delta
          |       - resume cursor
          |
          +---- Agent Orchestrator
          |       - 发言调度
          |       - 引用与立场
          |       - 轮数和 Token 预算
          |
          +---- LLM Provider
          |       - OpenAI-compatible
          |       - Mock Provider
          |
          +---- Celery
                  - 最终总结
                  - 长任务清理

PostgreSQL: 持久化
Redis: Channels、缓存、Celery broker
```

## 为什么不是 FastAPI

FastAPI 在异步流式和 AI 服务上很顺手，但公司当前有明确的 Python-Django 后端 HC，而 FastAPI 不在公开 JD 中。

如果做纯模型推理服务，FastAPI 很合适；但本项目同时需要：

- 用户和房间模型。
- Django Admin 调试。
- 鉴权和业务管理。
- 历史消息。
- 最终总结。

这些是 Django 更擅长的部分。Django Channels 已经可以提供 WebSocket，不需要在第一版同时引入 FastAPI。

后续如果需要独立推理服务，可以再把模型网关拆成 FastAPI，而不是一开始就做双后端。

## 为什么不把 Node.js 作为主后端

AI-JS 岗位确实说明公司使用或重视 JS 全栈和 IM，但你的项目只需要证明：

- 标准 WebSocket 协议。
- 多 Agent 事件流。
- 移动端状态恢复。
- 后端可靠编排。

这些用 Django Channels 可以实现。把 Node.js 也做进来会增加第二个服务、第二套部署和双份状态管理，降低完成度。

更合理的做法是：

- 主后端使用 Django。
- WebSocket 事件定义成语言无关 JSON。
- 未来可以用 TypeScript 实现 Web 客户端或独立 Gateway。

## 你在简历中应体现的技术关键词

项目完成后可以写：

> Python · Django · Django REST Framework · Django Channels · PostgreSQL · Redis · Celery · WebSocket · Docker

不要提前写尚未实现的内容。如果你最终只做了 WebSocket，并没有真正使用 Celery，就不要在简历里加入 Celery。

## 对入职后发展的帮助

这套栈让你以后可以向四个方向移动：

1. **Native 开发**：Android 客户端和端侧 AI。
2. **Python/Django 后端**：现有后端 HC。
3. **AI 应用/Agent 工程**：LLM 编排、流式输出、工具调用。
4. **IM/实时系统**：WebSocket、心跳、重连、消息恢复。

这也解释了为什么一个 Native 实习生做这个项目是合理的：它不是转去做算法，而是用原生客户端驱动完整的 AI 应用链路。

## 最终建议

后续不要同时比较 Django、FastAPI、Spring Boot 和 Node.js。直接采用：

> **Python 3.12 + Django 5 + DRF + Channels + PostgreSQL + Redis + Celery + Docker**

客户端采用 Android 原生：

> **Kotlin + Jetpack Compose + WebSocket + Room**

这一组合最符合公司当前 HC 的组合，也最适合 Agent Roundtable 的实时群聊场景。

