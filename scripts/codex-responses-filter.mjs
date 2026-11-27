#!/usr/bin/env node
// Codex responses 请求兼容代理
//
// 背景（SIL-1033）
// --------------
// Codex 的 responses 请求会回放会话历史。New-API 背后的上游（DeepSeek 等）只接受
// 四类 input item：
//   message / function_call / function_call_output / reasoning
// 其余 item 会被当作 “item reference”，要求服务端保存过对应 response：
//   input items may be messages, function calls, function call outputs and reasoning.
//   Item references need stored responses, which are not kept.  (unsupported_input_item)
// Codex 对这个 400 不做降级重试，任务直接失败。
//
// 会产生这类 item 的来源（随 Codex 能力/会话状态变化）：
//   - custom_tool_call / custom_tool_call_output（apply_patch 等 freeform 工具）
//   - local_shell_call、compaction / context_compaction（远程压缩产物）、
//     web_search_call、image_generation_call、tool_search_*、additional_tools 等
//   - previous_response_id / item_reference（客户端增量模式；需要服务端 stored response）
//
// 本代理做两件事，且只在这两种情况下改写请求：
//   1) 基于本地 transcript 重建/展开引用：缓存每个会话的 response 输出，遇到
//      previous_response_id 或 item_reference 时用本地缓存的完整 item 展开；
//      缓存缺失时安全降级（去掉引用字段/换成占位 message），绝不让请求 400。
//   2) 把上游白名单之外的 item 降级成白名单形态：custom tool → function，
//      local_shell → function，其余（压缩/搜索/图片/工具搜索等）→ 占位 message。
//
// 其余请求头/路径/响应（含 SSE 流）与上游错误原样透传；解析失败按原请求转发
// （fail-open），代理自身不成为新的故障点。

import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/** 上游明确接受的 item 类型。 */
export const STANDARD_ITEM_TYPES = new Set([
  'message',
  'reasoning',
  'function_call',
  'function_call_output',
]);

/** 只用于本地重建、绝不上送上游的内部字段。 */
const INTERNAL_ITEM_FIELDS = ['internal_chat_message_metadata_passthrough'];

function truncate(text, max = 2000) {
  return text.length > max ? `${text.slice(0, max)}…[truncated]` : text;
}

function dropInternalFields(item) {
  if (!item || typeof item !== 'object') {
    return item;
  }
  for (const field of INTERNAL_ITEM_FIELDS) {
    delete item[field];
  }
  return item;
}

function placeholderMessage(type) {
  const label =
    type === 'compaction' || type === 'context_compaction'
      ? 'context compaction summary'
      : type;
  return {
    type: 'message',
    role: 'developer',
    content: [
      {
        type: 'input_text',
        text: `[${label} omitted by gateway compatibility filter]`,
      },
    ],
  };
}

function customCallArguments(item) {
  const input = item.input;
  if (typeof input !== 'string') {
    return JSON.stringify(input ?? {});
  }
  try {
    JSON.parse(input);
    return input;
  } catch {
    return JSON.stringify({ input });
  }
}

function customOutputValue(item) {
  const output = item.output;
  if (typeof output === 'string') {
    return output;
  }
  if (output === undefined || output === null) {
    return '';
  }
  return JSON.stringify(output);
}

/**
 * 把一个 input item 变成上游可接受的形态。
 * lookupItem(id) 用于展开 item_reference；返回 undefined 表示缓存缺失。
 */
