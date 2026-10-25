# AI 多智能体群聊：产品与开源项目调研

调研日期：2026-10-25

## 结论先行

“多个 AI 角色在群聊里互相接话，用户可以随时加入”的产品已经存在，而且不只一个。差异主要在两种定位：

1. **陪伴/角色扮演型**：重点是人格、关系、情绪价值和自然闲聊。
2. **任务/决策型**：重点是围绕一个问题给出多种观点，进行比较、辩论和总结。

目前最接近“用户提出一个问题，多个 AI 发表观点并互相评价”的产品包括：

- **Huddle: AI Group Chat**：一个问题和多个性格不同的 AI 角色，可拉 2-4 个进入私人群聊，角色会记住参与过的对话。
- **Persona Chat**：明确支持多个角色“与用户以及彼此互动”，使用智能路由决定谁回复，并自动总结长对话。
- **MyGang.ai**：AI 好友群，角色会互相接话、回应和打趣，强调朋友群氛围与长期记忆。
- **Friends - AI Group Chat**：多个 AI 伙伴讨论想法、共同写故事、玩游戏，也可以由任务助手拆解目标并汇总结果。
- **筑梦岛**：国内移动端产品，App Store 介绍明确支持“多角色梦屋群聊”。
- **HiWaifu**：最多 10 个角色群聊，角色既与用户对话，也会彼此对话。

因此，这个想法不是产品空白。真正可区分的方向不是“再多接几个模型”，而是：

> **有明确议题、可见的观点分歧、引用式互相评价、用户裁决，以及最终共识/行动建议的 AI 圆桌群聊。**

GitHub 上也已经有多个高度相关的项目，但截至 2026-10-25，没有发现一个成熟开源项目同时满足全部条件：

- 多 Agent 自主群聊。
- 动态选择发言者，并允许 Agent 主动沉默。
- 引用、评价或反驳其他 Agent。
- 用户可以随时插话和改变方向。
- 实时同步、持久化和断线恢复。
- 有成熟的桌面端或移动端客户端。
- 许可证允许后续产品化。
- 仍在积极维护。

## 商业产品

### Huddle: AI Group Chat

