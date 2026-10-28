# Agent Roundtable Glossary

本文件定义产品、设计和代码中使用的固定术语。实现、Issue 标题、测试名称和 PR 描述应使用这里的规范词。

## 圆桌（Roundtable）

围绕一个明确议题创建的一次 AI 讨论会话。圆桌包含参与者、轮次、消息、状态和结论。

不要与“聊天室”混用。聊天室强调自由聊天，圆桌强调一个议题和收敛结果。

## 房间（Room）

圆桌在实时协议中的连接上下文。`room_id` 始终等于圆桌 ID，事件名沿用 PRD 的 `room.*` 前缀（如 `room.joined`）；产品和界面文案仍统一称“圆桌”，不把房间当成第二个实体。

## 议题（Topic）

用户希望 Agent 讨论的核心问题或决策。议题必须在创建圆桌时确定，并在讨论过程中保持可追溯。

## Agent

具有身份、目标、立场和表达风格的 AI 参与者。一个 Agent 在不同圆桌中可以使用不同的实例配置。

不要使用“机器人”“角色”作为实现术语。面向用户可以使用“AI 伙伴”或“AI 角色”作为展示文案。

## AgentProfile

可复用的 Agent 基础定义，包括名称、简介、专长、默认立场、表达风格和禁止行为。

## RoundtableAgent

AgentProfile 在某个圆桌中的实例。它保存该圆桌内的当前目标和状态。

## Turn（回合）

服务端签发给单个 RoundtableAgent 的一次发言任务，包含稳定 `turn_id`、轮次和 Agent。iOS 执行 Provider 后必须用同一个 `turn_id` 提交发言或 pass；同一圆桌同一时间最多存在一个待完成 turn，每位参与者在每轮最多有一个 Turn。

## Turn 失败（Turn Failure）

单个 Turn 在 Provider 请求、网络、超时或结构化校验失败后进入的终态。失败带稳定 `failure_code`、用户可读原因、`retryable` 和可选 partial，以 `agent.failed` 事件关闭当前 Turn；它不等于整场圆桌失败，也不删除已完成消息。

## 用量记录（UsageRecord）

每个 Turn 一条的可观测记录，保存模型快照、输入/输出 Token（若客户端可取得）、延迟、重试次数和失败码。不得保存 Prompt 正文、Provider 完整响应或 API Key。

## 客户端上报 Token

BYOK 架构下，Django 看不到 Provider 的真实 Token。iOS 从 SSE `usage` 解析后上报的数字只用于展示和成本观察，不是服务端计费级计量，也不触发讨论结束。服务端可靠强制的是轮数、消息数、Turn 截止时间和整场时间。

## 预算耗尽（Budget Exhausted）

圆桌仍有潜在发言空间，但时长或 Agent 消息数已达到上限时的终态。它只产生一次 `budget.exhausted` 事件；若最后一轮已经自然完成，则 `round.completed` 优先，不再追加预算耗尽事件。

## 进行中圆桌限额

同一匿名会话最多同时保留 3 个 `ready | running | paused | summarizing` 圆桌。Mock 圆桌另受每 UTC 日 10 个的创建限额；真实 Provider 圆桌没有每日创建上限。

## 参与者（Participant）

圆桌快照与界面中对 RoundtableAgent 的称呼。`participants` 数组就是该圆桌的 RoundtableAgent 列表，顺序由 `position` 决定。

## 主持人（Host）

负责生成议程、安排发言顺序、控制轮数和生成最终结论的系统角色。主持人不参与普通观点竞争。

## 轮次（Round）

圆桌中的一次讨论周期。MVP 包含第一轮观点表达和第二轮引用式互评。

## 发言（Message）

用户、Agent、主持人或系统产生的一条可持久化内容。Agent 消息必须遵循结构化消息协议。

消息作者用 `author.type` 显式区分：

- `agent`：必须关联 `RoundtableAgent` 和当前 `Turn`。
- `user`：用户消息，不关联 Agent，不要求 claim 或立场。

代码与协议不要把用户消息改写成 Agent 消息。

## 用户消息（User Message）

用户插入普通讨论内容或点名 Agent 的群聊消息。用户消息会持久化、参与后续 Agent 上下文，并可携带显式 `mentioned_agent_ids`。正文中的 `@名字` 只是展示文本，不是调度依据。

## 点名（Mention）

用户通过一个或多个 `RoundtableAgent.id` 明确要求某位 Agent 在下一 turn 优先回应。被点名者必须是当前圆桌参与者；调度器只把仍然可发言的参与者作为优先候选。

## 暂停边界（Pause Boundary）

