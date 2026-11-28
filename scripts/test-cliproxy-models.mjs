// 聚焦测试：scripts/cliproxy-models.mjs
// 运行：pixi run test（= node --test scripts/test-*.mjs）
//
// 覆盖 CLIProxyAPI 模型映射的三层来源：
//   1. CLIPROXY_MODELS 显式指定；
//   2. 从上游 /v1/models 动态发现；
//   3. 端点失败/超时/空返回时回退内置默认列表。

import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import http from 'node:http';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import {
  DEFAULT_MODELS,
  buildModelsYaml,
  discoverModelIds,
  parseModelIds,
  parseModelSpecs,
  resolveModels,
} from './cliproxy-models.mjs';

const execFileAsync = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const cliPath = path.join(here, 'cliproxy-models.mjs');

async function withServer(handler, fn) {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    return await fn(`http://127.0.0.1:${server.address().port}`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

test('parseModelIds 支持 {data:[...]} / 数组，去重并跳过空值', () => {
  assert.deepEqual(
    parseModelIds({ data: [{ id: 'b' }, { id: 'a' }, { id: 'a' }, { id: '' }, { nope: 1 }] }),
    ['b', 'a'],
  );
  assert.deepEqual(parseModelIds([{ id: 'x' }, 'y']), ['x', 'y']);
  assert.deepEqual(parseModelIds({ data: [] }), []);
  assert.deepEqual(parseModelIds(null), []);
});

test('parseModelSpecs 支持 "上游名:别名" 与同名简写', () => {
  assert.deepEqual(parseModelSpecs('deepseek-chat:deepseek-v4-flash, kimi-k3'), [
    { name: 'deepseek-chat', alias: 'deepseek-v4-flash' },
    { name: 'kimi-k3', alias: 'kimi-k3' },
  ]);
  assert.deepEqual(parseModelSpecs(''), []);
});

test('buildModelsYaml 生成 CLIProxyAPI 的 models 片段并转义名称', () => {
  assert.equal(
    buildModelsYaml(['a', { name: 'b', alias: 'c' }, { name: 'q"uote', alias: 'q' }]),
    '      - name: "a"\n        alias: "a"\n' +
      '      - name: "b"\n        alias: "c"\n' +
      '      - name: "q\\"uote"\n        alias: "q"\n',
  );
  assert.equal(buildModelsYaml([]), '');
});

test('resolveModels 优先级：显式 > 发现 > 回退', () => {
  assert.deepEqual(
    resolveModels({ modelsSpec: 'up:alias', discovered: ['x'], fallback: ['f'] }),
    { models: [{ name: 'up', alias: 'alias' }], source: 'explicit' },
  );
  assert.deepEqual(resolveModels({ discovered: ['x', 'y'], fallback: ['f'] }), {
    models: [
      { name: 'x', alias: 'x' },
      { name: 'y', alias: 'y' },
    ],
    source: 'discovered',
  });
  assert.deepEqual(resolveModels({ discovered: [], fallback: ['f'] }), {
    models: [{ name: 'f', alias: 'f' }],
    source: 'fallback',
  });
});

test('discoverModelIds：成功取 id，非 2xx / 网络错误 / 非 JSON 均返回空', async () => {
  await withServer(
    (req, res) => {
      assert.equal(req.url, '/v1/models');
      assert.equal(req.headers.authorization, 'Bearer tok');
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ data: [{ id: 'alpha' }, { id: 'beta' }] }));
    },
    async (base) => {
      assert.deepEqual(await discoverModelIds({ baseUrl: base, token: 'tok' }), ['alpha', 'beta']);
    },
  );

  await withServer(
    (req, res) => {
      res.writeHead(500).end('boom');
    },
    async (base) => {
      assert.deepEqual(await discoverModelIds({ baseUrl: base, token: 'tok' }), []);
    },
  );

  await withServer(
    (req, res) => {
      res.writeHead(200, { 'content-type': 'text/plain' }).end('not json');
    },
    async (base) => {
      assert.deepEqual(await discoverModelIds({ baseUrl: base }), []);
    },
  );

  assert.deepEqual(await discoverModelIds({ baseUrl: 'http://127.0.0.1:9', timeoutMs: 300 }), []);
  assert.deepEqual(await discoverModelIds({ baseUrl: '' }), []);
});

test('CLI：/v1/models 可用时动态生成映射', async () => {
  await withServer(
    (req, res) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ data: [{ id: 'zeta' }, { id: 'eta' }] }));
    },
    async (base) => {
      const { stdout } = await execFileAsync(
        process.execPath,
        [cliPath, '--base-url', base, '--token', 'tok', '--fallback', 'fallback-model'],
        { timeout: 20_000 },
      );
      assert.match(stdout, /name: "zeta"/);
      assert.match(stdout, /name: "eta"/);
      assert.doesNotMatch(stdout, /fallback-model/);
    },
  );
});

test('CLI：端点失败时回退内置默认列表', async () => {
  const { stdout } = await execFileAsync(
    process.execPath,
    [cliPath, '--base-url', 'http://127.0.0.1:9', '--token', 'tok', '--fallback', 'a,b'],
    { timeout: 20_000 },
  );
  assert.equal(stdout, '      - name: "a"\n        alias: "a"\n      - name: "b"\n        alias: "b"\n');
  assert.ok(DEFAULT_MODELS.newapi.includes('deepseek-v4-flash'));
});

test('CLI：CLIPROXY_MODELS 显式指定时不访问端点', async () => {
  const { stdout } = await execFileAsync(
    process.execPath,
    [cliPath, '--models', 'up:alias', '--base-url', 'http://127.0.0.1:9', '--fallback', 'a'],
    { timeout: 20_000 },
  );
  assert.equal(stdout, '      - name: "up"\n        alias: "alias"\n');
});
