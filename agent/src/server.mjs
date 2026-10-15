// 用途：局域网 HTTP 层。负责鉴权、路由、Range 播放与 JSON 输出；业务状态全部来自 JobStore。
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer } from "node:http";
import { timingSafeEqual } from "node:crypto";

import { JOB_STATE, extractDouyinUrl, toPublicJob } from "./jobs.mjs";

const JSON_HEADERS = { "content-type": "application/json; charset=utf-8" };

export function createApp({ store, config, token, logger }) {
  const server = createServer((req, res) => {
    handle(req, res).catch((error) => {
      logger.error("请求处理异常", { error: error.message, url: req.url });
      sendJson(res, 500, { error: "内部错误" });
    });
  });

  async function handle(req, res) {
    const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);

    res.setHeader("access-control-allow-origin", "*");
    res.setHeader("access-control-allow-headers", "authorization, content-type");
    res.setHeader("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
    if (req.method === "OPTIONS") return res.writeHead(204).end();

    if (url.pathname === "/" || url.pathname === "/index.html") {
      return sendHtml(res, renderHomePage({ store, config, token }));
    }

    // 探活接口不鉴权：App 配对前先要能确认「这台 Mac 可达」
    if (url.pathname === "/health" || url.pathname === "/v1/health") {
      return sendJson(res, 200, {
        ok: true,
        name: config.name,
        version: config.version,
        queue: store.stats(),
      });
    }

    if (!isAuthorized(req, url, token)) {
      return sendJson(res, 401, { error: "配对令牌不正确" });
    }

    if (url.pathname === "/v1/jobs" && req.method === "GET") {
      return sendJson(res, 200, { jobs: store.list().map((job) => publicJob(job)) });
    }

    if (url.pathname === "/v1/jobs" && req.method === "POST") {
      const body = await readJsonBody(req);
      let link;
      try {
        link = extractDouyinUrl(body.url ?? body.text, config.maxUrlLength);
      } catch (error) {
        return sendJson(res, 400, { error: error.message });
      }
      const { job, reused } = store.submit({ url: link });
      logger.info("收到任务", { id: job.id, reused });
      return sendJson(res, reused ? 200 : 202, { job: publicJob(job), reused });
    }

    const audioMatch = /^\/v1\/jobs\/([^/]+)\/audio$/.exec(url.pathname);
    if (audioMatch && req.method === "GET") {
      return sendAudio(req, res, audioMatch[1]);
    }

    const jobMatch = /^\/v1\/jobs\/([^/]+)$/.exec(url.pathname);
    if (jobMatch) {
      const job = store.get(jobMatch[1]);
      if (!job) return sendJson(res, 404, { error: "任务不存在" });
      if (req.method === "GET") return sendJson(res, 200, { job: publicJob(job) });
      if (req.method === "DELETE") {
        store.remove(job.id);
        return sendJson(res, 200, { ok: true });
      }
    }

    return sendJson(res, 404, { error: "接口不存在" });
  }

  function publicJob(job) {
    return toPublicJob(job, { hasAudio: job.state === JOB_STATE.ready && Boolean(job.audioFile) });
  }

  async function sendAudio(req, res, id) {
    const job = store.get(id);
    if (!job) return sendJson(res, 404, { error: "任务不存在" });
    if (job.state !== JOB_STATE.ready || !job.audioFile) {
      return sendJson(res, 409, { error: "音频还没准备好", state: job.state, stage: job.stage });
    }

    let info;
    try {
      info = await stat(job.audioFile);
    } catch {
      return sendJson(res, 410, { error: "音频文件已被清理" });
    }

    const headers = {
      "content-type": "audio/mpeg",
      "accept-ranges": "bytes",
      "cache-control": "no-store",
      "content-disposition": `inline; filename="${encodeURIComponent(job.title || "audio")}.mp3"`,
    };

    const range = parseRange(req.headers.range, info.size);
    if (!range) {
      res.writeHead(200, { ...headers, "content-length": info.size });
      if (req.method === "HEAD") return res.end();
      return createReadStream(job.audioFile).pipe(res);
    }

    if (range === "invalid") {
      res.writeHead(416, { ...headers, "content-range": `bytes */${info.size}` });
      return res.end();
    }

    res.writeHead(206, {
      ...headers,
      "content-length": range.end - range.start + 1,
      "content-range": `bytes ${range.start}-${range.end}/${info.size}`,
    });
    if (req.method === "HEAD") return res.end();
    return createReadStream(job.audioFile, { start: range.start, end: range.end }).pipe(res);
  }

  return { server, listen: () => listen(server, config) };
}

