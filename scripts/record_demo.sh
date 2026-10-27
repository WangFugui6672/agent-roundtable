#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-$ROOT/docs/assets/demo-v0.1.0.mp4}"
SIMULATOR_ID="${SIMULATOR_ID:-$(python3 "$ROOT/scripts/select_simulator.py")}"
TEMP_OUTPUT="${OUTPUT%.mp4}.recording.mp4"
RECORDER_PID=""

cleanup() {
  if [[ -n "$RECORDER_PID" ]] && kill -0 "$RECORDER_PID" 2>/dev/null; then
    kill -INT "$RECORDER_PID" 2>/dev/null || true
    wait "$RECORDER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

curl --fail --silent http://127.0.0.1:8000/api/v1/health >/dev/null || {
  echo "Start the backend first: make docker-up" >&2
  exit 1
}

xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b

(
  cd "$ROOT/ios"
  xcodegen generate
  xcodebuild \
    -project AgentRoundtable.xcodeproj \
    -scheme AgentRoundtable \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -only-testing:AgentRoundtableUITests/ReleaseDemoUITests/testReleaseDemoFlow \
    -collect-test-diagnostics never \
    build-for-testing
)

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$TEMP_OUTPUT"
xcrun simctl io "$SIMULATOR_ID" recordVideo --codec=h264 --force "$TEMP_OUTPUT" &
RECORDER_PID=$!
sleep 2

set +e
(
  cd "$ROOT/ios"
  xcodebuild \
    -project AgentRoundtable.xcodeproj \
    -scheme AgentRoundtable \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -only-testing:AgentRoundtableUITests/ReleaseDemoUITests/testReleaseDemoFlow \
    -collect-test-diagnostics never \
    test-without-building
)
TEST_STATUS=$?
set -e

sleep 1
cleanup
RECORDER_PID=""

if [[ $TEST_STATUS -ne 0 ]]; then
  echo "UI recording flow failed with status $TEST_STATUS" >&2
  exit "$TEST_STATUS"
fi

mv "$TEMP_OUTPUT" "$OUTPUT"
if [[ ! -s "$OUTPUT" ]]; then
  echo "Recording is empty: $OUTPUT" >&2
  exit 1
fi
if command -v ffprobe >/dev/null 2>&1; then
  ffprobe -v error -select_streams v:0 \
    -show_entries format=duration,size -of default=noprint_wrappers=1 "$OUTPUT"
fi
echo "Recorded $OUTPUT"
