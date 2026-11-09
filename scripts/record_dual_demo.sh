#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${OUT_DIR:-$ROOT/../artifacts/dual-demo-raw}/$(date +%Y%m%d-%H%M%S)"
SIMULATOR_ID="${SIMULATOR_ID:-$(python3 "$ROOT/scripts/select_simulator.py")}"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
MAX_SECONDS="${MAX_SECONDS:-180}"
IOS_PID=""
ANDROID_PID=""

cleanup() {
  if [[ -n "$IOS_PID" ]] && kill -0 "$IOS_PID" 2>/dev/null; then
    kill -INT "$IOS_PID" 2>/dev/null || true
    wait "$IOS_PID" 2>/dev/null || true
  fi
  if [[ -n "$ANDROID_PID" ]]; then
    "$ADB" shell pkill -INT screenrecord >/dev/null 2>&1 || true
    wait "$ANDROID_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

curl --fail --silent http://127.0.0.1:8000/api/v1/health >/dev/null || {
  echo "Start the backend first: make docker-up" >&2
  exit 1
}

if ! "$ADB" devices | awk 'NR>1 && $2=="device" {found=1} END {exit !found}'; then
  echo "No Android device or emulator attached. Start Medium_Phone first." >&2
  exit 1
fi

xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
"$ADB" reverse tcp:8000 tcp:8000 >/dev/null

mkdir -p "$RUN_DIR"
cat <<'CHECKLIST'
分镜（60 秒）：
  0–3s   标题卡：同一议题 · 两个独立圆桌 · 同一协议
  3–13s  双栏：两端第一轮流式发言
  13–25s 双栏：第二轮引用式互评（Android 放大）
  25–37s 双栏：Android 暂停 / 点名 / 继续
  37–47s Android 全屏：资料库与「参考了资料库的 N 个片段」
  47–55s 双栏：两端结论四分区
  55–60s 片尾卡：仓库地址

录制时先操作 iOS，再操作 Android；两端画面在剪辑阶段对齐。
CHECKLIST

read -r -p "按 Enter 开始同时录屏..." _
xcrun simctl io "$SIMULATOR_ID" recordVideo --codec=h264 --force \
  "$RUN_DIR/ios-raw.mp4" >"$RUN_DIR/ios-record.log" 2>&1 &
IOS_PID=$!
"$ADB" shell screenrecord --time-limit "$MAX_SECONDS" --bit-rate 8000000 \
  /sdcard/android-raw.mp4 >"$RUN_DIR/android-record.log" 2>&1 &
ANDROID_PID=$!
echo "录制中（最长 ${MAX_SECONDS}s）..."
read -r -p "按 Enter 停止..." _

kill -INT "$IOS_PID" 2>/dev/null || true
wait "$IOS_PID" 2>/dev/null || true
IOS_PID=""
"$ADB" shell pkill -INT screenrecord >/dev/null 2>&1 || true
wait "$ANDROID_PID" 2>/dev/null || true
ANDROID_PID=""
sleep 1
"$ADB" pull /sdcard/android-raw.mp4 "$RUN_DIR/android-raw.mp4" >/dev/null
"$ADB" shell rm -f /sdcard/android-raw.mp4

for f in "$RUN_DIR/ios-raw.mp4" "$RUN_DIR/android-raw.mp4"; do
  if [[ ! -s "$f" ]]; then
    echo "Recording is empty: $f" >&2
    exit 1
  fi
  if command -v ffprobe >/dev/null 2>&1; then
    ffprobe -v error -select_streams v:0 \
      -show_entries format=duration,size -of default=noprint_wrappers=1 "$f"
  fi
done
echo "Raw recordings: $RUN_DIR"
