# 录制与后期合成

三条路径，按从全自动到全手动排：

| 路径 | 何时用 | 输出 |
|---|---|---|
| **A · 程序化渲染**（`scripts/render-video.mjs`） | 已合成音频；想要无人工 mp4 | 直接 mp4 |
| **B · Auto 模式一镜到底屏幕录制** | 已合成音频；想要一次手动操作搞定 | 录屏软件的产物 |
| **C · 手动点击 + 后期配音** | 没合成音频 | 录屏 + 剪辑 |

---

## 路径 A · 程序化渲染（推荐）

`scripts/render-video.mjs` 用 Playwright headless + ffmpeg 把 auto 模式
**无声**地跑完一遍，然后把每段 mp3 按 step 切换时间点对齐到录像上。
不依赖系统屏幕录制、不需要 BlackHole/Loopback，不会被通知/光标污染。

### 前置

- 章节代码做完，每章都有 `narrations.ts`
- 跑过 `npm run extract-narrations` + `npm run synthesize-audio`，
  `public/audio/<id>/<step>.mp3` 全部就位
- 安装好 Playwright + Chromium：

```bash
cd <skill>/scripts    # 或者你 workspace 里复制的那份
npm install
npx playwright install chromium
```

### 运行

```bash
# 1) 起 dev server（任何方式都行，端口默认 5174）
npm run dev   # 在 presentation/ 目录里

# 2) 在 presentation 父目录跑：
node <skill>/scripts/render-video.mjs <project-dir-or-slug>

# 输出：<project>/video-out/<slug>.mp4 + timings.json
```

或者用 workspace 包装（见 `workspace/README.md`）：

```bash
./start.sh <slug>
./render-video.sh <slug>            # 录制 + mux
./render-video.sh <slug> --remux    # 只重 mux（调 ffmpeg 参数用）
./stop.sh
```

### 工作原理

```
Playwright headless Chromium 1920×1080
  + --mute-audio（防止任何系统声音）
  + recordVideo 1920×1080 → webm
  ↓
浏览器在 auto 模式播：触发 audio.ended 推进，但听不到声音
浏览器吐 console marks：__STEP_START / __AUTO_DONE + window.__autoDone
  ↓
Playwright 抓 console，记录每段 mp3 该出现的时刻
context.close 落 webm
  ↓
ffmpeg 合成：
  -i raw.webm                                  # 录像
  -i 1.mp3 -i 2.mp3 ... -i N.mp3               # 每段音频
  -filter_complex
    "[1:a]adelay=0|0[a1];                      # 用 adelay 显式延迟到时间点
     [2:a]adelay=4320|4320[a2]; ...
     [a1][a2]...amix=inputs=N:normalize=0[aout]"
  -c:v libx264 -c:a aac out.mp4
```

> **关键坑**：用 `-itsoffset` 给输入加偏移，amix 滤镜**不会**尊重它。
> 必须用 `[i:a]adelay=<ms>|<ms>` 在 filter 里显式延迟，再喂给 amix。
>
> **另一坑**：用 `page.keyboard.press(" ")` 启动 auto 会被 `useStepper`
> 的 Space 推进键吃掉，cursor 直接跳到 step 1。改用 `page.click(".auto-gate")`。

### 调试

- `<project>/video-out/timings.json` 记录每个 step 的实测开始时间，
  漂移异常时回看这个
- 录像中间产物 `<project>/video-out/raw/*.webm` 保留，便于 `--remux`
- 一段 mp3 缺失会被警告且跳过，最终视频该处静音

---

## 路径 B · Auto 模式一镜到底（屏幕录制）

适合你想亲眼看一遍效果再录的场景。

### 前置

- 章节代码做完，每章都有 `narrations.ts`
- 已经跑过 `npm run extract-narrations` + `npm run synthesize-audio`，
  `public/audio/<id>/<step>.mp3` 全部就位
- `npm run dev` 跑着，浏览器能打开页面

### 录制步骤

1. **浏览器全屏**（F11 / Ctrl+Cmd+F），URL 改成
   `http://localhost:5173/?auto=1`
2. 看到 "Press SPACE to start" 蒙层 = Auto 模式就绪
3. **打开屏幕录制**（QuickTime / OBS / Cmd+Shift+5），开始录
4. **按一次 Space** → 蒙层消失 → step 0 出现，1.mp3 自动播 →
   播完自动推进到 step 1 → 2.mp3 → … → 最后一个 step 播完 → 停在终态
5. **停止录制** → 后期裁掉头尾（Space 那一下、最后停在终态的尾巴）就是
   成品

整个过程**完全不用点鼠标**。音视频天然同步，不需要后期对轨。

> **Auto 模式严格按音频结束推进**（+ 200ms 缓冲），没有"等动画跑完"
> 的兜底。如果你看到某步动画被切了一半 → 说明该 step 动画长于口播，
> 回章节代码改：写更长口播 / 拆 step / 调动画速度。

### 录屏工具

| 平台 | 工具 | 设置 |
|---|---|---|
| macOS | Cmd+Shift+5 → 录制选定窗口 | 选浏览器窗口；浏览器全屏后输出就是 1920×1080 |
| macOS | QuickTime → 文件 → 新建屏幕录制 | 同上 |
| 跨平台 | OBS Studio | 窗口捕获，Canvas 1920×1080，60fps |

### 模式速查

| URL / 快捷键 | 行为 |
|---|---|
| 直接打开（默认） | Manual：点击 / ←→ 推进，不播音频 |
| `?audio=1` 或按 `M` | Audio：进入 step 自动播音频，但**手动点鼠标推进** |
| `?audio=1` + 再按 `M` | Auto：进入 step 自动播 + 自动推进（录制用） |
| Auto 模式下首次按 `Space` | 启动 Auto 播放（绕过浏览器自动播放限制） |

也可以鼠标移到右上角，会出现一个隐藏的模式切换按钮。

---

## 路径 C · 没合成音频时手动录屏

如果你跳过了音频合成（`Checkpoint Audio` 选了"不合成"），按老方法：

1. 浏览器全屏 → 打开 `localhost:5173`（默认 Manual 模式）
2. **刷新一次**清空历史 step
3. 开始录屏 → 按口播节奏点击空白推进 step
4. 后期用任何剪辑软件配音 + 调时间线

### 后期工具

| 工具 | 适合 |
|---|---|
| **DaVinci Resolve** | 跨平台免费、能处理多段音频拼接 |
| **iMovie** | macOS 简单场景 |
| **CapCut / 剪映** | B 站 / 抖音风加字幕 |

---

> agent 在 Checkpoint Audio 后**主动告诉用户**上面 Auto 模式录屏的
> 路径，让用户知道下一步怎么把网页变成 mp4。
