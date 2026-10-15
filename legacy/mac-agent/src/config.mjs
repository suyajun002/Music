// 用途：集中管理 douyin2mp3 agent 的所有可变参数；实现层不硬编码端口、路径、超时、并发等实例值。
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { homedir, networkInterfaces } from "node:os";
import { join } from "node:path";

const HOME = homedir();

export const config = {
  name: "douyin2mp3-agent",
  version: "0.1.0",
  host: process.env.D2M_HOST || "0.0.0.0",
  port: Number(process.env.D2M_PORT || 8787),
  dataDir: process.env.D2M_DATA_DIR || join(HOME, ".douyin2mp3"),
  douyinCli:
    process.env.D2M_DOUYIN_CLI ||
    join(HOME, ".agents", "skills", "douyin-skill", "scripts", "douyin-dl.mjs"),
  nodeBin: process.env.D2M_NODE_BIN || process.execPath,
  ffmpegBin: process.env.D2M_FFMPEG || "ffmpeg",
  ffprobeBin: process.env.D2M_FFPROBE || "ffprobe",
  maxConcurrentJobs: Number(process.env.D2M_CONCURRENCY || 1),
  downloadTimeoutMs: Number(process.env.D2M_DOWNLOAD_TIMEOUT_MS || 300000),
  transcodeTimeoutMs: Number(process.env.D2M_TRANSCODE_TIMEOUT_MS || 300000),
  keepVideo: process.env.D2M_KEEP_VIDEO === "1",
  embedCover: process.env.D2M_EMBED_COVER !== "0",
  mp3Quality: process.env.D2M_MP3_QUALITY || "2",
  maxUrlLength: 2000,
  historyLimit: Number(process.env.D2M_HISTORY_LIMIT || 200),
};

config.libraryDir = join(config.dataDir, "library");
config.workDir = join(config.dataDir, "work");
config.tokenFile = join(config.dataDir, "token");
config.jobsFile = join(config.dataDir, "jobs.json");

export function ensureDirs() {
  for (const dir of [config.dataDir, config.libraryDir, config.workDir]) {
    mkdirSync(dir, { recursive: true });
  }
}

/** 首次启动生成局域网配对令牌，落盘 0600；后续复用。 */
export function loadOrCreateToken() {
  ensureDirs();
  if (existsSync(config.tokenFile)) {
    const existing = readFileSync(config.tokenFile, "utf8").trim();
    if (existing) return existing;
  }
  const token = randomBytes(24).toString("hex");
  writeFileSync(config.tokenFile, `${token}\n`, { mode: 0o600 });
  try {
    chmodSync(config.tokenFile, 0o600);
  } catch {
    // 权限设置失败不影响运行
  }
  return token;
}

/** 本机可供手机访问的 IPv4 地址，用于打印配对地址。 */
export function lanAddresses() {
  const found = [];
  for (const [iface, addrs] of Object.entries(networkInterfaces())) {
    for (const addr of addrs || []) {
      if (addr.family === "IPv4" && !addr.internal) {
        found.push({ iface, address: addr.address });
      }
    }
  }
  return found;
}
