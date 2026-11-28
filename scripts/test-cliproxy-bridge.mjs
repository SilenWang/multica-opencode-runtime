// 聚焦测试：entrypoint 的 setup_cliproxyapi（配置生成 / 动态模型 / 兜底 / 桥接启动）
// 运行：pixi run test（= node --test scripts/test-*.mjs）
//
// 用假 CLIProxyAPI 二进制 + 假上游 /v1/models，真实执行 entrypoint 里的
// setup_cliproxyapi 片段，验证：
//   1. CLIPROXY_BRIDGE=off / 二进制缺失时回退直连；
//   2. 上游 /v1/models 可用时把发现的模型写进 config.yaml；
//   3. 端点失败时回退内置默认列表；
//   4. 生成的 config.yaml 关键字段（disable-cooling、base-url、api key）与桥接就绪。

import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
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
const modelsScript = path.join(repoRoot, 'scripts', 'cliproxy-models.mjs');

function readBridgeSnippet() {
  const text = fs.readFileSync(entrypointPath, 'utf8');
  const start = text.indexOf('CODEX_BRIDGE_URL=""');
  assert.notEqual(start, -1, 'entrypoint 中应存在 CODEX_BRIDGE_URL=""');
  const callIndex = text.indexOf('\nsetup_cliproxyapi\n', start);
  assert.notEqual(callIndex, -1, 'entrypoint 中应调用 setup_cliproxyapi');
  return text.slice(start, callIndex);
}

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function startUpstream(handler) {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

/** 假 CLIProxyAPI：读取 --config，按 port 监听并返回 /v1/models。 */
function writeFakeBridge(dir) {
  const serverPath = path.join(dir, 'fake-bridge.mjs');
  fs.writeFileSync(
    serverPath,
    `import fs from 'node:fs';
import http from 'node:http';
const config = fs.readFileSync(process.argv[2], 'utf8');
const port = Number((config.match(/^port:\\s*(\\d+)/m) || [])[1]);
http.createServer((req, res) => {
  if ((req.url || '').includes('/models')) {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"data":[{"id":"bridge-ok"}]}');
    return;
  }
  res.writeHead(404).end('{}');
}).listen(port, '127.0.0.1');
`,
  );
  const binPath = path.join(dir, 'fake-cliproxyapi');
  fs.writeFileSync(
    binPath,
    `#!/bin/bash\nexec "${process.execPath}" "${serverPath}" "$2"\n`,
    { mode: 0o755 },
  );
  return binPath;
}

async function runBridge(env) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sil1033-bridge-'));
  const harness = path.join(dir, 'harness.sh');
  fs.writeFileSync(
    harness,
    `#!/bin/bash\nset -e\n${readBridgeSnippet()}\nsetup_cliproxyapi\nprintf 'URL=%s\\n' "\${CODEX_BRIDGE_URL}"\n`,
    { mode: 0o755 },
  );
  try {
    const { stdout } = await execFileAsync('bash', [harness], {
      env: { ...process.env, ...env },
      timeout: 90_000,
    });
    const match = stdout.match(/^URL=(.*)$/m);
    assert.ok(match, `harness 应输出 URL，实际：${stdout}`);
    return { url: match[1].trim(), dir, stdout };
  } finally {
    // 目录与桥接进程由调用方清理
  }
}

function cleanupBridge(dir, home) {
  const pidFile = path.join(home, 'cliproxyapi.pid');
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
  fs.rmSync(home, { recursive: true, force: true });
}

test('CLIPROXY_BRIDGE=off 时不启动桥接，Codex 回退直连', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sil1033-home-'));
  const { url, dir, stdout } = await runBridge({
    CLIPROXY_BRIDGE: 'off',
    CLIPROXY_HOME: home,
    NEW_API_TOKEN: 'test-token',
    NEW_API_BASE_URL: 'http://127.0.0.1:9',
    CLIPROXY_BIN: '/nonexistent/cliproxyapi',
  });
  try {
    assert.equal(url, '');
    assert.match(stdout, /bridge disabled/);
  } finally {
    cleanupBridge(dir, home);
  }
});

test('CLIProxyAPI 未安装时告警并回退直连', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sil1033-home-'));
  const { url, dir, stdout } = await runBridge({
    CLIPROXY_BRIDGE: 'on',
    CLIPROXY_HOME: home,
    NEW_API_TOKEN: 'test-token',
    NEW_API_BASE_URL: 'http://127.0.0.1:9',
    CLIPROXY_BIN: '/nonexistent/cliproxyapi',
  });
  try {
    assert.equal(url, '');
    assert.match(stdout, /not installed/);
  } finally {
    cleanupBridge(dir, home);
  }
});

