#!/usr/bin/env bash
# 启动指定项目的 Vite dev server（后台运行）
# 用法：./start.sh <项目 slug 或路径>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECTS_DIR="$ROOT/projects"
STATE_DIR="$ROOT/.running"
mkdir -p "$STATE_DIR"

usage() {
  echo "用法: $0 <项目 slug 或路径>"
  echo "示例: $0 batch-normalization"
  echo "      $0 projects/foundations/batch-normalization"
  echo
  echo "可用项目（projects/ 下含 presentation/ 的）："
  find "$PROJECTS_DIR" -mindepth 2 -maxdepth 4 -type d -name presentation 2>/dev/null \
    | sed -E "s#^${PROJECTS_DIR}/##; s#/presentation\$##" \
    | sort \
    | sed 's/^/  /'
  exit 1
}

[ $# -eq 1 ] || usage

ARG="$1"
PROJ_DIR=""
if [ -d "$ARG/presentation" ]; then
  PROJ_DIR="$(cd "$ARG" && pwd)"
elif [ -d "$PROJECTS_DIR/$ARG/presentation" ]; then
  # 老布局或用户传了 "<category>/<slug>" 这种相对路径
  PROJ_DIR="$PROJECTS_DIR/$ARG"
else
  # 新布局：递归找 slug
  FOUND=$(find "$PROJECTS_DIR" -mindepth 1 -maxdepth 3 -type d -name "$ARG" 2>/dev/null | head -1)
  if [ -n "$FOUND" ] && [ -d "$FOUND/presentation" ]; then
    PROJ_DIR="$FOUND"
  fi
fi

if [ -z "$PROJ_DIR" ]; then
  echo "❌ 找不到 presentation/ 目录：$ARG"
  echo
  usage
fi

SLUG="$(basename "$PROJ_DIR")"
PRES="$PROJ_DIR/presentation"
PID_FILE="$STATE_DIR/$SLUG.pid"
LOG_FILE="$STATE_DIR/$SLUG.log"

# 已在跑？
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "⚠️  [${SLUG}] 已在运行（PID ${OLD_PID}）"
    URL=$(grep -oE 'http://localhost:[0-9]+/' "$LOG_FILE" 2>/dev/null | head -1 || true)
    [ -n "$URL" ] && echo "    URL: $URL"
    echo "    日志: $LOG_FILE"
    exit 0
  else
    rm -f "$PID_FILE"
  fi
fi

# 装依赖（首次）
if [ ! -d "$PRES/node_modules" ]; then
  echo "📦 首次启动，安装依赖..."
  (cd "$PRES" && npm install)
fi

# 后台跑 vite
echo "🚀 启动 [${SLUG}]..."
: > "$LOG_FILE"
(
  cd "$PRES"
  nohup npm run dev >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
)

# 等 Vite 把 URL 打出来（最多 ~6s）
PID=$(cat "$PID_FILE")
URL=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "❌ 启动失败，最近日志："
    tail -30 "$LOG_FILE"
    rm -f "$PID_FILE"
    exit 1
  fi
  URL=$(grep -oE 'http://localhost:[0-9]+/' "$LOG_FILE" | head -1 || true)
  [ -n "$URL" ] && break
  sleep 0.5
done

echo "✅ [${SLUG}] 已启动"
echo "    PID:  $PID"
echo "    日志: $LOG_FILE"
[ -n "$URL" ] && echo "    URL:  $URL"
echo
echo "停止：./stop.sh ${SLUG}     # 或 ./stop.sh 停所有"