export function sanitizeItem(item, lookupItem = () => undefined) {
  if (!item || typeof item !== 'object') {
    return { item, changed: false };
  }
  dropInternalFields(item);

  if (item.type === 'item_reference') {
    const referenced = item.id ? lookupItem(item.id) : undefined;
    if (referenced && typeof referenced === 'object') {
      // 缓存里的完整 item 仍可能是非白名单类型，递归降级。
      const sanitized = sanitizeItem({ ...referenced }, lookupItem);
      return { item: sanitized.item, changed: true, expanded: true };
    }
    return { item: placeholderMessage('item reference'), changed: true, dropped: true };
  }

  if (STANDARD_ITEM_TYPES.has(item.type)) {
    return { item, changed: false };
  }

  if (item.type === 'custom_tool_call') {
    return {
      item: {
        type: 'function_call',
        call_id: item.call_id,
        name: item.name,
        arguments: customCallArguments(item),
      },
      changed: true,
    };
  }

  if (item.type === 'custom_tool_call_output') {
    return {
      item: {
        type: 'function_call_output',
        call_id: item.call_id,
        output: customOutputValue(item),
      },
      changed: true,
    };
  }

  if (item.type === 'local_shell_call') {
    return {
      item: {
        type: 'function_call',
        call_id: item.call_id,
        name: item.name || 'local_shell',
        arguments: truncate(JSON.stringify(item.action ?? {}), 100000),
      },
      changed: true,
    };
  }

  // compaction / context_compaction / web_search_call / image_generation_call /
  // tool_search_* / additional_tools / agent_message / other ……
  return { item: placeholderMessage(String(item.type || 'unknown')), changed: true, dropped: true };
}

/**
 * 改写请求体：展开引用 + 降级非白名单 item。
 * options.sessionId 用于从 transcript 缓存取数据。
 */
export function rewriteResponsesBody(body, options = {}) {
  if (!body || typeof body !== 'object' || !Array.isArray(body.input)) {
    return { body, rewritten: 0, expanded: 0, replaced: 0, previousResponseId: null };
  }

  const store = options.store;
  const sessionId = options.sessionId || body.prompt_cache_key || 'default';
  const lookupItem = (id) => store?.lookupItem?.(sessionId, id);

  let input = body.input;
  let expanded = 0;
  let previousResponseId = null;

  if (body.previous_response_id) {
    previousResponseId = body.previous_response_id;
    const previous = store?.lookupResponse?.(sessionId, body.previous_response_id);
    if (Array.isArray(previous) && previous.length > 0) {
      // OpenAI 语义：previous_response_id + input 是增量；用本地缓存的 output
      // 拼回完整历史，再删掉字段（上游无状态，保留只会 400）。
      input = [...previous, ...input];
      expanded += previous.length;
    }
  }

  let replaced = 0;
  const out = input.map((item) => {
    const result = sanitizeItem(item, lookupItem);
    if (result.changed) {
      replaced += 1;
      if (result.expanded) {
        expanded += 1;
      }
    }
    return result.item;
  });

  const changed = Boolean(previousResponseId) || replaced > 0;
  const next = changed ? { ...body, input: out } : body;
  if (previousResponseId && next.previous_response_id) {
    delete next.previous_response_id;
  }

  return {
    body: next,
    rewritten: replaced,
    expanded,
    replaced,
    previousResponseId,
  };
}

/**
 * 本地 transcript 缓存：response id → output items，item id → item。
 * 可选 JSONL 落盘，容器/代理重启后仍能展开旧引用。
 */
export class TranscriptStore {
  constructor(options = {}) {
    this.maxResponses = options.maxResponses ?? 200;
    this.persistPath = options.persistPath ?? '';
    this.sessions = new Map();
    if (this.persistPath) {
      this.load();
    }
  }

  session(sessionId) {
    let state = this.sessions.get(sessionId);
    if (!state) {
      state = { responses: new Map(), items: new Map() };
      this.sessions.set(sessionId, state);
    }
    return state;
  }

  recordResponse(sessionId, responseId, outputItems) {
    if (!responseId || !Array.isArray(outputItems)) {
      return;
    }
    const state = this.session(sessionId);
    state.responses.set(responseId, outputItems);
    for (const item of outputItems) {
      if (item && item.id) {
        state.items.set(item.id, item);
      }
    }
    while (state.responses.size > this.maxResponses) {
      const oldest = state.responses.keys().next().value;
      state.responses.delete(oldest);
    }
    if (this.persistPath) {
      try {
        fs.appendFileSync(
          this.persistPath,
          `${JSON.stringify({ s: sessionId, r: responseId, o: outputItems })}\n`,
        );
      } catch {
        // 落盘失败不影响请求路径。
      }
    }
  }

  lookupResponse(sessionId, responseId) {
    return this.session(sessionId).responses.get(responseId);
  }

