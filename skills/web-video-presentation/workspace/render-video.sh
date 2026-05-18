#!/usr/bin/env bash
# 把一个项目的 auto-mode 演示录制成 mp4：
#   1) Playwright headless + muted Chromium → 1920×1080 webm
#   2) 浏览器吐 step 时间戳
#   3) ffmpeg adelay+amix 把每段 mp3 对到时间点
#
# 用法：
#   ./render-video.sh <slug>                启动 dev → 录制 → mux
#   ./render-video.sh <slug> --remux        只用上次录像重新 mux
#   ./render-video.sh <slug> --port 5174    指定端口
#
# 前置：
#   - 该项目已合成音频（public/audio/<chapter>/<N>.mp3）
#   - 用 ./start.sh <slug> 先把 dev server 起好（或它已经在跑）

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# 默认端口（跟 start.sh 一致）
PORT=5174
SLUG=""
EXTRA_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      PORT="$2"
      EXTRA_ARGS+=("--port" "$2")
      shift 2
      ;;
    --remux)
      EXTRA_ARGS+=("--remux")
      shift
      ;;
    *)
      if [ -z "${SLUG}" ]; then
        SLUG="$1"
      else
        EXTRA_ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

if [ -z "${SLUG}" ]; then
  echo "用法: $0 <项目 slug> [--port 5174] [--remux]"
  exit 1
fi

# 健康检查：dev server 在不在
if ! curl -sf "http://localhost:${PORT}/" > /dev/null 2>&1; then
  echo "⚠️  端口 ${PORT} 没响应。"
  echo "    先跑：./start.sh ${SLUG}"
  exit 1
fi

exec node "${ROOT}/scripts/render-video.mjs" "${SLUG}" "${EXTRA_ARGS[@]}"