用户插话或请求暂停后，允许当前已签发 turn 完成其 message/pass 的安全边界。存在在途 turn 时先记录 `pause_pending`；当前 turn 关闭后才进入 `paused`。暂停不是取消当前 Provider 生成，提前结束才是。

## 暂停（Paused）

圆桌停止自动签发新 turn 的状态。只有显式继续可以恢复自动讨论；用户仍可在暂停状态下发送其他用户消息。

## 提前结束（End）

用户主动把圆桌推进到 `completed`。服务端取消 pending turn，后续 message、pass 和 turn 签发均被拒绝；客户端同时取消本地 Provider 生成 Task。

## 主张（Claim）

一条发言中的核心命题，通常是一句话。结论和观点面板优先引用 Claim，而不是整段正文。

## 关键观点（Key Point）

用户在一场圆桌中标记为优先参考的、有效的 Agent 观点。关键观点只增加 `is_key_point` 元数据，不修改消息正文、不改变引用关系，也不使消息不可删除。生成结论时，关键观点排在普通候选之前。

## 回复版本（Reply Version）

用户要求重新生成某条 AI 回复后产生的新消息。旧消息继续保存原正文和引用，新消息通过 `supersedes_message_id` 指向它，旧消息通过 `superseded_by_message_id` 暴露被替代关系。版本链不是正文覆盖。

## 引用（Reference）

一条消息对另一条具体消息的明确关联。第二轮的有效 Agent 发言必须引用同一圆桌中更早产生、来自其他参与者的有效 Agent 观点。用户消息、自身观点、pass、summary、未知消息和跨圆桌消息都不是合法引用目标。

## 立场（Stance）

Agent 对其他观点的关系。合法值包括：

- `support`：支持。
- `challenge`：质疑或反对。
- `supplement`：补充。
- `question`：追问。

## 挑战（Challenge）

一种要求特定 Agent 回应某条观点的行为。挑战带有 `challenge_target_agent_id`，目标必须是当前圆桌参与者，并且是被引用观点的作者；挑战关系不保证被挑战者必须同意。

## 沉默（Pass）

Agent 评估当前消息后决定不发言的状态。Pass 是正常行为，不是错误，也不产生普通消息；它以 `agent.passed` 事件关闭当前 turn。

## 轮次调度器（Turn Scheduler）

根据点名、相关度、分歧度、待回复关系、发言间隔和预算决定下一位发言者的后端模块。

## 共识（Consensus）

讨论中被多数相关 Agent 明确支持，且没有同等级反证的结论。

## 分歧（Dissent）

讨论中仍然存在明确反对或未解决冲突的观点。分歧不应被总结成虚假的共识。

## 结论（RoundSummary）

圆桌结束时生成的结构化结果，包含共识、分歧、建议、未决问题和引用依据。

结论与普通 `Message` 是两个实体。每个结论项必须引用当前圆桌中已经存在的有效 Agent 观点；`degraded = true` 表示模型摘要失败后使用了规则化降级，但引用仍必须真实。

## 结论版本（Summary Version）

同一圆桌结论的非负单调版本。首次提交从版本 1 开始，重新生成必须提交当前 `expected_version`；旧版本且内容完全相同的网络重试是幂等的，其他过期版本返回冲突。

## 结论卡（Summary Card）

将 RoundSummary 渲染为可保存和分享的原生图片。结论卡不是讨论全文。

## 继续追问（Follow-up）

从已完成圆桌创建新圆桌。新圆桌显式保存父圆桌与原结论关系，并携带原议题和结论上下文；它不能修改父圆桌。

## 事件（Event）

通过 WebSocket 发送的实时状态或消息变化。每个事件有唯一 ID、房间 ID 和单调递增序号。

## 事件游标（Resume Cursor）

客户端记录的最后已处理事件序号。重连时用于请求补发之后的事件。

已有本地缓存时，事件游标以本机持久化值为准，不被新收到的圆桌快照覆盖。

## 补发窗口（Replay Window）

服务端允许按游标补发事件的时间范围，默认 90 天。请求游标与窗口内最早事件之间存在缺口时，服务端标记 `cursor_expired`，客户端必须使用完整 `room.joined` 快照重置本地投影和游标。

## 本地圆桌缓存（Stored Room）

iOS 用 SwiftData 保存的多桌历史快照、消息、失败、事件游标、有界事件 ID 去重集合、最近可见消息 ID 和删除墓碑。它不保存 Provider API Key。

## 删除墓碑（Deletion Tombstone）