  lookupItem(sessionId, itemId) {
    return this.session(sessionId).items.get(itemId);
  }

  load() {
    let raw;
    try {
      raw = fs.readFileSync(this.persistPath, 'utf8');
    } catch {
      return;
    }
    for (const line of raw.split('\n')) {
      if (!line.trim()) {
        continue;
      }
      try {
        const row = JSON.parse(line);
        if (row && row.r && Array.isArray(row.o)) {
          const state = this.session(row.s || 'default');
          state.responses.set(row.r, row.o);
          for (const item of row.o) {
            if (item && item.id) {
              state.items.set(item.id, item);
            }
          }
        }
      } catch {
        // 跳过损坏行
      }
    }
  }

  /** 把内存里最近的状态重写回磁盘（启动/退出时调用）。 */
  compact() {
    if (!this.persistPath) {
      return;
    }
    const lines = [];
    for (const [sessionId, state] of this.sessions) {
      for (const [responseId, output] of state.responses) {
        lines.push(JSON.stringify({ s: sessionId, r: responseId, o: output }));
      }
    }
    try {
      fs.mkdirSync(path.dirname(this.persistPath), { recursive: true });
      fs.writeFileSync(this.persistPath, lines.length ? `${lines.join('\n')}\n` : '');
    } catch {
      // 忽略
    }
  }
}

function sessionIdFromHeaders(headers) {
  const direct = headers['session-id'] || headers['thread-id'];
  if (typeof direct === 'string' && direct) {
    return direct;
  }
  const meta = headers['x-codex-turn-metadata'];
  if (typeof meta === 'string' && meta) {
    try {
      const parsed = JSON.parse(meta);
      if (parsed.session_id) {
        return String(parsed.session_id);
      }
      if (parsed.thread_id) {
        return String(parsed.thread_id);
      }
    } catch {
      // ignore
    }
  }
  return 'default';
}

/** 从 SSE/JSON 响应里提取 response.completed 的 id 与 output。 */
export function extractCompletedResponse(text) {
  const trimmed = text.trim();
  if (trimmed.startsWith('{')) {
    try {
      const parsed = JSON.parse(trimmed);
      if (parsed && Array.isArray(parsed.output) && parsed.id) {
        return { responseId: parsed.id, output: parsed.output };
      }
    } catch {
      return null;
    }
    return null;
  }
  // SSE：按行扫描 data: 负载
  for (const line of trimmed.split('\n')) {
    if (!line.startsWith('data:')) {
      continue;
    }
    const payload = line.slice(5).trim();
    if (!payload || payload === '[DONE]') {
      continue;
    }
    try {
      const parsed = JSON.parse(payload);
      if (
        parsed?.type === 'response.completed' &&
        parsed.response?.id &&
        Array.isArray(parsed.response.output)
      ) {
        return { responseId: parsed.response.id, output: parsed.response.output };
      }
    } catch {
      // 跳过非 JSON 事件
    }
  }
  return null;
}

function upstreamFor(rawBase) {
  // 代理按客户端请求的原路径拼接（Codex 的 base_url 已带 /v1，请求路径就是
  // /v1/responses），所以上游只保留网关根地址，兼容用户填了带 /v1 的写法。
  const base = (rawBase || '').trim().replace(/\/+$/, '');
  if (!base) {
    return '';
  }
  return base.replace(/\/v1$/, '');
}

/**
 * 启动代理。返回 http.Server，便于测试 close()。
 */