test('从上游 /v1/models 动态生成模型映射，并生成可用桥接配置', async () => {
  const upstream = await startUpstream((req, res) => {
    assert.equal(req.url, '/v1/models');
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ data: [{ id: 'alpha' }, { id: 'beta' }] }));
  });
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sil1033-home-'));
  const binDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sil1033-bin-'));
  const bin = writeFakeBridge(binDir);
  const port = await freePort();
  const { url, dir, stdout } = await runBridge({
    CLIPROXY_BRIDGE: 'on',
    CLIPROXY_HOME: home,
    CLIPROXY_PORT: String(port),
    NEW_API_TOKEN: 'test-token',
    NEW_API_BASE_URL: upstream.url,
    CLIPROXY_BIN: bin,
    CLIPROXY_MODELS_SCRIPT: modelsScript,
  });
  try {
    assert.equal(url, `http://127.0.0.1:${port}/v1`);
    assert.match(stdout, /bridge ready/);
    const config = fs.readFileSync(path.join(home, 'config.yaml'), 'utf8');
    assert.match(config, /port: \d+/);
    assert.match(config, /disable-cooling: true/);
    assert.match(config, new RegExp(`base-url: "${upstream.url}/v1"`));
    assert.match(config, /name: "alpha"/);
    assert.match(config, /alias: "beta"/);
    assert.doesNotMatch(config, /deepseek-v4-flash/, '不应回退默认列表');
    const health = await fetch(`http://127.0.0.1:${port}/v1/models`, {
      headers: { authorization: 'Bearer test' },
    });
    assert.equal(health.status, 200);
  } finally {
    cleanupBridge(dir, home);
    fs.rmSync(binDir, { recursive: true, force: true });
    await upstream.close();
  }
});

test('/v1/models 失败时回退内置默认模型列表', async () => {
  const upstream = await startUpstream((req, res) => {
    res.writeHead(500).end('down');
  });
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sil1033-home-'));
  const binDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sil1033-bin-'));
  const bin = writeFakeBridge(binDir);
  const port = await freePort();
  const { url, dir, stdout } = await runBridge({
    CLIPROXY_BRIDGE: 'on',
    CLIPROXY_HOME: home,
    CLIPROXY_PORT: String(port),
    NEW_API_TOKEN: 'test-token',
    NEW_API_BASE_URL: upstream.url,
    CLIPROXY_BIN: bin,
    CLIPROXY_MODELS_SCRIPT: modelsScript,
  });
  try {
    assert.equal(url, `http://127.0.0.1:${port}/v1`);
    assert.match(stdout, /bridge ready/);
    const config = fs.readFileSync(path.join(home, 'config.yaml'), 'utf8');
    for (const model of ['deepseek-v4-flash', 'deepseek-v4.1-flash', 'qwen3.8-flash', 'kimi-k3']) {
      assert.match(config, new RegExp(`name: "${model.replace(/\./g, '\\.')}"`));
    }
  } finally {
    cleanupBridge(dir, home);
    fs.rmSync(binDir, { recursive: true, force: true });
    await upstream.close();
  }
});

test('entrypoint 已恢复桥接、回退直连与回滚开关（静态断言）', () => {
  const entrypoint = fs.readFileSync(entrypointPath, 'utf8');
  assert.match(entrypoint, /setup_cliproxyapi\(\)/);
  assert.match(entrypoint, /\nsetup_cliproxyapi\n/);
  assert.match(entrypoint, /CLIPROXY_BRIDGE:-auto/);
  assert.match(entrypoint, /CLIPROXY_MODELS_SCRIPT:-/);
  assert.match(entrypoint, /BRIDGE_MODELS_DEFAULT="deepseek-v4-flash,deepseek-v4\.1-flash,qwen3\.8-flash,kimi-k3"/);
  assert.match(entrypoint, /CODEX_BRIDGE_URL="http:\/\/127\.0\.0\.1:\$\{CLIPROXY_PORT\}\/v1"/);
  assert.doesNotMatch(entrypoint, /CODEX_FILTER/);
  assert.doesNotMatch(entrypoint, /codex-responses-filter/);

  const dockerfile = fs.readFileSync(path.join(repoRoot, 'Dockerfile'), 'utf8');
  assert.match(dockerfile, /CLI_PROXY_API_VERSION=7\.2\.146/);
  assert.match(dockerfile, /install -m 0755 .*cli-proxy-api \/usr\/local\/bin\/cliproxyapi/);
  assert.match(dockerfile, /COPY scripts\/cliproxy-models\.mjs \/cliproxy-models\.mjs/);
  assert.doesNotMatch(dockerfile, /codex-responses-filter/);
});
