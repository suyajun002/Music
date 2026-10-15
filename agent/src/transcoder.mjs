// 用途：把下载到的 MP4 转成 MP3（libmp3lame），写 ID3 标题、可选封面，并回报真实转码进度。
import { spawn } from "node:child_process";
import { stat, unlink } from "node:fs/promises";

export class TranscodeError extends Error {}

/** 读取媒体时长（秒）；失败返回 null，进度退化为不确定态。 */
export async function probeDurationSec(mediaPath, config) {
  try {
    const output = await runCapture(config.ffprobeBin, [
      "-v",
      "error",
      "-show_entries",
      "format=duration",
      "-of",
      "default=nw=1:nk=1",
      mediaPath,
    ]);
    const seconds = Number.parseFloat(output.trim());
    return Number.isFinite(seconds) && seconds > 0 ? seconds : null;
  } catch {
    return null;
  }
}

/**
 * 转码为 MP3。
 * progress 区间由调用方给定，这里只回报 0..1 的本地进度，不关心任务状态。
 */
export async function transcodeToMp3({
  videoPath,
  audioPath,
  title,
  author,
  config,
  onProgress,
  logger,
}) {
  const durationSec = await probeDurationSec(videoPath, config);
  const coverPath = config.embedCover ? await extractCover(videoPath, audioPath, config, logger) : null;

  const args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", videoPath];
  if (coverPath) args.push("-i", coverPath);
  args.push("-map", "0:a");
  if (coverPath) {
    args.push("-map", "1:v", "-c:v", "mjpeg", "-disposition:v", "attached_pic");
  }
  args.push(
    "-c:a",
    "libmp3lame",
    "-q:a",
    config.mp3Quality,
    "-id3v2_version",
    "3",
    "-metadata",
    `title=${title || "抖音音频"}`,
  );
  if (author) args.push("-metadata", `artist=${author}`);
  args.push("-progress", "pipe:1", "-nostats", audioPath);

  await new Promise((resolve, reject) => {
    const child = spawn(config.ffmpegBin, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stderr = "";
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, config.transcodeTimeoutMs);

    child.stdout.on("data", (chunk) => {
      if (!durationSec || !onProgress) return;
      for (const line of chunk.toString().split("\n")) {
        const match = /^out_time_us=(\d+)$/.exec(line.trim());
        if (!match) continue;
        const ratio = Number(match[1]) / 1_000_000 / durationSec;
        onProgress(Math.max(0, Math.min(1, ratio)));
      }
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(new TranscodeError(`无法启动 ffmpeg：${error.message}`));
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (timedOut) return reject(new TranscodeError("转码超时"));
      if (code !== 0) {
        const detail = stderr.trim().split("\n").filter(Boolean).pop() || `ffmpeg 退出码 ${code}`;
        return reject(new TranscodeError(detail));
      }
      return resolve();
    });
  });

  if (coverPath) {
    await unlink(coverPath).catch(() => {});
  }

  let sizeBytes = null;
  try {
    sizeBytes = (await stat(audioPath)).size;
  } catch {
    throw new TranscodeError("转码完成但找不到输出文件");
  }

  return { audioPath, durationSec, sizeBytes };
}

async function extractCover(videoPath, audioPath, config, logger) {
  const coverPath = `${audioPath}.cover.jpg`;
  try {
    await runCapture(config.ffmpegBin, [
      "-hide_banner",
      "-loglevel",
      "error",
      "-nostdin",
      "-y",
      "-ss",
      "1",
      "-i",
      videoPath,
      "-frames:v",
      "1",
      "-vf",
      "scale=600:-2",
      coverPath,
    ]);
    await stat(coverPath);
    return coverPath;
  } catch (error) {
    await logger?.debug("封面提取失败，跳过", { error: error.message });
    return null;
  }
}

function runCapture(bin, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve(stdout);
      else reject(new Error(stderr.trim() || `${bin} 退出码 ${code}`));
    });
  });
}