服务端删除圆桌成功后，本机持久化的“不得恢复”标记。墓碑必须先于本地物理删除写入；即使随后 SwiftData 清理失败或进程崩溃，重启恢复也必须跳过对应圆桌。

## 匿名会话（Guest Session）

无需注册即可使用的设备会话。它用于隔离用户数据和恢复圆桌，不等同于正式账号。

匿名会话可以轮换标识：旧标识立即失效，已有圆桌转移到新标识；也可以整体删除，级联清理服务端和本机圆桌数据，但保留 Provider API Key。

## BYOK

Bring Your Own Key。用户提供自己的模型服务凭据，产品不提供或代付服务端模型额度。

## Provider（模型服务商）

用户选择的模型服务来源：Qwen、DeepSeek，或任意 OpenAI-compatible 服务。一场圆桌的所有 Agent 共用同一个 Provider。代码与协议中用 `kind` 表示它的稳定标识：`qwen | deepseek | custom`。

## Provider 配置（Provider Configuration）

一场圆桌调用模型所需的非秘密信息，包括 Provider、BaseURL 和 Model。API Key 是秘密，不属于普通 Provider 配置。

## Mock Provider

用于开发和演示的确定性 LLM 替代实现。它必须能产生稳定的测试事件，不调用真实模型。

## 讨论预算（Discussion Budget）

一次圆桌允许的最大轮数、消息数和时间。Token 用量会记录和展示，但依赖客户端上报，因此不作为强制计费或终止条件。

## 内容策略（Content Policy）

在 iOS 本机执行的可测试规则集，结果只有 `allow | block | flag`。`block` 阻止内容发送给服务端或模型服务商；`flag` 允许继续，但必须明确提示内容未经审核。

## 内容标记（Content Flag）

本地规则命中较低置信度风险后的显示状态。它不是审核结论，不代表违规，也不等同于用户举报。

## 消息举报（Message Report）

用户对当前圆桌中 AI 消息提交的投诉记录，状态固定为 `submitted`，只供维护者后续处理。MVP 不引入服务端模型审核，举报不会自动删除或改写消息。

## 本地隐藏（Local Hide）

只影响当前设备消息显示的本地状态，不删除、不改写服务端消息，也不影响其他设备。

## 最后活动（Last Activity）

圆桌创建、WebSocket 打开、消息、回合、控制命令、举报和结论保存等操作的最近时间。90 天保留以圆桌最后活动为唯一锚点。

## 第三方数据提示（Third-party Data Notice）

真实 Provider 首次调用前展示的数据发送说明。确认状态可以保存在 UserDefaults，但其中不得包含 API Key。

## 资料库（Knowledge Base）

用户在某一台设备上导入、供圆桌讨论检索引用的文档集合。资料库属于本地私有数据，不经过服务端，也不在设备之间同步。

不要与“历史圆桌”混用：历史圆桌是讨论产物，资料库是讨论的输入材料。

## 文档块（Chunk）

资料库中一篇文档被切分后的最小检索单元。文档块保留其来源文档和在该文档内的顺序位置，检索与引用都以文档块为单位。

不要与“发言”混用：文档块来自用户导入的资料，不属于圆桌消息，也不受消息的引用和立场规则约束。

## 检索结果（Retrieval Hit）

用户消息对资料库检索后，相似度达到阈值的文档块及其相似度分数。检索结果为空是正常结果，不是错误。

## 相似度阈值（Match Threshold）

判定一条文档块是否构成检索结果的最低相似度。低于阈值的文档块不进入 Agent 上下文；阈值由产品统一设定，不对用户暴露为可调参数。

## 端侧推理（On-device Inference）

模型在用户设备本地加载并生成文本，不经过服务端，也不调用云端 Provider。端侧推理与圆桌讨论中的 Provider 直连是两条独立路径，本地失败不影响圆桌讨论。

## 端侧模型（Local Model）

以 GGUF 等形式存放在设备本地的模型文件。端侧模型不进入仓库、不打进安装包，通过 Release 资产或用户导入获得。

## 模型清单（Model Catalog）

端侧模型的不可变元数据集合：文件名、体积、SHA256、下载地址和上下文窗口。模型清单是校验与展示的唯一依据。

## 首字延迟（TTFT）

从发起一次端侧生成到第一个输出 token 出现的时间，包含 prompt 预填充。

## 解码速度（Decode Speed）

首 token 之后的生成速度，单位为 tokens/s；不含 prompt 预填充阶段。

## 推理峰值内存（Peak Inference Memory）

一次端侧推理期间进程的峰值常驻内存，Android 上取 `/proc/self/status` 的 `VmHWM`。
