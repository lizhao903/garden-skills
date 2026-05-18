#!/usr/bin/env bash
# 停止由 ./start.sh 在当前目录启动的项目服务
# 用法：./stop.sh             停所有
#       ./stop.sh <slug> ...  只停指定
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$ROOT/.running"

if [ ! -d "$STATE_DIR" ]; then
  echo "（没有在运行的项目）"
  exit 0
fi

shopt -s nullglob
PID_FILES=("$STATE_DIR"/*.pid)
if [ ${#PID_FILES[@]} -eq 0 ]; then
  echo "（没有在运行的项目）"
  exit 0
fi

# 递归 kill 进程树（npm → vite → esbuild ...）
kill_tree() {
  local pid="$1" sig="$2"
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_tree "$child" "$sig"
  done
  kill "-$sig" "$pid" 2>/dev/null || true
}

stop_one() {
  local pid_file="$1"
  local slug
  slug="$(basename "$pid_file" .pid)"
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || echo)"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    echo "ℹ️  [${slug}] 已不在运行（清理状态文件）"
    rm -f "$pid_file"
    return
  fi
  kill_tree "$pid" TERM
  # 等最多 3s
  for i in 1 2 3 4 5 6; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "    SIGTERM 没结束，发 SIGKILL..."
    kill_tree "$pid" KILL
    sleep 0.3
  fi
  rm -f "$pid_file"
  echo "🛑 已停止 [${slug}]（PID ${pid}）"
}

if [ $# -eq 0 ]; then
  for pf in "${PID_FILES[@]}"; do
    stop_one "$pf"
  done
else
  for slug in "$@"; do
    pf="$STATE_DIR/$slug.pid"
    if [ -f "$pf" ]; then
      stop_one "$pf"
    else
      echo "⚠️  [${slug}] 未在运行（${STATE_DIR}/${slug}.pid 不存在）"
    fi
  done
fi
