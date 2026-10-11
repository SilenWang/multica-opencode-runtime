#!/usr/bin/env node
// Reasonix ACP 代理：在 daemon 拿到 session/new（或 resume/load）结果之前，先把该会话的
// tool_approval 设为 Full access，再把会话响应转给 daemon。
//
// 背景（reasonix 1.38.11 实测）：
// - reasonix 1.38.8 起「权限 preset」接管 bash 沙箱与文件工具边界，ACP 新会话的 preset
//   固定从 workspace-write 开始，reasonix 没有用户级默认设置可以改它（实测
//   [desktop] default_tool_approval_mode 对 ACP 无效）；唯一的开关是 ACP 协议里的
//   session/set_config_option（configId = tool_approval），而 multica daemon 不发它。
// - daemon 还会给 reasonix 传 `--workspace-only`（忽略配置里的额外写根，把写操作限制在
//   会话 cwd）与 `--sandbox-bash auto`，二者都优先于 ~/.reasonix/config.toml，
//   所以只改容器内 reasonix 配置不足以放开 ACP 会话。
// - preset = danger-full-access 时 reasonix 明确「命令按当前 OS 用户走正常路径，关闭
//   reasonix 自身的文件系统与网络沙箱」，正是本容器想要的语义：容器已是隔离边界，
//   容器内不再套第二层沙箱。
//
// 接线：Dockerfile 安装本文件并设 MULTICA_REASONIX_PATH 指向它（daemon 支持该环境变量）；
// 真实 reasonix 用 REASONIX_REAL_BIN 指定（默认 npm 全局 bin）。
// 任何非 `acp` 调用（--version、doctor、run 等）原样透传，不影响 daemon 的探测。
import { spawn } from "node:child_process";
import readline from "node:readline";

const real = process.env.REASONIX_REAL_BIN || "/usr/local/bin/reasonix";
const args = process.argv.slice(2);
const FULL_ACCESS = process.env.REASONIX_ACP_FULL_ACCESS || "danger-full-access";
const LOG = process.env.REASONIX_ACP_SHIM_DEBUG !== "0";

function log(msg) {
  // 默认写 stderr（daemon 日志可见）：注入失败时要能立刻看出来，否则 preset 悄悄退回
  // workspace-write。REASONIX_ACP_SHIM_DEBUG=0 可关掉。
  if (LOG) process.stderr.write(`[reasonix-acp-shim] ${msg}\n`);
}

// 会话响应里回显的还是切换前的 preset（reasonix 在 session/new 时就已经发出该行）。
// reasonix 之后会补一条 config_option_update 通知，daemon 也能看到真实值；这里再把
// 挂起的那行改写成实际生效的 preset，免得客户端按旧值显示/决策。改写失败就原样转发。
function withFullAccess(line) {
  try {
    const m = JSON.parse(line);
    const opts = m && m.result && m.result.configOptions;
    if (Array.isArray(opts)) {
      for (const o of opts) if (o && o.id === "tool_approval") o.currentValue = FULL_ACCESS;
    }
    return JSON.stringify(m);
  } catch {
    return line;
  }
}

if (args[0] !== "acp") {
  const c = spawn(real, args, { stdio: "inherit" });
  c.on("exit", (code, sig) => process.exit(code ?? (sig ? 1 : 0)));
  c.on("error", (err) => {
    log(`failed to exec real reasonix (${real}): ${err.message}`);
    process.exit(127);
  });
} else {
  const child = spawn(real, args, { stdio: ["pipe", "pipe", "pipe"] });
  const clientReq = new Map(); // daemon 请求 id -> method
  const injected = new Map(); // 补发请求 id -> { pendingLine }
  let counter = 2000000000;

  child.on("error", (err) => {
    log(`failed to exec real reasonix (${real}): ${err.message}`);
    process.exit(127);
  });

  const rlOut = readline.createInterface({ input: child.stdout });
  rlOut.on("line", (line) => {
    let m = null;
    try {
      m = JSON.parse(line);
    } catch {
      /* 非 JSON 行，原样转发 */
    }

    if (m && m.id !== undefined && m.method === undefined && (m.result !== undefined || m.error !== undefined)) {
      const held = injected.get(m.id);
      if (held) {
        injected.delete(m.id);
        if (m.error) {
          log(`tool_approval=${FULL_ACCESS} REJECTED: ${JSON.stringify(m.error)} — session keeps the preset reasonix picked`);
        } else {
          log(`tool_approval=${FULL_ACCESS} applied`);
        }
        // 先应用权限，再放行被挂起的会话响应，避免 daemon 的 prompt 与权限切换竞争
        process.stdout.write((m.error ? held.pendingLine : held.rewrittenLine) + "\n");
        return;
      }

      const method = clientReq.get(m.id);
      if (method !== undefined) clientReq.delete(m.id);
      if ((method === "session/new" || method === "session/resume" || method === "session/load") && !m.error) {
        const r = m.result || {};
        const sid = r.sessionId || (r.session && r.session.sessionId);
        if (sid) {
          const id = counter++;
          injected.set(id, { pendingLine: line, rewrittenLine: withFullAccess(line) });
          child.stdin.write(
            JSON.stringify({
              jsonrpc: "2.0",
              id,
              method: "session/set_config_option",
              params: { sessionId: sid, configId: "tool_approval", value: FULL_ACCESS },
            }) + "\n",
          );
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
    try {
      m = JSON.parse(line);
    } catch {
      /* 非 JSON 行，原样转发 */
    }
    if (m && m.method !== undefined && m.id !== undefined) clientReq.set(m.id, m.method);
    child.stdin.write(line + "\n");
  });

  child.stderr.on("data", (d) => process.stderr.write(d));
  process.stdin.on("end", () => child.stdin.end());
  child.on("exit", (code, sig) => process.exit(code ?? (sig ? 1 : 0)));
}
