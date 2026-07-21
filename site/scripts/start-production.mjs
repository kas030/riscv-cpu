#!/usr/bin/env node
import { access, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const siteRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const wranglerConfig = resolve(siteRoot, "dist/server/wrangler.json");
const localStateRoot = resolve(siteRoot, ".wrangler");

try {
  await access(wranglerConfig);
} catch {
  console.error("找不到生产构建，请先运行 npm run build");
  process.exit(1);
}

await mkdir(localStateRoot, { recursive: true });

const forwardedArgs = process.argv.slice(2);
const hasPort = forwardedArgs.some((arg) => arg === "--port" || arg.startsWith("--port="));
const args = [
  resolve(siteRoot, "node_modules/wrangler/bin/wrangler.js"),
  "dev",
  "--config",
  wranglerConfig,
  ...hasPort ? [] : ["--port", process.env.PORT ?? "3000"],
  ...forwardedArgs,
];

const child = spawn(process.execPath, args, {
  cwd: siteRoot,
  stdio: "inherit",
  env: {
    ...process.env,
    XDG_CONFIG_HOME: process.env.XDG_CONFIG_HOME ?? localStateRoot,
    WRANGLER_LOG_PATH: process.env.WRANGLER_LOG_PATH ?? resolve(localStateRoot, "logs"),
    MINIFLARE_REGISTRY_PATH: process.env.MINIFLARE_REGISTRY_PATH ?? resolve(localStateRoot, "registry"),
  },
});

child.on("error", (error) => {
  console.error(`生产服务器启动失败: ${error.message}`);
  process.exitCode = 1;
});

child.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exitCode = code ?? 1;
});
