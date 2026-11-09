# 双端 60 秒演示录制脚本

目标是 **60 秒 ±5 秒、1920×1080** 的双端并排视频：同一议题分别在 iOS 与 Android
上运行，展示同一套协议产生结构相同的讨论。两端是**两个独立的圆桌**，不是同一个房间；
字幕必须写「同一议题 · 两个独立圆桌 · 同一协议」，不得暗示两端实时同房。

## 为什么必须用真实 Provider

Android 的 Mock 演示目前只运行第一轮，且「参考了资料库的 N 个片段」只在真实 Provider
的 Turn 中出现。因此 Mock 拍不出第二轮引用和资料库引用；录制使用两端真实 Provider。
Mock 缺口见对应缺陷工单。

## 录制前准备

后端：

```bash
cp .env.example .env
docker compose up --build --detach --wait
curl http://127.0.0.1:8000/api/v1/health
```

iOS 模拟器：在 Xcode 的 Device Hub 中启动 iPhone 17，安装 `AgentRoundtable`。
Android 模拟器（`Medium_Phone`，arm64-v8a）：

```bash
adb reverse tcp:8000 tcp:8000
cd android && ./gradlew :app:assembleDebug -PbackendBaseUrl=http://127.0.0.1:8000
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

> 部分模拟器镜像访问不到 `10.0.2.2`，此时必须使用 `adb reverse` +
> `127.0.0.1`；`android/README.md` 的默认地址仍适用于可正常访问宿主机的镜像。

Provider（两端各配置一次，Key 不出现在录屏中）：

1. 打开 Provider 设置，填写 BaseURL、模型名与 API Key，点「验证连接」。
2. 若返回 404，按服务商文档核对模型 ID 与 BaseURL 的对应关系；聚合平台的模型名
   通常带前缀，不能直接填官方名称。
3. 发一条真实消息测首字延迟；若首个可见 token 超过 5 秒，改用非思考模型后再录。

资料库（仅 Android）：

1. 将 `docs/demo-knowledge.md` 推到设备可访问的位置。
2. 在资料库页通过系统文件选择器导入，确认文档块数量大于 0。
3. 回到圆桌，确认真实 Provider 的发言出现「参考了资料库的 N 个片段」。

演示议题统一为：

> 独立开发者该不该先做 iOS 再补 Android？

## 分镜（60 秒）

| 时间 | 画面 | 说明 |
| --- | --- | --- |
| 0–5s | 标题卡 | 「同一议题 · 两个独立圆桌 · 同一协议」 |
| 5–19s | 双栏 | 两端第一轮流式发言，展示不同立场 |
| 19–29s | 双栏 | 第二轮结构化互评：质疑 + 引用原观点 |
| 29–38s | Android 全屏 | 资料库与「参考了资料库的 2 个片段」，标注「Android 独有」 |
| 38–44s | 协议卡 | 同一份 `docs/protocol.md`，两个原生客户端各自实现 |
| 44–56s | 片尾卡 | 仓库地址、发布说明与「真实设备录屏 · 剪辑压缩」 |

剪辑说明：双栏使用 take4 的同步录制；Android 第二轮与资料库素材来自同一议题的
另一场 Android 圆桌（同一版本、同一协议、同一 Provider），用于补齐 take4 中未滚动到
的第二轮画面。片尾卡已注明「真实设备录屏 · 为时长做剪辑压缩」，不宣称两端逐帧同步。

## 录制

```bash
make docker-up
make record-dual-demo
make docker-down
```

脚本同时启动 iOS `simctl recordVideo` 与 Android `adb screenrecord`，打印分镜清单，
按回车停止后把原始素材拉到 `../artifacts/dual-demo-raw/`。录制时人工先后操作两端即可，
两端画面在剪辑阶段按分镜对齐；不要为了对齐而宣称实时同步。

## 剪辑

1. 每条素材按分镜裁切，资料库段切 Android 全屏，其余时间保持左右分栏。
2. 输出 1920×1080、H.264、约 2.5–3 Mbps，时长控制在 55–65 秒。
3. 中文字幕烧录在底部安全区；字体使用 PingFang SC 或 Noto Sans CJK。
4. 逐帧检查：无 API Key、无系统通知、无真实姓名/公司资料、无未授权的第三方内容。
5. 从成片抽一帧作为封面，存为 `docs/assets/demo-v0.2.0-dual-end-poster.png`。

可复现的合成命令（`scripts/demo/` 下的素材生成与拼接脚本）：

```bash
python3 scripts/demo/build_assets.py     # 标题卡、分栏背景、字幕、协议卡、片尾卡
python3 scripts/demo/build_poster.py     # 封面图
scripts/demo/make_video.sh               # 按分镜裁切、叠字、拼接、烧录字幕
```

脚本默认读取 `../artifacts/dual-demo-raw/take4/` 下的原始素材，输出 1920×1080、
30 fps、H.264 的无音轨成片；素材目录可用环境变量覆盖。

## 产物

- 成片上传为 GitHub Release `v0.2.0` 资产 `demo-v0.2.0-dual-end.mp4`，**不进入仓库历史**。
- 封面图放 `docs/assets/`，体积小，可以入库。
- 4 分 43 秒的 iOS 完整录屏继续作为补充材料，指向 `v0.1.0` Release 资产。

## 当前状态

Provider 闸门已通过：iOS 模拟器与 Android 模拟器各完成一次真实请求，使用应用真实
提示词测得首个可见 token 分别为 1.5 秒和 2.8 秒（本地网关，仅代表录制环境）。

成片已按本文分镜完成（56 秒、1920×1080、无音轨），并作为 `v0.2.0` Release 资产发布；
封面在 `docs/assets/demo-v0.2.0-dual-end-poster.png`。成片不进入仓库历史。
