// 用途：统一日志格式，级别由 D2M_LOG_LEVEL 控制，避免各层自己拼字符串。
const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };
const threshold = LEVELS[process.env.D2M_LOG_LEVEL || "info"] ?? LEVELS.info;

function emit(level, message, extra) {
  if (LEVELS[level] < threshold) return;
  const line = `${new Date().toISOString()} ${level.toUpperCase()} ${message}`;
  const text = extra === undefined ? line : `${line} ${JSON.stringify(extra)}`;
  const stream = LEVELS[level] >= LEVELS.warn ? process.stderr : process.stdout;
  stream.write(`${text}\n`);
}

export const logger = {
  debug: (message, extra) => emit("debug", message, extra),
  info: (message, extra) => emit("info", message, extra),
  warn: (message, extra) => emit("warn", message, extra),
  error: (message, extra) => emit("error", message, extra),
};
