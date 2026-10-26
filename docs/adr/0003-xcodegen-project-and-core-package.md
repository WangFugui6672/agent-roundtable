# iOS 工程由 XcodeGen 生成，核心逻辑放在 RoundtableCore 包

**Status:** accepted

`ios/project.yml` 是工程定义的唯一来源，`xcodegen generate` 生成 `AgentRoundtable.xcodeproj`；生成的工程不提交。App 只包含 SwiftUI 视图与组装代码，模型、事件解码、REST/WebSocket 客户端和圆桌状态机放在本地 Swift 包 `ios/RoundtableCore` 中。

## Considered Options

- **提交 `.xcodeproj`**：Xcode 默认可行，但 `project.pbxproj` 冲突频繁、review 噪音大，且新文件需要手工加 target。
- **只用 Swift Package，不做 App target**：无法产出可运行的 iOS App。
- **XcodeGen 生成工程 + SwiftPM 核心包**：工程文件可读、可 review，核心逻辑可用 `swift test` 在 macOS 上直接跑，不必启动模拟器；代价是 CI 与本地需要额外安装 `xcodegen`。

## Consequences

- 克隆后需要 `make ios-project` 才能用 Xcode 打开；README 已写明。
- CI 的 iOS job 先 `brew install xcodegen`，再生成工程、`xcodebuild` 编译。
- 解码、去重、游标、REST 请求构造等回归测试不依赖模拟器，提交反馈更快；SwiftUI 视图本身仍需 Xcode/模拟器或 CI 的构建验证。
- 若将来改为提交工程文件，只需移除生成步骤，`RoundtableCore` 的边界仍然成立。
