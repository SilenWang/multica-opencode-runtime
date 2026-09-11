#!/usr/bin/env node
// 给 dsh 的“子进程环境清洗”开一个 Multica 白名单口子。
//
// 背景（SIL-192）：dsh 的 @deepseek-ai/dsh-subprocess 在每次 spawn 子进程前会执行
// scrubbedParentEnv()，把父进程里名字命中 /KEY|PASSWORD|SECRET|TOKEN/i 的环境变量
// 全部删掉，再交给子进程。MULTICA_TOKEN 正好命中 TOKEN，于是 dsh 的 bash 工具里
// 看不到它；而 MULTICA_DAEMON_PORT / MULTICA_TASK_ID / MULTICA_AGENT_ID 等并不命中，
// 会被保留。multica CLI 因此判定“处于 agent 执行上下文，但缺少任务令牌”，直接失败：
//
//   agent execution context requires MULTICA_TOKEN to be a task-scoped mat_ token
//
// 结果就是 dsh 运行时里的 agent 无法执行任何 multica 命令（issue get / comment add /
// repo checkout …），dsh 作为 Multica runtime 基本不可用。
//
// Multica 官方文档在“Task runtime environment”里就点明了这一类问题：会过滤自身子进程
// 环境的工具需要显式放行（Codex 的 shell 工具同样丢 TOKEN/KEY/SECRET，由 daemon 的
// managed shell policy 放行）。dsh 没有对应的放行配置，所以只能在镜像构建期做一处
// 最小 patch：把 MULTICA_TOKEN 从清洗规则里豁免。
//
// 该 patch 幂等：已打过则跳过；dsh 升级后布局/字符串变化导致找不到目标时只告警、不失败，
// 避免把镜像构建炸掉（届时需要按新版本重新确认）。
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { execSync } from "node:child_process";

// npm may nest the dependency under the dsh package or hoist it to the sibling
// @deepseek-ai scope; accept either layout.
const TARGET_RELS = [
  "node_modules/@deepseek-ai/dsh-subprocess/lib/index.js",
  "../dsh-subprocess/lib/index.js",
];

const OLD_LOOP =
  'for (const [key, value] of Object.entries(process.env)) if (value !== void 0 && !SENSITIVE_ENV_PATTERN.test(key) && !key.toUpperCase().startsWith("DSH_")) env[key] = value;';
const NEW_LOOP =
  'for (const [key, value] of Object.entries(process.env)) if (value !== void 0 && (key === "MULTICA_TOKEN" || (!SENSITIVE_ENV_PATTERN.test(key) && !key.toUpperCase().startsWith("DSH_")))) env[key] = value;';
const MARKER = 'key === "MULTICA_TOKEN"';

function dshRoots() {
  if (process.env.DSH_INSTALL_ROOT) return [process.env.DSH_INSTALL_ROOT];
  const roots = [];
  try {
    roots.push(`${execSync("npm root -g", { encoding: "utf8" }).trim()}/@deepseek-ai/dsh`);
  } catch {
    // npm not resolvable here; fall through to the conventional global root
  }
  roots.push("/usr/local/lib/node_modules/@deepseek-ai/dsh");
  return roots;
}

function findTarget() {
  for (const root of dshRoots()) {
    for (const rel of TARGET_RELS) {
      const candidate = `${root}/${rel}`;
      if (existsSync(candidate)) return candidate;
    }
  }
  return "";
}

const target = findTarget();
if (!target) {
  console.warn(
    `WARNING: patch-dsh-env: dsh-subprocess not found under ${dshRoots().join(", ")}; skipped.`,
  );
  process.exit(0);
}

const source = readFileSync(target, "utf8");
if (source.includes(MARKER)) {
  console.log("patch-dsh-env: already applied.");
  process.exit(0);
}
if (!source.includes(OLD_LOOP)) {
  console.warn("WARNING: patch-dsh-env: scrub pattern not found (dsh layout changed?); skipped.");
  process.exit(0);
}

writeFileSync(target, source.replace(OLD_LOOP, NEW_LOOP));
console.log("patch-dsh-env: exempted MULTICA_TOKEN from the dsh subprocess env scrub.");
