#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# synthesize-audio-indextts.sh — local zero-shot TTS via index-tts.
#
# Counterpart to synthesize-audio.sh (mmx). Uses voice-sincere-adult.mp3
# at the web-video root as the voice prompt, so it matches the mmx default
# voice "Chinese (Mandarin)_Sincere_Adult" — both engines sound like the
# same speaker.
#
# Pipeline mirrors synthesize-audio.sh:
#   • runs extract-narrations first (writes audio-segments.json);
#     pass --no-extract to reuse the existing file
#   • reads audio-segments.json
#   • produces public/audio/<chapter>/<step>.mp3
#   • serial, idempotent (skip existing), --force to overwrite
#   • model loaded ONCE per run (delegates the loop to the python sibling)
#
# Prereq:
#   1. index-tts repo cloned with checkpoints, uv-managed env initialised:
#        cd /Volumes/project/github/index-tts && uv sync
#   2. ffmpeg in PATH (wav→mp3) and jq.
#
# Knobs (env):
#   INDEX_TTS_REPO    repo root          (default /Volumes/project/github/index-tts)
#   INDEX_TTS_PROMPT  override prompt    (default <web-video>/voice-sincere-adult.mp3)
#   INDEX_TTS_DEVICE  cpu|cuda|mps       (default auto)
#
# Usage:
#   bash scripts/synthesize-audio-indextts.sh              # extract + incremental
#   bash scripts/synthesize-audio-indextts.sh --force      # extract + overwrite all
#   bash scripts/synthesize-audio-indextts.sh --no-extract # reuse existing segments.json
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

# Resolve THIS script's real location (BSD readlink has no -f).
resolve_self() {
  local p="$1" link
  while [[ -L "$p" ]]; do
    link="$(readlink "$p")"
    [[ "$link" = /* ]] && p="$link" || p="$(dirname "$p")/$link"
  done
  cd "$(dirname "$p")" && pwd
}
SELF_DIR="$(resolve_self "${BASH_SOURCE[0]}")"

# Project root = $PWD when invoked under a presentation dir, else script-relative.
if [[ -f "$PWD/audio-segments.json" || -d "$PWD/src/chapters" ]]; then
  PROJECT_ROOT="$PWD"
else
  PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
SEGMENTS="$PROJECT_ROOT/audio-segments.json"
OUT_DIR="$PROJECT_ROOT/public/audio"

INDEX_TTS_REPO="${INDEX_TTS_REPO:-/Volumes/project/github/index-tts}"

# Resolve voice prompt: $INDEX_TTS_PROMPT > project root > web-video root > next-to-script.
# Covers both standalone (skill template) and monorepo (shared/presentation/) layouts.
resolve_prompt() {
  if [[ -n "${INDEX_TTS_PROMPT:-}" ]]; then echo "$INDEX_TTS_PROMPT"; return; fi
  local candidates=(
    "$PROJECT_ROOT/voice-sincere-adult.mp3"
    "$SELF_DIR/../../../voice-sincere-adult.mp3"   # monorepo: shared/presentation/scripts → up 3
    "$SELF_DIR/voice-sincere-adult.mp3"
  )
  for c in "${candidates[@]}"; do
    [[ -f "$c" ]] && { ( cd "$(dirname "$c")" && echo "$PWD/$(basename "$c")" ); return; }
  done
  echo ""  # not found
}
INDEX_TTS_PROMPT="$(resolve_prompt)"

FORCE=false
NO_EXTRACT=false
for arg in "$@"; do
  case "$arg" in
    --force)      FORCE=true ;;
    --no-extract) NO_EXTRACT=true ;;
    *) echo "✗ unknown arg: $arg" >&2; exit 1 ;;
  esac
done

# ── extract narrations (idempotent, fast) ────────────────────────────
if [[ "$NO_EXTRACT" != true ]]; then
  [[ -d "$PROJECT_ROOT/src/chapters" ]] || {
    echo "✗ $PROJECT_ROOT/src/chapters not found — run from a presentation dir, or pass --no-extract" >&2
    exit 1; }
  echo "→ extracting narrations …"
  ( cd "$PROJECT_ROOT" && npx --yes tsx scripts/extract-narrations.ts ) || {
    echo "✗ extract-narrations failed" >&2; exit 1; }
fi

# ── preflight ────────────────────────────────────────────────────────
[[ -f "$SEGMENTS" ]] || {
  echo "✗ $SEGMENTS not found. Run without --no-extract, or: npm run extract-narrations" >&2; exit 1; }
[[ -d "$INDEX_TTS_REPO" ]] || { echo "✗ INDEX_TTS_REPO not found: $INDEX_TTS_REPO (set INDEX_TTS_REPO=<path>)" >&2; exit 1; }
[[ -f "$INDEX_TTS_REPO/checkpoints/config.yaml" ]] || {
  echo "✗ checkpoints/config.yaml missing under $INDEX_TTS_REPO — clone & download weights first" >&2; exit 1; }
[[ -n "$INDEX_TTS_PROMPT" && -f "$INDEX_TTS_PROMPT" ]] || {
  echo "✗ voice prompt not found. Looked for voice-sincere-adult.mp3 in $PROJECT_ROOT/ and the script's parent dirs." >&2
  echo "  Drop a reference voice there, or set INDEX_TTS_PROMPT=<path/to/x.mp3>." >&2
  exit 1; }
command -v uv     >/dev/null || { echo "✗ uv not in PATH. brew install uv" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "✗ ffmpeg required (wav→mp3). brew install ffmpeg" >&2; exit 1; }
command -v jq     >/dev/null || { echo "✗ jq required to read audio-segments.json" >&2; exit 1; }

# ── delegate to python (loads IndexTTS model once for the whole batch) ──
PY="$SELF_DIR/synthesize-audio-indextts.py"
[[ -f "$PY" ]] || { echo "✗ python sibling missing: $PY" >&2; exit 1; }

ARGS=(
  "$PY"
  --segments  "$SEGMENTS"
  --out-dir   "$OUT_DIR"
  --prompt    "$INDEX_TTS_PROMPT"
  --model-dir "$INDEX_TTS_REPO/checkpoints"
  --config    "$INDEX_TTS_REPO/checkpoints/config.yaml"
)
[[ -n "${INDEX_TTS_DEVICE:-}" ]] && ARGS+=(--device "$INDEX_TTS_DEVICE")
[[ "$FORCE" == true ]] && ARGS+=(--force)

# uv reads pyproject.toml / uv.lock from the cwd, so run inside the repo.
cd "$INDEX_TTS_REPO"
exec uv run python "${ARGS[@]}"
