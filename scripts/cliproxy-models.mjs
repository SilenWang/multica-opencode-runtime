#!/usr/bin/env node
// CLIProxyAPI 模型映射生成器（SIL-1033）
//
// CLIProxyAPI 的 `openai-compatibility` 供应商要求显式声明 models（不配 = 没有模型），
// 而不同网关的模型集会随时间变化。这里在容器启动时从 `$BRIDGE_BASE_URL/v1/models`
// 动态生成映射：
//   1. 显式 `CLIPROXY_MODELS`（"上游名:别名,..."）优先，可手工钉住；
//   2. 否则请求 `/v1/models`，取返回的 id 列表；
//   3. 端点失败/超时/返回空 → 回退内置默认列表（与旧 entrypoint 一致）。
//
// 输出：可直接嵌进 CLIProxyAPI config.yaml 的 `models:` 片段（stdout），日志走 stderr。
// 退出码保持 0（发现失败不是致命错误，调用方用回退列表即可）。

import { fileURLToPath } from 'node:url';

/** 旧 entrypoint 的默认模型集，作为 /v1/models 不可用时的回退。 */
export const DEFAULT_MODELS = {
  newapi: ['deepseek-v4-flash', 'deepseek-v4.1-flash', 'qwen3.8-flash', 'kimi-k3'],
  deepseek: ['deepseek-v4-flash'],
};

/** 从 /v1/models 的响应体里提取模型 id（兼容 {data:[…]} 与 [...])。 */
export function parseModelIds(payload) {
  const list = Array.isArray(payload)
    ? payload
    : Array.isArray(payload?.data)
      ? payload.data
      : [];
  const ids = [];
  const seen = new Set();
  for (const item of list) {
    const id = typeof item === 'string' ? item : item?.id;
    if (typeof id !== 'string') {
      continue;
    }
    const trimmed = id.trim();
    if (!trimmed || seen.has(trimmed)) {
      continue;
    }
    seen.add(trimmed);
    ids.push(trimmed);
  }
  return ids;
}

/** 解析 "upstream:alias,..."；没有别名时两边同名。 */
export function parseModelSpecs(spec) {
  return String(spec || '')
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => {
      const [name, alias] = entry.split(':');
      return { name: name.trim(), alias: (alias || name).trim() };
    })
    .filter((entry) => entry.name);
}

/** 生成 CLIProxyAPI config.yaml 的 models 片段（缩进与上游示例一致）。 */
export function buildModelsYaml(models) {
  const specs = models
    .map((m) => (typeof m === 'string' ? { name: m, alias: m } : m))
    .filter((m) => m && m.name);
  return specs
    .map((m) => `      - name: ${JSON.stringify(m.name)}\n        alias: ${JSON.stringify(m.alias)}`)
    .join('\n')
    .concat(specs.length ? '\n' : '');
}

/**
 * 从上游 /v1/models 发现模型；任何失败（网络、超时、非 2xx、解析失败）返回 []。
 * 不抛异常：调用方据空数组回退默认列表。
 */
export async function discoverModelIds(options = {}) {
  const baseUrl = String(options.baseUrl || '').replace(/\/+$/, '');
  if (!baseUrl) {
    return [];
  }
  const url = /\/v1$/.test(baseUrl) ? `${baseUrl}/models` : `${baseUrl}/v1/models`;
  const timeoutMs = Number(options.timeoutMs || 5000);
  const fetchImpl = options.fetchImpl || globalThis.fetch;
  const controller = typeof AbortController === 'function' ? new AbortController() : null;
  const timer = controller ? setTimeout(() => controller.abort(), timeoutMs) : null;
  try {
    const response = await fetchImpl(url, {
      headers: options.token ? { authorization: `Bearer ${options.token}` } : {},
      signal: controller?.signal,
    });
    if (!response.ok) {
      return [];
    }
    return parseModelIds(await response.json());
  } catch {
    return [];
  } finally {
    if (timer) {
      clearTimeout(timer);
    }
  }
}

/** 解析最终要写入 config 的模型列表（优先级：显式 spec > 发现 > 回退）。 */
export function resolveModels({ modelsSpec = '', discovered = [], fallback = [] } = {}) {
  if (String(modelsSpec).trim()) {
    return { models: parseModelSpecs(modelsSpec), source: 'explicit' };
  }
  if (Array.isArray(discovered) && discovered.length > 0) {
    return { models: discovered.map((id) => ({ name: id, alias: id })), source: 'discovered' };
  }
  return {
    models: fallback.map((id) => ({ name: id, alias: id })),
    source: 'fallback',
  };
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith('--')) {
      continue;
    }
    const value = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : '';
    args[key.slice(2)] = value;
    if (value) {
      i += 1;
    }
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const upstream = args.upstream || 'newapi';
  const fallbackSpec = args.fallback || (DEFAULT_MODELS[upstream] || []).join(',');
  const fallback = fallbackSpec
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  let discovered = [];
  if (!String(args.models || '').trim()) {
    discovered = await discoverModelIds({
      baseUrl: args['base-url'] || process.env.BRIDGE_BASE_URL || '',
      token: args.token || process.env.BRIDGE_TOKEN || '',
      timeoutMs: args['timeout-ms'] || 5000,
    });
  }

  const { models, source } = resolveModels({
    modelsSpec: args.models || '',
    discovered,
    fallback,
  });
  if (source === 'discovered') {
    console.error(`cliproxy-models: discovered ${models.length} model(s) from /v1/models`);
  } else if (source === 'fallback') {
    console.error(
      `cliproxy-models: /v1/models unavailable, using ${models.length} built-in default model(s)`,
    );
  } else {
    console.error(`cliproxy-models: using ${models.length} explicit CLIPROXY_MODELS entr(ies)`);
  }
  process.stdout.write(buildModelsYaml(models));
}

const isMain = (() => {
  try {
    return process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
  } catch {
    return false;
  }
})();

if (isMain) {
  main().catch((error) => {
    console.error(`cliproxy-models: ${error?.message ?? error}`);
    process.exit(1);
  });
}
