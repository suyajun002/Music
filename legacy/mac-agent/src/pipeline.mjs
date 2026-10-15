// 用途：编排「取流 → 转码 → 入库」一次任务，只更新任务的结构化状态；不碰 HTTP，也不包含抓取细节。
import { mkdir, rm } from "node:fs/promises";
import { join } from "node:path";

import { downloadVideo } from "./downloader.mjs";
import { transcodeToMp3 } from "./transcoder.mjs";

const DOWNLOAD_END = 0.28;
const TRANSCODE_START = 0.3;
const TRANSCODE_END = 0.92;

export function createRunner({ config, logger }) {
  return async function runPipeline(job, { update }) {
    const workDir = join(config.workDir, job.id);
    await mkdir(workDir, { recursive: true });

    update({ stage: "下载中", progress: 0.03 });
    const media = await downloadVideo({ url: job.url, workDir, config, update, logger });

    if (media.title) update({ title: media.title });
    update({ stage: "转码中", progress: TRANSCODE_START });

    const audioFile = join(config.libraryDir, `${safeName(media.title, job.id)}.mp3`);
    const audio = await transcodeToMp3({
      videoPath: media.videoPath,
      audioPath: audioFile,
      title: media.title,
      author: job.author,
      config,
      logger,
      onProgress: (ratio) =>
        update({ progress: TRANSCODE_START + ratio * (TRANSCODE_END - TRANSCODE_START) }),
    });

    if (!config.keepVideo) {
      await rm(workDir, { recursive: true, force: true }).catch((error) =>
        logger.warn("清理工作目录失败", { id: job.id, error: error.message }),
      );
    }

    update({
      state: "ready",
      stage: "可以听了",
      progress: 1,
      title: media.title,
      durationSec: audio.durationSec,
      sizeBytes: audio.sizeBytes,
      audioFile: audio.audioPath,
      error: null,
    });

    logger.info("任务完成", { id: job.id, sizeMB: (audio.sizeBytes / 1024 / 1024).toFixed(2) });
  };
}

/** 文件名只保留安全字符；作品标题可能很长或含表情，统一截断并用任务 ID 保证唯一。 */
export function safeName(title, id) {
  const cleaned = String(title || "")
    .replace(/[\\/:*?"<>|\r\n\t]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 60);
  return `${cleaned || "抖音音频"}__${id}`;
}