- 来源：[App Store 官方产品页](https://apps.apple.com/us/app/huddle-ai-group-chat/id6810903304)
- 一个用户问题会匹配多个不同声音、观点和表达风格的 AI 角色。
- 用户可选择 2-4 个角色进入私人群聊。
- 角色会记住自己参与过的对话，并允许用户补充照片、截图、链接或发起语音通话。
- 与用户设想的接近程度：**很高**。
- 需要进一步核验：角色之间是否强制引用、评价彼此，以及是否输出结构化的分歧和结论。

### Persona Chat - AI Characters

- 来源：[App Store 官方产品页](https://apps.apple.com/us/app/persona-chat-ai-characters/id6480217280)
- 官方描述明确写明 AI 角色会与用户以及彼此互动。
- 使用 smart routing 根据上下文决定哪个角色回复。
- 支持角色插话、长对话自动总结、角色创建、记忆和 Lorebook。
- 与用户设想的接近程度：**很高**。
- 产品重心仍偏角色扮演和故事体验，不是决策会议工具。

### MyGang.ai

- 来源：[MyGang.ai 官方产品页](https://www.mygang.ai/)
- 用户组建一个 AI 好友群，角色会有不同声音、回复、反应和 reply chains。
- 官方强调角色之间会互相接话和打趣，形成“真实聊天线程”的感觉。
- 有长期记忆、内部梗和情感支持定位。
- 与用户设想的接近程度：**高**，但更偏陪伴而不是任务讨论。

### Friends - AI Group Chat

- 来源：[App Store 官方产品页](https://apps.apple.com/us/app/friends-ai-group-chat/id6759603154)
- 可邀请多个 AI 伙伴进入群聊，讨论想法、合作写故事或玩游戏。
- 任务助手可把目标拆成步骤、引入伙伴并汇总结果。
- 支持自定义角色、分享码导入、群聊总结。
- 与用户设想的接近程度：**高**。

### HiWaifu

- 来源：[App Store 官方产品页](https://apps.apple.com/us/app/hiwaifu-ai-character-chat/id6447806780)
- 最多支持 10 个角色进入同一个群聊房间。
- 官方描述明确写明角色会彼此交谈，也会与用户交谈。
- 更偏角色扮演、恋爱和沉浸式剧情。

### 筑梦岛

- 来源：[中国大陆 App Store 产品页](https://apps.apple.com/cn/app/id6465838500)
- App Store 官方介绍明确支持“组建多角色梦屋进行群聊”。
- 使用场景包括修罗场、磕 CP、家庭群聊等，偏娱乐和剧情互动。
- 说明国内移动端已有多角色 AI 群聊产品。

### Shapes, Inc. - AI with friends

- 来源：[App Store 官方产品页](https://apps.apple.com/us/app/shapes-inc-ai-with-friends/id6747601762)
- 定位是真人朋友与多个 AI 在同一房间协作。
- 支持不同观点、研究问题、旅行规划、学习和写代码。
- 与用户设想的接近程度：**中高**，但核心是“真人多人 + AI”，不是用户独自观看 AI 圆桌。

### SillyTavern Group Chats

- 来源：[SillyTavern 官方文档](https://docs.sillytavern.app/usage/core-concepts/groupchats/)
- 支持 Manual、Natural Order、List Order、Pooled Order 等发言顺序。
- Natural Order 会识别角色名字、Talkativeness 和随机因素决定谁说话。
- 支持 Auto-mode，让角色在没有用户操作时持续生成回复。
- 支持共享群聊历史、静音角色、强制指定角色发言。
- 更接近开发者和重度角色扮演用户的桌面工具，不是消费级移动产品。

## 产品分类

| 类型 | 代表产品 | 主要价值 | 与用户想法的差异 |
|---|---|---|---|
| 陪伴型 AI 好友群 | MyGang、Persona Chat、HiWaifu | 情绪陪伴、关系、人格互动 | 更重闲聊和角色沉浸，不一定有结构化结论 |
| 角色扮演群聊 | 筑梦岛、Persona Chat、HiWaifu | 多人剧情、修罗场、故事推进 | AI 会互相对话，但通常不强调观点评价和决策 |
| 决策/多视角群聊 | Huddle、Friends | 一个问题获得多个视角、任务拆解 | 最接近；需确认互相批评和证据引用的深度 |
| 真人 + AI 协作 | Shapes、Sircle | 真人团队和 AI 同房间工作 | 用户设想更偏 AI 群体自动讨论 |
| 多模型比较 | Poe、askROI | 多模型回答同一问题、比较答案 | 模型通常不会像真人一样自主互评 |
| 自托管群聊工具 | SillyTavern | 高度可配置的发言顺序和角色卡 | 工程参考价值高，但不是完整消费产品 |

## 仍存在的产品机会

如果把这个方向做成面试项目，建议避开“通用 AI 朋友群”红海，突出以下差异：

1. **结构化议题**：主持人先生成讨论议程，再分配给不同角色。
2. **引用式互评**：每条评价必须引用某条具体观点，明确 agree/disagree。
3. **分歧可视化**：最终展示共识、分歧、风险、行动建议，而不是只给一段总结。
4. **用户裁决**：用户可以投票、打断、点名、要求重开某个论点。
5. **成本与节奏控制**：限制人数、轮数、总 Token 和单轮时长，避免无限群聊。
6. **原生移动体验**：正在输入、引用回复、轮次状态、断线恢复、分享结论卡。
7. **中文消费场景**：旅行决策、消费选择、学习讨论、产品脑暴，而不是纯角色扮演。

## 对项目定位的建议

不建议把项目宣传成“首个 AI 群聊”，因为已有产品。更可信的定位是：

> **Agent Roundtable：一个让多个 AI 围绕具体问题结构化讨论、互相质疑，并输出共识与分歧图的移动端 AI 圆桌。**

这一定位既保留“像真人群聊”的体验，又有比角色陪聊更明确的任务价值。

## GitHub 开源项目

### 最接近产品形态的项目

| 项目 | 群聊与发言机制 | 互评能力 | 客户端 | 许可证 | 最近推送 | 判断 |
|---|---|---|---|---|---|---|
| [multi-agent-group-chat](https://github.com/gyhdc/multi-agent-group-chat) | 动态选人、直接挑战、饥饿补偿、用户证据加权 | 有 `replyTo`、`forceReply`、评审角色和记录员 | Web | 未找到明确许可证 | 2026-04-20 | 产品语义最贴近，但不能直接复制代码 |
| [Talkio](https://github.com/llt22/talkio) | `@` 指定、轮流、托管讨论 | 共享上下文和角色立场，无结构化评价协议 | Tauri 桌面端、Android 页面 | MIT | 2026-10-19 | 产品 UI 和工程完成度最高 |
| [AI 단톡방](https://github.com/Moris-kr/ai-chatroom) | Agent 自主 `say/pass`，有沉默破冰 | 支持 `@`、`reply_to` 和反应，但没有评价模型 | Web | MIT | 2026-10-16 | 最像真人自由群聊 |
| [Rikkahub 华灯](https://github.com/MiaoWuNYA/rikkahub-sillytavern-android) | 自然 AI 选择、列表、加权随机、手动 | 共享历史，可自定义角色和提示词 | Android，Kotlin/Compose | AGPL-3.0 | 2026-10-22 | 移动端 turn-taking 最成熟 |
| [UiharuMind](https://github.com/CWHISME/UiharuMind) | 串行/并行轮次、主持、离席托管 | Agent 可见彼此内容和共享 artifact | 桌面端 | Apache-2.0 | 2026-10-22 | 更像 Agent 群聊工作台 |
| [AgentPeerChat](https://github.com/AgenticsWorks/AgentPeerChat) | 消息路由，不是自动发言 | linked reply、共享线程，决策由外部 Agent 完成 | Web、CLI | MIT | 2026-10-24 | 适合参考 durable inbox |
| [dsh-attention-group](https://github.com/cilarx/dsh-attention-group) | 规则、语义、广播三种唤醒方式 | 有引用和结论转发，无评价模型 | DSH 面板 | MIT | 2026-10-22 | “先路由，再唤醒”值得借鉴 |
| [SillyTavern](https://github.com/SillyTavern/SillyTavern) | Manual、Natural、List、Pooled、Auto-mode | 共享历史和角色互相提及 | Web | AGPL-3.0 | 2026-10-02 | 群聊发言顺序最成熟的公开参考 |
| [Mantella](https://github.com/art-from-the-machine/Mantella) | NPC 可主动发起、加入和互相聊天 | 有记忆和关系，无显式互评 | Skyrim/Fallout 游戏内 | AGPL-3.0 | 2026-07-16 | 自然语音群聊体验优秀，但强绑定游戏 |

### 最值得重点阅读的五个项目

#### 1. multi-agent-group-chat

- 仓库：[gyhdc/multi-agent-group-chat](https://github.com/gyhdc/multi-agent-group-chat)
- 讨论逻辑最接近用户设想。
- 动态选人时考虑直接挑战、饥饿补偿、用户证据权重和硬性回复目标。
- 用户可以插话，也可以对历史消息定向回复；被点名的 Agent 优先响应。
- Agent 可以强制另一个 Agent 回答，形成追问链路。
- 有记录员 checkpoint、最终结论、完整 transcript 和 Markdown 导出。
- 风险：没有明确 LICENSE，项目规模小，实时推送和多用户并发能力证据不足。

#### 2. Talkio

- 仓库：[llt22/talkio](https://github.com/llt22/talkio)
- 多个模型进入同一群聊，支持 Persona、群组提示词、`@` 指定和轮流发言。
- 使用 SQLite 持久化，支持流式输出、MCP、上下文压缩和备份恢复。
- 提供 Tauri 桌面端和 Android 页面。
- 更适合参考群聊 UI、数据模型和客户端体验，不适合直接参考自主辩论协议。

#### 3. AI 단톡방

- 仓库：[Moris-kr/ai-chatroom](https://github.com/Moris-kr/ai-chatroom)
- 每个 Agent 可自主选择 `say` 或 `pass`，长时间沉默时会触发破冰。
- 提示词要求 Agent 不必回应每条消息，只在一到两个角色有观点时发言。
- 支持 `reply_to`、个人笔记和共享 workspace。
- 使用 SSE 推送，JSONL 保存消息，JSON 保存房间状态。
- 最能借鉴“混合主动权”和“主动沉默”。

#### 4. Rikkahub 华灯

- 仓库：[MiaoWuNYA/rikkahub-sillytavern-android](https://github.com/MiaoWuNYA/rikkahub-sillytavern-android)
- Kotlin + Jetpack Compose 的原生 Android 多角色聊天应用。
- 支持自然 AI 选择、列表顺序、加权随机和手动选择发言人。
- 支持自动回复轮数、可配置延迟、用户消息打断自动回复和实时说话人状态。
- 移动端体验最值得参考，但产品定位是角色扮演，且使用 AGPL-3.0。

#### 5. AG2

- 仓库：[ag2ai/ag2](https://github.com/ag2ai/ag2)
- 提供 Hub、typed channel、write-ahead log、audit trail、历史压缩和人机协作。
- 内置 conversation、discussion 和 workflow 等频道类型。
- 适合作为可靠后端基础，但 discussion 默认仍偏 round-robin。
- 仍需自己实现动态发言评分、结构化互评、客户端和产品记忆。

### 底层多 Agent 框架

| 项目 | 适合用途 | 主要限制 |
|---|---|---|
| [AG2](https://github.com/ag2ai/ag2) | 可靠群聊后端、频道、WAL、审计 | 没有成品群聊客户端 |
| [Microsoft Agent Framework](https://github.com/microsoft/agent-framework) | 生产级 group collaboration、handoff、checkpoint | 偏企业框架 |
| [CrewAI](https://github.com/crewAIInc/crewAI) | 任务流水线和确定性工作流 | 不是自由群聊 |
| [CAMEL](https://github.com/camel-ai/camel) | Agent societies、动态通信和研究 | 产品层需要自建 |
| [MetaGPT](https://github.com/FoundationAgents/MetaGPT) | 软件团队式 SOP 和角色分工 | 流程固定 |
| [ChatDev 2.0](https://github.com/OpenBMB/ChatDev) | 多 Agent 工作流、评审、日志和回放 | 更偏任务编排 |
| [LangGraph](https://github.com/langchain-ai/langgraph) | 状态图、durable execution、HITL | 需要自行设计群聊体验 |
| [AgentVerse / ChatEval](https://github.com/OpenBMB/AgentVerse) | 多评审角色辩论和 Agent 互评研究 | 2024 年后基本停滞 |
| [Generative Agents](https://github.com/joonspk-research/generative_agents) | 记忆、反思、计划和社会模拟 | 研究原型，不是实时群聊产品 |

Microsoft AutoGen 的 README 已明确标记项目归档，新项目不建议直接采用。需要类似能力时，应优先查看 AG2 或 Microsoft Agent Framework。

### 开源项目暴露出的真实缺口

综合这些项目和商业产品，目前最明显的缺口不是“多个 AI 能否说话”，而是：

1. **发言权如何分配**：多数项目只支持 mention、随机、轮流或简单概率，缺少“相关性 + 专业度 + 分歧度 + 成本”的综合调度。
2. **互评如何结构化**：很少存在 `reply_to + stance + claim + evidence + challenge` 这样的协议。
3. **何时结束**：多数项目依赖固定轮数，缺少基于分歧收敛和成本预算的停止条件。
4. **用户如何接管**：可以发送下一条消息不等于可以暂停、打断、重排或分叉整个讨论。
5. **群聊记忆如何分层**：缺少“Agent 私有记忆 + 群共享事实 + 用户可纠正记忆”的清晰模型。
6. **移动端实时状态**：谁在想、谁选择沉默、谁正在被点名，以及断线后如何恢复，仍有很大设计空间。

### 许可证提示

- MIT 或 Apache-2.0：更适合参考或二次开发，但仍需检查依赖。
- AGPL-3.0：SillyTavern、Rikkahub、Mantella、taOS 等项目在对外提供修改版网络服务时可能产生额外义务。
- [multi-agent-group-chat](https://github.com/gyhdc/multi-agent-group-chat) 未找到明确 LICENSE，不应默认可以复制或用于闭源产品。

本文不是法律意见。准备商业发布时需要单独复核许可证。

## 对项目立项的最终判断

这个方向**可以做，但不能把“多个 AI 群聊”本身当作创新点**。商业产品和开源实现都已经证明这个能力可行，招聘方更关心你能否做出：

- 可解释的发言调度。
- 有引用关系的观点网络。
- 可控的用户打断和讨论重排。
- 成本、轮数和收敛控制。
- WebSocket 断线恢复和移动端实时状态。
- 共识、分歧和行动建议的最终结构。

面试表达可以这样定位：

> 我参考了 Huddle、Persona Chat、Talkio、Rikkahub 和 AG2，但没有把项目做成普通角色群聊。我的重点是发言调度、结构化互评、用户接管和结论收敛，并用 Android 原生客户端把这些状态完整呈现出来。

这比声称“市面上没有类似产品”更可信，也能说明你不是只跟着一个想法写代码，而是做过竞品和开源调研。

