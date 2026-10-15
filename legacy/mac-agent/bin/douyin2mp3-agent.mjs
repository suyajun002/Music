#!/usr/bin/env node
// 用途：agent 启动入口。装配配置 → 任务队列 → 处理流水线 → HTTP 服务，并打印配对信息。
import { ensureDirs, lanAddresses, loadOrCreateToken, config } from "../src/config.mjs";
import { JobStore } from "../src/jobs.mjs";
import { logger } from "../src/logger.mjs";
import { createRunner } from "../src/pipeline.mjs";
import { createApp } from "../src/server.mjs";

async function main() {
  ensureDirs();
  const token = loadOrCreateToken();

  const runner = createRunner({ config, logger });
  const store = new JobStore({
    runner,
    maxConcurrent: config.maxConcurrentJobs,
    persistencePath: config.jobsFile,
    historyLimit: config.historyLimit,
    logger,
  });
  await store.load();

  const { listen } = createApp({ store, config, token, logger });
  const address = await listen();

  logger.info("agent 已启动", { host: config.host, port: address.port, library: config.libraryDir });
  const hosts = lanAddresses();
  if (!hosts.length) {
    logger.warn("没有找到局域网 IPv4 地址，手机可能无法直连");
  }
  for (const item of hosts) {
    logger.info(`配对地址（${item.iface}）：http://${item.address}:${config.port}`);
  }
  logger.info(`配对令牌：${token}`);
  logger.info("在手机 App 里填入上面的地址和令牌即可；令牌保存在本机 0600 权限文件里");
}

main().catch((error) => {
  logger.error("启动失败", { error: error.message });
  process.exit(1);
});
