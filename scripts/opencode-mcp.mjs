#!/usr/bin/env node
// 把一条 stdio MCP server 合并进 opencode 的全局配置
// （默认 ~/.config/opencode/opencode.json 的 `mcp` 段）。
//
// 为什么单独一个脚本：entrypoint.sh 里的 opencode.json 只在 NEW_API_TOKEN 存在时
// 才整份重写，而 MCP 注册与 provider 无关；直接 cat 覆盖会丢掉用户/上游写入的
// provider、model 等字段。这里按 JSON 读-改-写，只动 `mcp` 下的一条 entry。
//
// 用法：opencode-mcp.mjs [config路径] [server名] [命令...]
//   node /opencode-mcp.mjs                                  # ~/.config/opencode/opencode.json + biomcp
//   node /opencode-mcp.mjs /tmp/x.json biomcp biomcp serve
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const configPath =
  process.argv[2] || path.join(os.homedir(), ".config", "opencode", "opencode.json");
const serverName = process.argv[3] || "biomcp";
const argv = process.argv.slice(4);
const command = argv.length > 0 ? argv : ["biomcp", "serve"];

let config = {};
try {
  config = JSON.parse(fs.readFileSync(configPath, "utf8"));
} catch (err) {
  // 文件不存在（或还是空的）时从 {} 开始；格式损坏则报错退出，避免静默清空用户配置。
  if (err.code !== "ENOENT") {
    console.error(`opencode-mcp: cannot parse ${configPath}: ${err.message}`);
    process.exit(1);
  }
}

if (typeof config !== "object" || config === null || Array.isArray(config)) {
  console.error(`opencode-mcp: ${configPath} is not a JSON object`);
  process.exit(1);
}

config.mcp = {
  ...(config.mcp && typeof config.mcp === "object" ? config.mcp : {}),
  [serverName]: { type: "local", command, enabled: true },
};

fs.mkdirSync(path.dirname(configPath), { recursive: true });
fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
console.log(`opencode: ${serverName} MCP -> ${command.join(" ")}`);
