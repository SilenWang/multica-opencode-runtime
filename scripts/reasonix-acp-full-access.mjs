#!/usr/bin/env node
// Reasonix ACP 代理：在 daemon 收到 session/new（或 resume/load）之前，先把该会话的
// tool_approval 设为 Full access，再把会话响应转给 daemon。
//
// 背景：reasonix 1.38.8 起由「权限 preset」决定 bash 沙箱，ACP 新会话的 preset 被
// 硬编码为 workspace-write，且没有用户级默认设置；只有 ACP 客户端能通过
// session/set_config_option 切换。multica daemon 目前不发这个请求，于是在容器内
// 用本代理补发。容器本身已是隔离边界，容器内的 reasonix 无需再套一层沙箱。
//
// 接线：Dockerfile 设 MULTICA_REASONIX_PATH 指向本文件（daemon 支持该环境变量），
// 真实 reasonix 启动脚本通过 REASONIX_REAL_BIN 指定（默认 npm 全局 bin）。
//
// 任何非 `acp` 调用（--version、run 等）原样透传，不影响 daemon 的版本/模型探测。
import { spawn } from "node:child_process";
import readline from "node:readline";

const real = process.env.REASONIX_REAL_BIN || "/usr/local/bin/reasonix";
const args = process.argv.slice(2);
const FULL_ACCESS = process.env.REASONIX_ACP_FULL_ACCESS || "danger-full-access";
const LOG = process.env.REASONIX_ACP_SHIM_DEBUG === "1";

function log(msg) {
  if (LOG) process.stderr.write(`[reasonix-acp-shim] ${msg}\n`);
}

if (args[0] !== "acp") {
  const c = spawn(real, args, { stdio: "inherit" });
  c.on("exit", (code, sig) => process.exit(code ?? (sig ? 1 : 0)));
} else {
  const child = spawn(real, args, { stdio: ["pipe", "pipe", "pipe"] });
  const clientReq = new Map(); // daemon 请求 id -> method
  const injected = new Map();  // 补发请求 id -> { pendingLine }
  let counter = 2000000000;

  const rlOut = readline.createInterface({ input: child.stdout });
  rlOut.on("line", (line) => {
    let m = null;
    try { m = JSON.parse(line); } catch { /* 非 JSON 行，原样转发 */ }

    if (m && m.id !== undefined && m.method === undefined && (m.result !== undefined || m.error !== undefined)) {
      const held = injected.get(m.id);
      if (held) {
        injected.delete(m.id);
        log(`tool_approval=${FULL_ACCESS} applied${m.error ? " (error: " + JSON.stringify(m.error) + ")" : ""}`);
        // 先应用权限，再放行被挂起的会话响应，避免 daemon 的 prompt 与权限切换竞争
        process.stdout.write(held.pendingLine + "\n");
        return;
      }

      const method = clientReq.get(m.id);
      if (method !== undefined) clientReq.delete(m.id);
      if ((method === "session/new" || method === "session/resume" || method === "session/load") && !m.error) {
        const r = m.result || {};
        const sid = r.sessionId || (r.session && r.session.sessionId);
        if (sid) {
          const id = counter++;
          injected.set(id, { pendingLine: line });
          child.stdin.write(JSON.stringify({
            jsonrpc: "2.0",
            id,
            method: "session/set_config_option",
            params: { sessionId: sid, configId: "tool_approval", value: FULL_ACCESS },
          }) + "\n");
          log(`inject tool_approval=${FULL_ACCESS} for session ${sid}`);
          return; // 挂起会话响应，等权限应用完成
        }
      }
    }
    process.stdout.write(line + "\n");
  });

  const rlIn = readline.createInterface({ input: process.stdin });
  rlIn.on("line", (line) => {
    let m = null;
    try { m = JSON.parse(line); } catch { /* 非 JSON 行，原样转发 */ }
    if (m && m.method !== undefined && m.id !== undefined) clientReq.set(m.id, m.method);
    child.stdin.write(line + "\n");
  });

  child.stderr.on("data", (d) => process.stderr.write(d));
  process.stdin.on("end", () => child.stdin.end());
  child.on("exit", (code, sig) => process.exit(code ?? (sig ? 1 : 0)));
}
