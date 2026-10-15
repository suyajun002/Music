// 用途：调用 douyin-skill 的下载脚本取回无水印视频。取流逻辑只在 skill 脚本里维护一份，这里不复制。
import { spawn } from "node:child_process";
import { stat } from "node:fs/promises";

const FILE_LINE = /^\s*文件：(.*)$/;
const TITLE_LINE = /^\s*标题：(.*)$/;
const STAGE_HINTS = [
  { match: "[1/4]", stage: "解析链接", progress: 0.04 },
  { match: "[2/4]", stage: "获取访问凭证", progress: 0.08 },
  { match: "[3/4]", stage: "解析作品信息", progress: 0.12 },
  { match: "[4/4]", stage: "下载视频", progress: 0.2 },
];

export class DownloadError extends Error {}

/**
 * 取回无水印视频，返回 { videoPath, title }。
 * 依赖 douyin-skill CLI 的稳定输出契约：`文件：<path>`、`标题：<desc>`。
 */
export async function downloadVideo({ url, workDir, config, update, logger }) {
  await logger?.debug("调用 douyin-skill 下载", { url });

  const child = spawn(config.nodeBin, [config.douyinCli, url, workDir], {
    stdio: ["ignore", "pipe", "pipe"],
  });

  let stdout = "";
  let stderr = "";
  let timedOut = false;

  const timer = setTimeout(() => {
    timedOut = true;
    child.kill("SIGKILL");
  }, config.downloadTimeoutMs);

  child.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
    const text = chunk.toString();
    for (const line of text.split("\n")) {
      for (const hint of STAGE_HINTS) {
        if (line.includes(hint.match)) update({ stage: hint.stage, progress: hint.progress });
      }
    }
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });

  const exitCode = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", resolve);
  }).finally(() => clearTimeout(timer));

  if (timedOut) {
    throw new DownloadError(`下载超时（${Math.round(config.downloadTimeoutMs / 1000)} 秒）`);
  }

  if (stdout.includes("类型：图文作品")) {
    throw new DownloadError("这是图文作品，没有音频可提取");
  }

  if (exitCode !== 0) {
    const detail = (stderr.trim() || stdout.trim()).split("\n").filter(Boolean).pop() || "未知错误";
    throw new DownloadError(detail.replace(/^❌\s*/, ""));
  }

  const videoPath = matchLine(stdout, FILE_LINE);
  if (!videoPath) throw new DownloadError("下载脚本没有返回视频文件路径");

  const title = matchLine(stdout, TITLE_LINE);
  let sizeBytes = null;
  try {
    sizeBytes = (await stat(videoPath)).size;
  } catch {
    throw new DownloadError("下载的视频文件不存在");
  }

  return { videoPath, title: title || null, sizeBytes };
}

function matchLine(text, pattern) {
  for (const line of text.split("\n")) {
    const match = pattern.exec(line);
    if (match) return match[1].trim();
  }
  return null;
}