function listen(server, config) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(config.port, config.host, () => resolve(server.address()));
  });
}

function isAuthorized(req, url, token) {
  const header = req.headers.authorization || "";
  const fromHeader = header.toLowerCase().startsWith("bearer ") ? header.slice(7).trim() : "";
  const candidate = fromHeader || req.headers["x-d2m-token"] || url.searchParams.get("token") || "";
  return safeEqual(String(candidate), token);
}

function safeEqual(a, b) {
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  if (bufA.length !== bufB.length) return false;
  return timingSafeEqual(bufA, bufB);
}

function parseRange(header, size) {
  if (!header) return null;
  const match = /^bytes=(\d*)-(\d*)$/.exec(String(header).trim());
  if (!match) return "invalid";
  const [, startRaw, endRaw] = match;
  let start = startRaw === "" ? null : Number(startRaw);
  let end = endRaw === "" ? null : Number(endRaw);
  if (start === null && end === null) return "invalid";
  if (start === null) {
    start = Math.max(0, size - end);
    end = size - 1;
  } else if (end === null || end >= size) {
    end = size - 1;
  }
  if (!Number.isFinite(start) || !Number.isFinite(end) || start > end || start >= size) return "invalid";
  return { start, end };
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let raw = "";
    req.on("data", (chunk) => {
      raw += chunk;
      if (raw.length > 64 * 1024) {
        reject(new Error("请求体过大"));
        req.destroy();
      }
    });
    req.on("end", () => {
      if (!raw.trim()) return resolve({});
      try {
        return resolve(JSON.parse(raw));
      } catch {
        return reject(new Error("请求体不是合法 JSON"));
      }
    });
    req.on("error", reject);
  });
}

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, { ...JSON_HEADERS, "content-length": Buffer.byteLength(body) });
  res.end(body);
}

function sendHtml(res, html) {
  res.writeHead(200, {
    "content-type": "text/html; charset=utf-8",
    "content-length": Buffer.byteLength(html),
  });
  res.end(html);
}

/** 极简自检页：手机 Safari 打开即能确认连通性、试听和复制链接。 */
function renderHomePage({ store, config, token }) {
  const rows = store
    .list()
    .slice(0, 30)
    .map((job) => {
      const audio =
        job.state === JOB_STATE.ready
          ? `<audio controls preload="none" src="/v1/jobs/${job.id}/audio?token=${token}"></audio>`
          : "";
      const status =
        job.state === JOB_STATE.failed
          ? `<span class="bad">失败：${escapeHtml(job.error || "")}</span>`
          : `<span>${escapeHtml(job.stage)}${job.progress ? ` ${Math.round(job.progress * 100)}%` : ""}</span>`;
      return `<li><div class="t">${escapeHtml(job.title || job.id)}</div>${status}${audio}</li>`;
    })
    .join("");

  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${config.name}</title>
<style>
body{font:15px/1.6 -apple-system,sans-serif;margin:0;padding:20px;background:#f5f5f7;color:#1d1d1f}
h1{font-size:20px;margin:0 0 4px}
.hint{color:#6e6e73;font-size:13px;margin-bottom:16px}
ul{list-style:none;padding:0;margin:0}
li{background:#fff;border-radius:12px;padding:12px;margin-bottom:10px}
.t{font-weight:600;margin-bottom:6px;word-break:break-all}
audio{width:100%;margin-top:8px}
.bad{color:#d70015}
code{background:#e8e8ed;padding:2px 6px;border-radius:6px;word-break:break-all}
</style></head><body>
<h1>${config.name} 已运行</h1>
<div class="hint">本页只要能打开，就说明 iPhone 已经连通这台 Mac。API 基地址：<code>http://${escapeHtml(config.host === "0.0.0.0" ? "本机局域网IP" : config.host)}:${config.port}</code></div>
<ul>${rows || "<li>还没有任务</li>"}</ul>
</body></html>`;
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (ch) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[ch]);
}
