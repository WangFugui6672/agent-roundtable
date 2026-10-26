# 结论使用独立版本化实体，继续追问创建新圆桌

**Status:** accepted

圆桌结论包含共识、分歧、建议、未决问题和每项的引用消息 ID。如果把它写成普通 `Message`，会复用消息作者、turn 和引用规则，并让第二轮观点校验把总结误当成 Agent 发言。因此后端使用一对一的 `RoundSummary` 实体，客户端通过 `summary.completed` 事件和 `room.joined.summary` 恢复。

结论可以重新生成，但不能直接编辑。提交携带 `expected_version`：首次为 0，成功后保存为版本 1；重新生成以当前版本为基准递增。旧版本且内容完全相同的请求视为幂等网络重试，其他版本冲突返回 `409`，避免覆盖较新的结论。

## Consequences

- 消息流、第二轮引用候选和总结保持分层，不会出现 `message_type=summary` 的伪观点。
- 每次成功重生成都会产生新的 `summary.completed` 事件，历史事件可补发，但数据库保留当前最新结论版本。
- 完成态圆桌只读。继续追问必须创建新圆桌，并通过 `parent_roundtable_id`、`source_summary_id` 和 `follow_up_context` 保留原议题与原结论关系。
- iOS 仍负责直连 Provider 生成结论；Django 只能验证结构、引用归属和版本，不能把语义“无新事实”包装成完全自动化的安全保证。
