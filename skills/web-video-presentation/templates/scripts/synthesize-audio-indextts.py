#!/usr/bin/env python3
"""Synthesize audio-segments.json via local index-tts.

Invoked by synthesize-audio-indextts.sh after `uv run` provides the env.
Loads the IndexTTS model exactly once and walks every segment, writing
public/audio/<chapter>/<step>.mp3 (wav → mp3 through ffmpeg).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def pick_device(requested: str | None) -> str:
    if requested:
        return requested
    import torch
    if torch.cuda.is_available():
        return "cuda:0"
    mps = getattr(torch, "mps", None)
    if mps is not None and torch.mps.is_available():
        return "mps"
    return "cpu"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--segments",  required=True, help="audio-segments.json path")
    ap.add_argument("--out-dir",   required=True, help="public/audio root")
    ap.add_argument("--prompt",    required=True, help="reference voice (wav/mp3)")
    ap.add_argument("--model-dir", required=True, help="index-tts checkpoints/")
    ap.add_argument("--config",    required=True, help="index-tts checkpoints/config.yaml")
    ap.add_argument("--device",    default=None,  help="cpu|cuda|mps (auto if omitted)")
    ap.add_argument("--force", action="store_true", help="overwrite existing mp3s")
    args = ap.parse_args()

    segments = json.loads(Path(args.segments).read_text())
    out_root = Path(args.out_dir)
    out_root.mkdir(parents=True, exist_ok=True)

    planned: list[tuple[dict, Path, bool]] = []  # (seg, out_mp3, skip)
    for seg in segments:
        out_mp3 = out_root / seg["chapter"] / f'{seg["step"]}.mp3'
        skip = out_mp3.exists() and not args.force
        planned.append((seg, out_mp3, skip))

    needs_work = [x for x in planned if not x[2]]
    total = len(planned)
    if not needs_work:
        print(f"✓ all {total} segments already exist — use --force to redo")
        return

    device = pick_device(args.device)
    # fp16 is only reliably safe on CUDA; cpu can't use it, mps drivers vary.
    use_fp16 = device.startswith("cuda")

    print(f"→ device={device}  fp16={use_fp16}")
    print(f"→ prompt={args.prompt}")
    print(f"→ loading IndexTTS from {args.model_dir} …")
    t0 = time.time()
    from indextts.infer import IndexTTS  # noqa: WPS433 (deferred import after device probe)
    tts = IndexTTS(
        cfg_path=args.config,
        model_dir=args.model_dir,
        use_fp16=use_fp16,
        device=device,
    )
    print(f"✓ model loaded in {time.time() - t0:.1f}s")

    synthesized = skipped = failed = 0
    for i, (seg, out_mp3, skip) in enumerate(planned, 1):
        label = f'{seg["chapter"]}/{seg["step"]}.mp3'
        if skip:
            skipped += 1
            print(f"[{i:3d}/{total}] {label:<28} skip (exists)")
            continue

        text = (seg.get("text") or "").strip()
        if not text:
            failed += 1
            print(f"[{i:3d}/{total}] {label:<28} ✗ empty text", file=sys.stderr)
            continue

        out_mp3.parent.mkdir(parents=True, exist_ok=True)
        tmp_fd, tmp_wav = tempfile.mkstemp(suffix=".wav")
        os.close(tmp_fd)
        os.unlink(tmp_wav)  # IndexTTS refuses to overwrite an existing file
        start = time.time()
        try:
            tts.infer(audio_prompt=args.prompt, text=text, output_path=tmp_wav)
            subprocess.run(
                [
                    "ffmpeg", "-y", "-loglevel", "error",
                    "-i", tmp_wav,
                    "-codec:a", "libmp3lame",
                    "-qscale:a", "2",
                    str(out_mp3),
                ],
                check=True,
            )
            synthesized += 1
            print(f"[{i:3d}/{total}] {label:<28} ✓ {time.time() - start:.1f}s")
        except Exception as exc:  # noqa: BLE001 — surface any failure as a row
            failed += 1
            print(f"[{i:3d}/{total}] {label:<28} ✗ FAILED: {exc}", file=sys.stderr)
        finally:
            try:
                os.unlink(tmp_wav)
            except OSError:
                pass

    print()
    print(f"✓ done — synthesized {synthesized}, skipped {skipped}, failed {failed}")
    if failed:
        sys.exit(2)


if __name__ == "__main__":
    main()
