# Agent Roundtable

Agent Roundtable 是一个 iOS 原生的 AI 多智能体圆桌应用。用户提出议题并选择多个具有不同立场的 AI Agent，Agent 之间进行受控的多轮讨论、引用和评价，最终生成共识、分歧与建议。

## 项目状态

- 阶段：需求与架构设计
- 客户端：iOS 先行，Android 后续复用同一协议
- 后端：Django + DRF + Channels
- 代码管理：GitHub

## 文档

- [产品需求文档](docs/PRD.md)
- [领域术语表](GLOSSARY.md)
- [竞品与开源调研](AGENT_GROUP_CHAT_RESEARCH.md)
- [公司后端技术栈调研](QUANTUMSTACK_BACKEND_STACK_RESEARCH.md)
- [Issue Tracker 配置](docs/agents/issue-tracker.md)
- [领域文档约定](docs/agents/domain.md)

## 目标技术栈

### iOS

- Swift
- SwiftUI
- Swift Concurrency
- URLSessionWebSocketTask
- SwiftData

### Backend

- Python
- Django
- Django REST Framework
- Django Channels
- PostgreSQL
- Redis
- Celery
- Docker Compose

## 开发原则

- 先完成 iOS 纵向切片，再开发 Android。
- 不把 LLM API Key 放入客户端。
- Agent 输出使用结构化消息协议。
- 讨论必须受轮数、Token 和时间预算约束。
- 所有功能变更通过 GitHub Pull Request。

