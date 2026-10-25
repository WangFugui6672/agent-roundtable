# BYOK 密钥保存在 Keychain，模型请求由 iOS 直连 Provider

**Status:** accepted

产品不提供或代付服务端模型额度，用户自行提供 Qwen、DeepSeek 或自定义 OpenAI-compatible Provider 的 API Key。为了让 Key 持久保留且不经过 Django，决定使用 iOS Keychain 保存 API Key，Provider、BaseURL 和 Model 保存在普通本地配置；所有模型与总结请求由 iOS 直接发送给所选 Provider，Django 只负责圆桌状态、轮次调度、消息持久化和结果校验。

## Considered Options

- 服务端代理模型请求：便于统一控制流式输出和成本，但 Django 会接触用户密钥，并需要代理用户提供的 BaseURL。
- API Key 仅保存在内存：实现简单且不持久化，但 App 重启后必须反复输入。
- Keychain 保存 Key、iOS 直连 Provider：保留本地持久化，不把 Key 发送给后端，也不需要服务端代理自定义 URL。
- UserDefaults 或 SwiftData 保存 Key：实现成本低，但不适合作为秘密存储。

## Consequences

- Django 无法直接观察 Provider 的 Token、流式响应和错误，只能接收 iOS 提交的结构化结果与用量元数据。
- Android 端以后需要实现等价的系统安全存储和 Provider Client，但继续复用同一套后端协议。
- Keychain item 使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，换机恢复后需要重新输入 Key。
- 自定义 BaseURL 的请求风险留在客户端，后端不增加任意 URL 代理能力。

