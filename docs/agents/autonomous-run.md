# 自主执行规则

本文件定义「无人值守推进 ticket」时的边界。任何在此模式下工作的 agent 必须先读本文件。

## 范围

目标是让 Issue #20 的 ticket 图在无人确认的情况下尽可能推进到底。

## 每轮做什么

1. 读 `docs/agents/issue-tracker.md` 与 Issue #20 的子 issue
2. 找**所有阻塞项已完成**的 ticket，按 `priority:p0` → `p1` → `p2` 排序
3. 一次只做一张，做完再挑下一张
4. 每张 ticket 的完成定义：
   - 验收标准逐条满足，未满足的必须写明原因
   - `./gradlew :core:test :app:testDebugUnitTest :app:assembleDebug` 通过
   - `python3 scripts/secret_scan.py` 通过
   - 提交到 `feat/android-client` 并 push
   - 在该 ticket 上留言说明：做了什么、验证到哪一步、未完成项

## 可以自主决定

- 实现方案、文件结构、命名
- 新增依赖（仅限开源、免费、许可证兼容）
- 提交与 push 到 `feat/android-client`
- 在 ticket 上留言
- 修复自己引入的 bug，包括 amend 自己刚提交但尚未被他人使用的提交

## 必须先停下来记录、不要猜

- 验收标准与协议文档冲突
- 需要改 `docs/protocol.md`（唯一契约）
- 需要改 iOS 或 backend
- 需要花钱（订阅、云资源、付费 SDK）
- 需要真机才能验证的性能数据

遇到这些：**不要猜、不要伪造数据**，在该 ticket 留一条 `待人工决策` 留言说明卡点，然后跳过它去做下一张可做的。

## 绝对不做

- 合并到 `main`
- 把仓库改为 public
- force push `main`、删除远程分支
- 读取、打印、提交任何密钥
- 编造测试结果或性能数据
- 为了让测试通过而弱化断言

## 收尾

每轮结束若没有可继续的 ticket，写一份简短状态到 Issue #20 的留言：
完成了哪些、卡在哪些、下一步建议。
