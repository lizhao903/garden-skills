# Workspace helpers

These scripts live at the **parent** of your `projects/` directory ——
they manage multiple skill-scaffolded projects at once. They are NOT
copied into individual projects.

## Layout assumed

```
my-video-workspace/
├── start.sh                # ← from here
├── stop.sh                 # ← from here
├── render-video.sh         # ← from here
├── scripts/
│   ├── render-video.mjs    # copy from skill's scripts/
│   └── package.json        # copy from skill's scripts/
└── projects/
    ├── video-a/
    │   └── presentation/   # scaffolded by scaffold.sh
    ├── video-b/
    │   └── presentation/
    └── ...                 # supports nested categories too, e.g. projects/cv/cnn/
```

## Install

```bash
cd /path/to/your/workspace
mkdir -p scripts

# 1) copy the bash helpers
cp <SKILL>/workspace/start.sh         ./
cp <SKILL>/workspace/stop.sh          ./
cp <SKILL>/workspace/render-video.sh  ./
chmod +x *.sh

# 2) copy the Node-side render script + install Playwright
cp <SKILL>/scripts/render-video.mjs  scripts/
cp <SKILL>/scripts/package.json      scripts/
cd scripts && npm install && npx playwright install chromium
```

## Use

```bash
./start.sh <slug>                # start a project's Vite dev server (background)
./render-video.sh <slug>         # record auto-mode → mp4 (needs synthesized audio)
./render-video.sh <slug> --remux # re-mux from previous recording, fast iterate
./stop.sh                        # stop all dev servers (or stop.sh <slug>)
```

The slug can be a project directory name; both flat (`projects/<slug>/`)
and nested (`projects/<category>/<slug>/`) layouts work.

## Why these are workspace-level, not skill-level

The skill scaffolds **one project** at a time. These scripts manage a
**collection** of projects — they belong to your workspace, not the
skill. They're included here as a starter so you can drop them in and
get multi-project orchestration + automated rendering for free.