export function createFilterServer(options = {}) {
  const upstreamBase = upstreamFor(
    options.upstreamBase ?? process.env.CODEX_FILTER_UPSTREAM ?? process.env.NEW_API_BASE_URL,
  );
  const upstreamToken =
    options.upstreamToken ?? process.env.CODEX_FILTER_TOKEN ?? process.env.NEW_API_TOKEN ?? '';
  const log = options.log ?? ((line) => console.error(line));
  const store =
    options.store ??
    new TranscriptStore({
      persistPath: options.persistPath ?? process.env.CODEX_FILTER_STATE ?? '',
      maxResponses: Number(process.env.CODEX_FILTER_MAX_RESPONSES || 200),
    });

  if (!upstreamBase) {
    throw new Error('CODEX_FILTER_UPSTREAM / NEW_API_BASE_URL is not set');
  }

  const server = http.createServer(async (req, res) => {
    if (req.method === 'GET' && req.url === '/healthz') {
      res.writeHead(200, { 'content-type': 'application/json' }).end('{"ok":true}');
      return;
    }

    const chunks = [];
    for await (const chunk of req) {
      chunks.push(chunk);
    }
    const raw = Buffer.concat(chunks);

    const sessionId = sessionIdFromHeaders(req.headers);
    let payload = raw;
    if (req.method === 'POST' && /\/responses(?:\?|$)/.test(req.url || '') && raw.length > 0) {
      try {
        const parsed = JSON.parse(raw.toString('utf8'));
        const { body, rewritten, expanded, previousResponseId } = rewriteResponsesBody(parsed, {
          store,
          sessionId,
        });
        if (rewritten > 0 || previousResponseId) {
          payload = Buffer.from(JSON.stringify(body));
          log(
            `session=${sessionId} rewrote ${rewritten} item(s), expanded ${expanded}` +
              (previousResponseId ? `, previous_response_id=${previousResponseId}` : ''),
          );
        }
      } catch (error) {
        // 解析失败就原样转发，代理不做假设。
        log(`left request untouched (parse error: ${error?.message ?? error})`);
      }
    }

    const headers = { ...req.headers };
    delete headers['content-length'];
    delete headers.host;
    delete headers.authorization;
    if (upstreamToken) {
      headers.authorization = `Bearer ${upstreamToken}`;
    }

    try {
      const upstream = await fetch(`${upstreamBase}${req.url || '/'}`, {
        method: req.method,
        headers,
        body: payload.length > 0 ? payload : undefined,
      });

      const responseHeaders = {};
      const contentType = upstream.headers.get('content-type');
      if (contentType) {
        responseHeaders['content-type'] = contentType;
      }
      const cacheControl = upstream.headers.get('cache-control');
      if (cacheControl) {
        responseHeaders['cache-control'] = cacheControl;
      }
      res.writeHead(upstream.status, responseHeaders);

      if (!upstream.body) {
        res.end();
        return;
      }

      const reader = upstream.body.getReader();
      const isEventStream = (contentType || '').includes('event-stream');
      let buffer = '';

      for (;;) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }
        const chunk = Buffer.from(value);
        res.write(chunk);

        // 只为了缓存 transcript，不改动转发内容
        if (upstream.status < 400) {
          buffer += chunk.toString('utf8');
          const cap = isEventStream ? 4 * 1024 * 1024 : 8 * 1024 * 1024;
          if (buffer.length > cap) {
            buffer = buffer.slice(-cap);
          }
        }
      }
      res.end();

      if (upstream.status < 400 && buffer) {
        const completed = extractCompletedResponse(buffer);
        if (completed) {
          store.recordResponse(sessionId, completed.responseId, completed.output);
        }
      }
    } catch (error) {
      log(`upstream request failed: ${error?.message ?? error}`);
      if (!res.headersSent) {
        res.writeHead(502, { 'content-type': 'application/json' });
      }
      res.end(
        JSON.stringify({ error: { message: `codex responses filter: ${error?.message ?? error}` } }),
      );
    }
  });

  server.upstreamBase = upstreamBase;
  server.transcriptStore = store;
  return server;
}

const isMain = (() => {
  try {
    return process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
  } catch {
    return false;
  }
})();

if (isMain) {
  const port = Number(process.env.CODEX_FILTER_PORT || 8321);
  const host = process.env.CODEX_FILTER_HOST || '127.0.0.1';
  let server;
  try {
    server = createFilterServer();
  } catch (error) {
    console.error(`codex responses filter not started: ${error?.message ?? error}`);
    process.exit(1);
  }
  server.listen(port, host, () => {
    console.error(`codex responses filter listening on ${host}:${port} -> ${server.upstreamBase}`);
  });
  const shutdown = () => {
    try {
      server.transcriptStore?.compact?.();
    } catch {
      // ignore
    }
    server.close(() => process.exit(0));
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}
