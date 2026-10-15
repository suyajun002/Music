// 用途：任务状态机 + 并发队列 + 幂等 + 持久化。只管状态流转，不关心下载/转码怎么实现（由 runner 注入）。
import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

export const JOB_STATE = Object.freeze({
  queued: "queued",
  running: "running",
  ready: "ready",
  failed: "failed",
});

const ACTIVE_STATES = new Set([JOB_STATE.queued, JOB_STATE.running]);

const ALLOWED_HOSTS = new Set([
  "v.douyin.com",
  "www.douyin.com",
  "douyin.com",
  "www.iesdouyin.com",
  "iesdouyin.com",
]);

/** 从分享文本里抠出抖音链接；非抖音来源直接拒绝，避免把 agent 当通用下载器。 */
export function extractDouyinUrl(text, maxLength = 2000) {
  const raw = String(text || "").trim();
  if (!raw) throw new Error("请粘贴抖音分享文本或链接");
  if (raw.length > maxLength) throw new Error("输入内容过长");

  const match = /https?:\/\/[^\s"'<>（）()]+/i.exec(raw);
  if (!match) throw new Error("没找到链接：请粘贴包含 https://v.douyin.com/... 的分享文本");

  const url = match[0];
  let host;
  try {
    host = new URL(url).hostname.toLowerCase();
  } catch {
    throw new Error("链接格式不正确");
  }
  if (!ALLOWED_HOSTS.has(host)) {
    throw new Error(`不支持的链接来源：${host}（只支持抖音链接）`);
  }
  return url;
}

export class JobStore {
  constructor({ runner, maxConcurrent = 1, persistencePath = null, historyLimit = 200, logger }) {
    this.runner = runner;
    this.maxConcurrent = Math.max(1, maxConcurrent);
    this.persistencePath = persistencePath;
    this.historyLimit = historyLimit;
    this.logger = logger;
    this.jobs = new Map();
    this.running = 0;
    this.saveTimer = null;
  }

  async load() {
    if (!this.persistencePath) return;
    try {
      const parsed = JSON.parse(await readFile(this.persistencePath, "utf8"));
      for (const job of parsed.jobs || []) {
        // 重启后未完成的任务一律标记失败，避免出现永远排队不动的僵尸任务
        if (ACTIVE_STATES.has(job.state)) {
          job.state = JOB_STATE.failed;
          job.stage = "中断";
          job.error = "agent 重启，任务已中断，请重新提交";
        }
        this.jobs.set(job.id, job);
      }
    } catch {
      // 首次启动没有历史文件
    }
  }

  async persist() {
    if (!this.persistencePath) return;
    const ordered = this.list();
    const payload = JSON.stringify({ version: 1, jobs: ordered }, null, 2);
    const tmp = `${this.persistencePath}.tmp`;
    await mkdir(dirname(this.persistencePath), { recursive: true });
    await writeFile(tmp, payload);
    await rename(tmp, this.persistencePath);
  }

  schedulePersist() {
    if (this.saveTimer) return;
    this.saveTimer = setTimeout(() => {
      this.saveTimer = null;
      this.persist().catch((error) => this.logger?.warn("持久化失败", { error: error.message }));
    }, 300);
  }

  list() {
    return [...this.jobs.values()].sort((a, b) => b.createdAt - a.createdAt);
  }

  get(id) {
    return this.jobs.get(id) || null;
  }

  /** 同一链接已有排队/进行中的任务时复用，避免重复下载。 */
  submit({ url }) {
    for (const job of this.jobs.values()) {
      if (job.url === url && ACTIVE_STATES.has(job.state)) {
        return { job, reused: true };
      }
    }

    const now = Date.now();
    const job = {
      id: randomUUID().replace(/-/g, "").slice(0, 12),
      url,
      state: JOB_STATE.queued,
      stage: "排队中",
      progress: 0,
      title: null,
      author: null,
      durationSec: null,
      sizeBytes: null,
      audioFile: null,
      coverFile: null,
      error: null,
      createdAt: now,
      updatedAt: now,
    };
    this.jobs.set(job.id, job);
    this.#trim();
    this.schedulePersist();
    this.#drain();
    return { job, reused: false };
  }

  update(id, patch) {
    const job = this.jobs.get(id);
    if (!job) return null;
    Object.assign(job, patch, { updatedAt: Date.now() });
    this.schedulePersist();
    return job;
  }

  remove(id) {
    const job = this.jobs.get(id);
    if (!job) return false;
    this.jobs.delete(id);
    this.schedulePersist();
    return job;
  }

  stats() {
    let queued = 0;
    let ready = 0;
    let failed = 0;
    for (const job of this.jobs.values()) {
      if (job.state === JOB_STATE.queued) queued += 1;
      else if (job.state === JOB_STATE.ready) ready += 1;
      else if (job.state === JOB_STATE.failed) failed += 1;
    }
    return { queued, running: this.running, ready, failed, total: this.jobs.size };
  }

  #trim() {
    const ordered = this.list();
    if (ordered.length <= this.historyLimit) return;
    for (const job of ordered.slice(this.historyLimit)) {
      if (ACTIVE_STATES.has(job.state)) continue;
      this.jobs.delete(job.id);
    }
  }

  #drain() {
    while (this.running < this.maxConcurrent) {
      const next = this.list()
        .filter((job) => job.state === JOB_STATE.queued)
        .sort((a, b) => a.createdAt - b.createdAt)[0];
      if (!next) return;
      this.#run(next);
    }
  }

  #run(job) {
    this.running += 1;
    this.update(job.id, { state: JOB_STATE.running, stage: "开始处理", progress: 0.01 });
    const update = (patch) => this.update(job.id, patch);
    Promise.resolve()
      .then(() => this.runner(job, { update }))
      .catch((error) => {
        const message = error instanceof Error ? error.message : String(error);
        this.logger?.warn("任务失败", { id: job.id, error: message });
        update({ state: JOB_STATE.failed, stage: "失败", error: message });
      })
      .finally(() => {
        this.running -= 1;
        this.#drain();
      });
  }
}

/** 对外输出：只暴露 App 需要的字段，内部路径不出网。 */
export function toPublicJob(job, { hasAudio = false } = {}) {
  return {
    id: job.id,
    state: job.state,
    stage: job.stage,
    progress: job.progress,
    title: job.title,
    author: job.author,
    durationSec: job.durationSec,
    sizeBytes: job.sizeBytes,
    error: job.error,
    hasAudio,
    createdAt: job.createdAt,
    updatedAt: job.updatedAt,
  };
}
