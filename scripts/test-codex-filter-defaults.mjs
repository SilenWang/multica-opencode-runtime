// 聚焦测试：默认部署改为网关侧过滤后，CODEX_FILTER 的默认值与回滚路径
// 运行：pixi run test（= node --test scripts/test-*.mjs）
//
// 覆盖 SIL-1033 迁移的三条约束：
//   1. 默认 CODEX_FILTER=off（网关侧 commandcode 参数覆盖接管）；
//   2. 显式 CODEX_FILTER=on 仍能启动容器内代理（回滚能力保留）；
//   3. #45/#46 的实现与 Docker 安装未被删除，README/.env 写明部署顺序与回滚。

import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..');
const entrypointPath = path.join(repoRoot, 'scripts', 'entrypoint.sh');
const filterScript = path.join(repoRoot, 'scripts', 'codex-responses-filter.mjs');
const readmePath = path.join(repoRoot, 'README.md');
const envExamplePath = path.join(repoRoot, '.env.example');

function readEntrypointFilterSnippet() {
  const text = fs.readFileSync(entrypointPath, 'utf8');
  const start = text.indexOf('CODEX_FILTER_URL=""');
  assert.notEqual(start, -1, 'entrypoint 中应存在 CODEX_FILTER_URL=""');
  const callIndex = text.indexOf('\nsetup_codex_responses_filter\n', start);
  assert.notEqual(callIndex, -1, 'entrypoint 中应调用 setup_codex_responses_filter');
  return text.slice(start, callIndex);
}

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function runFilterSetup(env) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sil1033-filter-'));
  const harness = path.join(dir, 'harness.sh');
  fs.writeFileSync(
    harness,
    `#!/bin/bash\nset -e\n${readEntrypointFilterSnippet()}\nsetup_codex_responses_filter\nprintf 'URL=%s\\n' "\${CODEX_FILTER_URL}"\n`,
    { mode: 0o755 },
  );
  try {
    const { stdout } = await execFileAsync('bash', [harness], {
      env: { ...process.env, ...env },
      timeout: 60_000,
    });
    const match = stdout.match(/^URL=(.*)$/m);
    assert.ok(match, `harness 应输出 URL，实际：${stdout}`);
    return { url: match[1].trim(), dir, stdout };
  } finally {
    // 目录由调用方在清理 pid 后删除
  }
}

test('默认不设置 CODEX_FILTER 时，容器内代理不启动', async () => {
  const port = await freePort();
  const { url, dir } = await runFilterSetup({
    CODEX_FILTER: '',
    NEW_API_TOKEN: 'test-token',
    CODEX_FILTER_PORT: String(port),
    CODEX_FILTER_PIDFILE: path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'sil1033-pid-')), 'filter.pid'),
  });
  try {
    assert.equal(url, '', '默认应为 off，不设置 CODEX_FILTER_URL');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('显式 CODEX_FILTER=on 时启动代理并可通过 healthz（回滚能力保留）', async () => {
  const port = await freePort();
  const pidDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sil1033-pid-'));
  const pidFile = path.join(pidDir, 'filter.pid');
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sil1033-state-'));
  const { url, dir } = await runFilterSetup({
    CODEX_FILTER: 'on',
    NEW_API_TOKEN: 'test-token',
    CODEX_FILTER_PORT: String(port),
    CODEX_FILTER_PIDFILE: pidFile,
    CODEX_FILTER_STATE: path.join(stateDir, 'state.jsonl'),
    CODEX_FILTER_SCRIPT: filterScript,
    CODEX_FILTER_UPSTREAM: 'http://127.0.0.1:9',
  });
  try {
    assert.equal(url, `http://127.0.0.1:${port}/v1`);
    assert.ok(fs.existsSync(pidFile), '应写入 pid 文件');
    const health = await fetch(`http://127.0.0.1:${port}/healthz`);
    assert.equal(health.status, 200);
    assert.deepEqual(await health.json(), { ok: true });
  } finally {
    if (fs.existsSync(pidFile)) {
      const pid = Number(fs.readFileSync(pidFile, 'utf8').trim());
      if (Number.isInteger(pid) && pid > 0) {
        try {
          process.kill(pid, 'SIGTERM');
        } catch {
          // 已退出
        }
      }
    }
    fs.rmSync(dir, { recursive: true, force: true });
    fs.rmSync(pidDir, { recursive: true, force: true });
    fs.rmSync(stateDir, { recursive: true, force: true });
  }
});

test('entrypoint 默认值为 off，且仅显式 on 才进入启动分支', () => {
  const entrypoint = fs.readFileSync(entrypointPath, 'utf8');
  assert.match(entrypoint, /CODEX_FILTER:-off/, '默认值必须是 off');
  assert.doesNotMatch(entrypoint, /CODEX_FILTER:-on/, '不得残留默认 on');
  assert.match(entrypoint, /!= "on"/, '仅显式 on 才启动');
});

test('#45/#46 的实现未被删除，且仍随镜像安装', () => {
  assert.ok(fs.existsSync(filterScript), 'scripts/codex-responses-filter.mjs 必须保留');
  const source = fs.readFileSync(filterScript, 'utf8');
  assert.match(source, /export function rewriteResponsesBody/);
  assert.match(source, /export class TranscriptStore/);

  const dockerfile = fs.readFileSync(path.join(repoRoot, 'Dockerfile'), 'utf8');
  assert.match(
    dockerfile,
    /COPY scripts\/codex-responses-filter\.mjs \/codex-responses-filter\.mjs/,
    'Dockerfile 仍需安装代理脚本（回滚时使用）',
  );
});

test('README / .env.example 写明网关侧默认方案、部署顺序与回滚', () => {
  const readme = fs.readFileSync(readmePath, 'utf8');
  assert.match(readme, /网关侧过滤/);
  assert.match(readme, /commandcode/);
  assert.match(readme, /prune_objects/);
  assert.match(readme, /部署顺序/);
  assert.match(readme, /回滚/);
  assert.match(readme, /\| `CODEX_FILTER` \| `off` \|/, 'README 变量表默认值应为 off');

  const env = fs.readFileSync(envExamplePath, 'utf8');
  assert.match(env, /CODEX_FILTER=on/);
  assert.match(env, /默认 off/, '.env.example 应说明默认 off');
  assert.match(env, /部署顺序/);
  assert.match(env, /回滚/);
});
