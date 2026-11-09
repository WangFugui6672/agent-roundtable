# 双端演示剪辑管线

把 `scripts/record_dual_demo.sh` 录到的原始素材剪成 60 秒双端并排视频与封面。

## 依赖

- `ffmpeg` / `ffprobe`（需 libx264；不需要 drawtext，字幕以 PNG 叠加）
- Python 3 + Pillow
- macOS 系统字体：`STHeiti Medium.ttc`、`Hiragino Sans GB.ttc`
  （字体路径在 `build_assets.py` 顶部，可改）

## 素材

默认从 `../artifacts/dual-demo-raw/take4/` 读取，可用 `DEMO_RAW_DIR` 覆盖：

| 文件 | 内容 |
| --- | --- |
| `ios-raw.mp4` | iOS 同步录制（含第一轮、第二轮、结论整理） |
| `android-raw.mp4` | Android 同步录制（第一轮） |
| `android-round2.mp4` | 同议题 Android 圆桌的第二轮滚动画面 |
| `android-library.mp4` | 资料库页与带引用标记的发言 |

Android 的 `adb screenrecord` 输出为 720×1280 且左右有黑边（内容实际 460×1280），
脚本会先裁到 460×1280，再按手机真实比例放进分栏。

## 用法

```bash
python3 scripts/demo/build_assets.py     # 卡片、分栏背景、圆角遮罩、字幕
python3 scripts/demo/build_poster.py     # 封面
scripts/demo/make_video.sh               # 成片
```

输出目录默认 `../artifacts/dual-demo-edit/`（`DEMO_WORK_DIR` 可覆盖）：

- `demo-v0.2.0-dual-end.mp4`：1920×1080、30 fps、无音轨、约 56 秒
- `demo-v0.2.0-dual-end-poster.png`：封面

## 分镜

| 时间 | 内容 |
| --- | --- |
| 0–5s | 标题卡 |
| 5–19s | 双栏：第一轮流式发言 |
| 19–29s | 双栏：第二轮结构化互评与引用 |
| 29–38s | Android 全屏：端侧资料库与引用标记（标注「Android 独有」） |
| 38–44s | 协议卡：同一份 `docs/protocol.md` |
| 44–56s | 片尾卡：仓库地址、发布说明与剪辑口径 |

成片不宣称两端逐帧同步；片尾卡注明「真实设备录屏 · 为时长做剪辑压缩」。
