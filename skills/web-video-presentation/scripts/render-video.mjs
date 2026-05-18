#!/usr/bin/env node
/**
 * 把一个项目的 auto-mode 演示渲染成 mp4：
 *   1) Playwright headed Chromium 1920×1080 起 ?auto=1
 *   2) 内置 recordVideo 录无声 webm
 *   3) 浏览器吐 __STEP_START / __AUTO_DONE 时间戳
 *   4) ffmpeg 用 -itsoffset 把每段 mp3 放到对应时间点
 *
 * 用法：node scripts/render-video.mjs <slug> [--port 5174]
 *
 * 前置：该项目的 dev server 已经在跑（./start.sh <slug>）
 *      该项目已合成音频（public/audio/<chapter>/<N>.mp3）
 */

import { chromium } from "playwright";
import { spawn } from "node:child_process";
import { mkdir, readdir, rm, writeFile, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const PROJECTS_DIR = path.join(ROOT, "projects");

// ---------- args ----------
const args = process.argv.slice(2);
const slug = args.find((a) => !a.startsWith("--"));
let port = 5174;
const portIdx = args.indexOf("--port");
if (portIdx >= 0) port = parseInt(args[portIdx + 1], 10);
const remuxOnly = args.includes("--remux");

if (!slug) {
  console.error(
    "用法: node scripts/render-video.mjs <slug> [--port 5174] [--remux]",
  );
  console.error("  --remux：跳过录制，只用上次的 raw.webm + timings.json 重 mux");
  process.exit(1);
}

// ---------- find project (兼容老布局 + 新分类布局) ----------
async function findProject(slug) {
  try {
    const direct = path.join(PROJECTS_DIR, slug, "presentation");
    await stat(direct);
    return path.join(PROJECTS_DIR, slug);
  } catch {}
  for (const cat of await readdir(PROJECTS_DIR, { withFileTypes: true })) {
    if (!cat.isDirectory()) continue;
    try {
      const nested = path.join(PROJECTS_DIR, cat.name, slug, "presentation");
      await stat(nested);
      return path.join(PROJECTS_DIR, cat.name, slug);
    } catch {}
  }
  throw new Error(`找不到项目 ${slug}`);
}

const projDir = await findProject(slug);
const presDir = path.join(projDir, "presentation");
const audioDir = path.join(presDir, "public", "audio");
const outDir = path.join(projDir, "video-out");
const rawDir = path.join(outDir, "raw");
if (!remuxOnly) {
  await rm(outDir, { recursive: true, force: true });
  await mkdir(rawDir, { recursive: true });
}

console.log(`项目: ${projDir}`);
console.log(`输出: ${outDir}`);

let timings = [];
let autoStartWall = null;
let autoDoneTime = null;
let finishWall = null;
let rawVideo = null;

if (remuxOnly) {
  // ---------- remux 模式：复用上次录像 + timings ----------
  const timingsPath = path.join(outDir, "timings.json");
  const saved = JSON.parse(await import("node:fs").then(m => m.promises.readFile(timingsPath, "utf-8")));
  timings = saved.timings;
  autoStartWall = saved.autoStartWall;
  autoDoneTime = saved.autoDoneTime;
  finishWall = saved.finishWall;
  const webms = (await readdir(rawDir)).filter((f) => f.endsWith(".webm"));
  if (webms.length === 0) throw new Error(`${rawDir} 没找到 webm`);
  rawVideo = path.join(rawDir, webms[0]);
  console.log(`复用录像: ${rawVideo}`);
  console.log(`复用 timings: ${timings.length} 个 step`);
} else {

// ---------- 健康检查：dev server 在不在 ----------
const url = `http://localhost:${port}/?auto=1`;
try {
  const res = await fetch(`http://localhost:${port}/`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
} catch (e) {
  console.error(
    `❌ 端口 ${port} 没有响应。请先 ./start.sh ${slug}（默认 5174 端口）。`,
  );
  console.error(`   detail: ${e.message}`);
  process.exit(1);
}

// ---------- 启动 Playwright ----------
// headless：后台跑，不弹窗
// --mute-audio：浏览器内所有 audio 输出静音（但 audio.ended 仍正常触发，
//   所以 auto 模式照常推进。最终 mp4 的音轨来自干净 mp3，不来自录制）
console.log("启 Chromium（headless + muted）...");
const browser = await chromium.launch({
  headless: true,
  args: [
    "--autoplay-policy=no-user-gesture-required",
    "--mute-audio",
  ],
});
const context = await browser.newContext({
  viewport: { width: 1920, height: 1080 },
  recordVideo: { dir: rawDir, size: { width: 1920, height: 1080 } },
});
const page = await context.newPage();

page.on("console", (msg) => {
  const text = msg.text();
  if (text.startsWith("__STEP_START ")) {
    const [, chapter, step, time] = text.split(" ");
    timings.push({
      chapter,
      step: parseInt(step, 10),
      time: parseFloat(time),
    });
    process.stdout.write(
      `  [${timings.length.toString().padStart(2)}] ${chapter}/${step} @ ${time}s\n`,
    );
  } else if (text.startsWith("__AUTO_DONE ")) {
    autoDoneTime = parseFloat(text.split(" ")[1]);
    console.log(`  __AUTO_DONE @ ${autoDoneTime}s`);
  } else if (text.startsWith("__AUTO_START")) {
    console.log("  __AUTO_START");
  }
});

// 把所有 page 错误打出来（mp3 加载失败 / decode 失败 等）
page.on("pageerror", (err) => console.error("  ⚠️ page error:", err.message));
page.on("requestfailed", (req) =>
  console.error("  ⚠️ request failed:", req.url(), req.failure()?.errorText),
);

console.log(`导航到 ${url}`);
const contextStart = Date.now();
await page.goto(url);
await page.waitForSelector(".auto-gate", { timeout: 10_000 });

// 用点击启动而不是 Space 键 —— useStepper 也监听 Space，按键会让 cursor 多走一步
console.log("点击 auto-gate 启动 auto...");
autoStartWall = (Date.now() - contextStart) / 1000;
await page.click(".auto-gate");

console.log("等播放完成（最长 30 分钟）...");
// 注意：waitForFunction 的第 2 个参数是 arg（不是 options），options 在第 3 个
await page.waitForFunction(
  () => window.__autoDone === true,
  undefined,
  { timeout: 30 * 60 * 1000, polling: 250 },
);

finishWall = (Date.now() - contextStart) / 1000;
console.log(`✓ 播放完成 ${finishWall.toFixed(2)}s（auto 内时长 ${autoDoneTime}s）`);
console.log(`  收集到 ${timings.length} 个 step 时间戳`);

await context.close();
await browser.close();

// ---------- 找 webm ----------
const webms = (await readdir(rawDir)).filter((f) => f.endsWith(".webm"));
if (webms.length === 0) throw new Error("没找到 Playwright 录的 webm");
rawVideo = path.join(rawDir, webms[0]);
console.log(`录到: ${rawVideo}`);

// 保存 timings.json
await writeFile(
  path.join(outDir, "timings.json"),
  JSON.stringify({ autoStartWall, autoDoneTime, finishWall, timings }, null, 2),
);

} // end if (!remuxOnly)

// ---------- ffmpeg mux ----------
// 录像 t=0 是 context 创建；SPACE 在 autoStartWall。先用 -ss 把录像裁掉前面这一段。
// 裁完后录像的 t=0 = SPACE 时刻 = 浏览器 timings 的 t=0，audio offset 直接用 timings.time。
const trimStart = Math.max(0, autoStartWall - 0.05); // 留 50ms 缓冲，避免裁太狠
const trimDuration = (autoDoneTime ?? finishWall - autoStartWall) + 0.5; // 尾巴 +500ms

// 关键：amix 不尊重 -itsoffset（会把所有输入塞到 t=0 混），所以用 adelay
// 在 filter 里显式头部加静音。每路 input 是 [k:a]，先 adelay 到对应时刻，
// 再喂给 amix。
const audioInputs = [];
const filterParts = [];
const audioLabels = [];
for (let i = 0; i < timings.length; i++) {
  const t = timings[i];
  const mp3 = path.join(audioDir, t.chapter, `${t.step + 1}.mp3`);
  try {
    await stat(mp3);
  } catch {
    console.warn(`⚠️  缺音频文件，跳过：${mp3}`);
    continue;
  }
  // 浏览器时间 t.time 是 step 开始相对 SPACE 的秒数；
  // 录像被 trim 了 trimStart，所以视频内的 t=0 = SPACE。直接用 t.time 当 delay。
  const delayMs = Math.max(0, Math.round(t.time * 1000));
  const inputIdx = audioInputs.length / 2 + 1; // input 0 是视频
  audioInputs.push("-i", mp3);
  filterParts.push(`[${inputIdx}:a]adelay=${delayMs}|${delayMs}[a${i}]`);
  audioLabels.push(`[a${i}]`);
}

if (audioLabels.length === 0) {
  console.error("❌ 一个音频文件都没找到");
  process.exit(1);
}

const filter =
  filterParts.join(";") +
  ";" +
  audioLabels.join("") +
  `amix=inputs=${audioLabels.length}:normalize=0:dropout_transition=0[aout]`;

const finalVideo = path.join(outDir, `${slug}.mp4`);
const ffArgs = [
  "-y",
  "-ss", trimStart.toFixed(3),
  "-t", trimDuration.toFixed(3),
  "-i", rawVideo,
  ...audioInputs,
  "-filter_complex", filter,
  "-map", "0:v",
  "-map", "[aout]",
  "-c:v", "libx264",
  "-pix_fmt", "yuv420p",
  "-preset", "fast",
  "-c:a", "aac",
  "-b:a", "192k",
  finalVideo,
];

console.log("\nffmpeg 合成中...");
console.log(`ffmpeg ${ffArgs.join(" ")}\n`);

await new Promise((resolve, reject) => {
  const ff = spawn("ffmpeg", ffArgs, { stdio: "inherit" });
  ff.on("exit", (code) =>
    code === 0 ? resolve() : reject(new Error(`ffmpeg 退出码 ${code}`)),
  );
});

console.log(`\n✅ 完成: ${finalVideo}`);
console.log(`   timings: ${path.join(outDir, "timings.json")}`);
