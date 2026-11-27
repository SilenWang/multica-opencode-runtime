#!/usr/bin/env node
// Codex responses 请求清洗代理（仅处理会导致上游 400 的 item 类型）
//
// 背景（SIL-1033）：Codex CLI 0.171 的 responses 请求会按“全量历史”回放会话，
// 其中 apply_patch 之类的 freeform 工具会产生 `custom_tool_call` /
// `custom_tool_call_output` item。New-API 的 responses 通道是无状态的（`store`
// 被强制改回 false，`previous_response_id` 一律 400），它把这类 item 视为
// “item reference”，需要上游保存过对应 response 才能解析；一旦会话间隔过长、
// 上游 channel 切换或响应存储过期，就会返回：
//
//   input items may be messages, function calls, function call outputs and
//   reasoning. Item references need stored responses, which are not kept.
//   code: unsupported_input_item
//
// Codex 对该 400 不做降级重试（will_retry=false），整个任务因此失败。
//
// 这里在本机（127.0.0.1）做最小改写：把 custom_tool_call / custom_tool_call_output
// 翻译成上游明确接受的 function_call / function_call_output，并去掉依赖服务端
// 存储的 item id。其余请求、响应（含 SSE 流）与错误原样透传；任何解析失败都
// 按原请求转发（fail-open），不会让代理本身成为新的故障点。

import http from 'node:http';
import { fileURLToPath } from 'node:url';

const CUSTOM_CALL = 'custom_tool_call';
const CUSTOM_OUTPUT = 'custom_tool_call_output';

/** 把 apply_patch 等 freeform 工具的输入包成 function_call 的 arguments 字符串。 */
function customCallArguments(item) {
  const input = item.input;
  if (typeof input !== 'string') {
    return JSON.stringify(input ?? {});
  }
  // 上游要求 arguments 是 JSON 字符串；freeform 输入本身是自由文本。
  try {
    JSON.parse(input);
    // 输入已经是合法 JSON：直接作为 arguments，避免再包一层。
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
 * 把 responses 请求体里的 custom tool item 翻译成 function item。
 * 返回原对象（无可改写项时）或新对象，以及改写数量。
 */
export function rewriteResponsesBody(body) {
  if (!body || typeof body !== 'object' || !Array.isArray(body.input)) {
    return { body, rewritten: 0 };
  }

  let rewritten = 0;
  const input = body.input.map((item) => {
    if (!item || typeof item !== 'object') {
      return item;
    }
    if (item.type === CUSTOM_CALL) {
      rewritten += 1;
      // 不保留 id：该 id 只有原上游的 stored response 才能解析。
      return {
        type: 'function_call',
        call_id: item.call_id,
        name: item.name,
        arguments: customCallArguments(item),
      };
    }
    if (item.type === CUSTOM_OUTPUT) {
      rewritten += 1;
      return {
        type: 'function_call_output',
        call_id: item.call_id,
        output: customOutputValue(item),
      };
    }
    return item;
  });

  if (rewritten === 0) {
    return { body, rewritten: 0 };
  }
  return { body: { ...body, input }, rewritten };
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
 * 启动清洗代理。返回 http.Server，便于测试中 close()。
 */
export function createFilterServer(options = {}) {
  const upstreamBase = upstreamFor(options.upstreamBase ?? process.env.CODEX_FILTER_UPSTREAM ?? process.env.NEW_API_BASE_URL);
  const upstreamToken = options.upstreamToken ?? process.env.CODEX_FILTER_TOKEN ?? process.env.NEW_API_TOKEN ?? '';
  const log = options.log ?? ((line) => console.error(line));

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

    let payload = raw;
    if (req.method === 'POST' && /\/responses(?:\?|$)/.test(req.url || '') && raw.length > 0) {
      try {
        const parsed = JSON.parse(raw.toString('utf8'));
        const { body, rewritten } = rewriteResponsesBody(parsed);
        if (rewritten > 0) {
          payload = Buffer.from(JSON.stringify(body));
          log(`rewrote ${rewritten} custom tool item(s) for ${req.url}`);
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
      for (;;) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }
        res.write(Buffer.from(value));
      }
      res.end();
    } catch (error) {
      log(`upstream request failed: ${error?.message ?? error}`);
      if (!res.headersSent) {
        res.writeHead(502, { 'content-type': 'application/json' });
      }
      res.end(JSON.stringify({ error: { message: `codex responses filter: ${error?.message ?? error}` } }));
    }
  });

  server.upstreamBase = upstreamBase;
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
  const shutdown = () => server.close(() => process.exit(0));
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}
