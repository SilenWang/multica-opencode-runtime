// 聚焦测试：scripts/codex-responses-filter.mjs
// 运行：pixi run test（= node --test scripts/test-codex-responses-filter.mjs）
//
// 覆盖 SIL-1033 的两类失败来源：
//   1. 上游白名单之外的 item（custom_tool_call / local_shell_call / compaction …）
//   2. previous_response_id / item_reference 依赖服务端 stored response
// 并验证代理基于本地 transcript 展开、缓存缺失时安全降级、上下游流式透传。

import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  TranscriptStore,
  createFilterServer,
  extractCompletedResponse,
  rewriteResponsesBody,
  sanitizeItem,
} from './codex-responses-filter.mjs';

const patchInput = '*** Begin Patch\n*** Add File: notes.txt\n+hello\n*** End Patch\n';

function makeStore() {
  return new TranscriptStore();
}

test('custom_tool_call / custom_tool_call_output 转成 function item，且去掉服务端 id', () => {
  const body = {
    model: 'deepseek-v4-flash',
    input: [
      { type: 'message', role: 'user', content: [{ type: 'input_text', text: '补丁' }] },
      {
        type: 'custom_tool_call',
        id: 'ctc_03AaIR-example',
        call_id: 'call_1',
        name: 'apply_patch',
        status: 'completed',
        input: patchInput,
      },
      { type: 'custom_tool_call_output', id: 'ctco_example', call_id: 'call_1', output: 'Success.' },
    ],
  };

  const { body: rewritten, rewritten: count } = rewriteResponsesBody(body, { store: makeStore() });

  assert.equal(count, 2);
  const [, call, output] = rewritten.input;
  assert.deepEqual(call, {
    type: 'function_call',
    call_id: 'call_1',
    name: 'apply_patch',
    arguments: JSON.stringify({ input: patchInput }),
  });
  assert.deepEqual(output, {
    type: 'function_call_output',
    call_id: 'call_1',
    output: 'Success.',
  });
  assert.equal(body.input[1].type, 'custom_tool_call', '原始 body 不被修改');
});

test('freeform 输入本身是 JSON 时直接作为 arguments', () => {
  const body = {
    input: [
      {
        type: 'custom_tool_call',
        call_id: 'call_2',
        name: 'apply_patch',
        input: '{"patch":"*** Begin Patch\\n*** End Patch\\n"}',
      },
    ],
  };

  const { body: rewritten } = rewriteResponsesBody(body, { store: makeStore() });
  assert.equal(rewritten.input[0].arguments, body.input[0].input);
  assert.equal(rewritten.input[0].type, 'function_call');
});

test('本地 shell / 远程压缩 / 未知类型都被降级成白名单形态', () => {
  const localShell = sanitizeItem({
    type: 'local_shell_call',
    call_id: 'call_3',
    action: { command: ['echo', 'hi'] },
  });
  assert.equal(localShell.item.type, 'function_call');
  assert.equal(localShell.item.name, 'local_shell');
  assert.deepEqual(JSON.parse(localShell.item.arguments), { command: ['echo', 'hi'] });

  for (const type of ['compaction', 'context_compaction', 'web_search_call', 'mystery_item']) {
    const result = sanitizeItem({ type, id: 'x', encrypted_content: 'opaque' });
    assert.equal(result.item.type, 'message', type);
    assert.equal(result.item.role, 'developer');
    assert.match(result.item.content[0].text, /omitted/);
    assert.equal(result.item.id, undefined);
  }
});

test('message / reasoning / function_call 等标准 item 原样保留', () => {
  const standard = [
    { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'hi' }] },
    { type: 'reasoning', id: 'rs_1', summary: [], content: [], encrypted_content: null },
    { type: 'function_call', id: 'fc_1', call_id: 'call_3', name: 'exec_command', arguments: '{}' },
    { type: 'function_call_output', id: 'fco_1', call_id: 'call_3', output: 'ok' },
  ];

  const { body, rewritten } = rewriteResponsesBody({ input: standard }, { store: makeStore() });
  assert.equal(rewritten, 0);
  assert.equal(body.input, standard);
});

test('item_reference 用本地 transcript 展开；缓存缺失时换成占位 message', () => {
  const store = makeStore();
  store.recordResponse('s1', 'resp_1', [
    { type: 'message', role: 'assistant', id: 'msg_1', content: [{ type: 'output_text', text: 'hello' }] },
  ]);

  const expanded = rewriteResponsesBody(
    {
      input: [
        { type: 'item_reference', id: 'msg_1' },
        { type: 'message', role: 'user', content: [{ type: 'input_text', text: '继续' }] },
      ],
    },
    { store, sessionId: 's1' },
  );
  assert.equal(expanded.expanded, 1);
  assert.equal(expanded.body.input[0].type, 'message');
  assert.equal(expanded.body.input[0].id, 'msg_1');

  const missing = rewriteResponsesBody(
    { input: [{ type: 'item_reference', id: 'rs_missing' }] },
    { store, sessionId: 's1' },
  );
  assert.equal(missing.body.input[0].type, 'message');
  assert.match(missing.body.input[0].content[0].text, /omitted/);
});

test('previous_response_id 用本地 output 重建完整 input；缺失时删字段而不是上送 400', () => {
  const store = makeStore();
  const output = [
    { type: 'reasoning', id: 'rs_9', summary: [], content: [], encrypted_content: null },
    { type: 'message', role: 'assistant', id: 'msg_9', content: [{ type: 'output_text', text: 'done' }] },
  ];
  store.recordResponse('s2', 'resp_9', output);

  const rebuilt = rewriteResponsesBody(
    {
      model: 'deepseek-v4-flash',
      previous_response_id: 'resp_9',
      input: [{ type: 'message', role: 'user', content: [{ type: 'input_text', text: '下一步' }] }],
    },
    { store, sessionId: 's2' },
  );
  assert.equal(rebuilt.previousResponseId, 'resp_9');
  assert.equal(rebuilt.expanded, 2);
  assert.equal(rebuilt.body.previous_response_id, undefined);
  assert.equal(rebuilt.body.input.length, 3);
  assert.deepEqual(rebuilt.body.input.slice(0, 2), output);

  const unknown = rewriteResponsesBody(
    { previous_response_id: 'resp_unknown', input: [{ type: 'message', role: 'user', content: [] }] },
    { store, sessionId: 's2' },
  );
  assert.equal(unknown.body.previous_response_id, undefined);
  assert.equal(unknown.body.input.length, 1);
});

test('TranscriptStore 可按会话隔离，并能从 JSONL 恢复', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sil1033-'));
  const file = path.join(dir, 'state.jsonl');
  try {
    const store = new TranscriptStore({ persistPath: file });
    store.recordResponse('s1', 'r1', [{ type: 'message', id: 'm1', role: 'assistant', content: [] }]);
    store.recordResponse('s2', 'r2', [{ type: 'message', id: 'm2', role: 'assistant', content: [] }]);

    const reloaded = new TranscriptStore({ persistPath: file });
    assert.equal(reloaded.lookupResponse('s1', 'r1')[0].id, 'm1');
    assert.equal(reloaded.lookupItem('s2', 'm2').id, 'm2');
    assert.equal(reloaded.lookupItem('s1', 'm2'), undefined, '会话之间不串数据');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('extractCompletedResponse 支持 SSE 与非流式 JSON', () => {
  const sse =
    'event: response.created\ndata: {"type":"response.created"}\n\n' +
    'event: response.completed\ndata: {"type":"response.completed","response":{"id":"resp_1","output":[{"type":"message","id":"m1"}]}}\n\n';
  assert.deepEqual(extractCompletedResponse(sse), {
    responseId: 'resp_1',
    output: [{ type: 'message', id: 'm1' }],
  });

  const json = JSON.stringify({ id: 'resp_2', output: [{ type: 'message', id: 'm2' }] });
  assert.equal(extractCompletedResponse(json).responseId, 'resp_2');
  assert.equal(extractCompletedResponse('event: ping\ndata: {}\n'), null);
});

test('端到端：SSE 响应被缓存，后续 previous_response_id 请求被重建为完整 input', async () => {
  const requests = [];
  const outputItem = {
    type: 'message',
    id: 'msg_upstream_1',
    role: 'assistant',
    content: [{ type: 'output_text', text: 'ok' }],
  };
  const upstream = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) {
      chunks.push(chunk);
    }
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
    requests.push({ url: req.url, headers: req.headers, body });
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write('event: response.created\ndata: {"type":"response.created"}\n\n');
    res.end(
      `event: response.completed\ndata: ${JSON.stringify({
        type: 'response.completed',
        response: { id: 'resp_upstream_1', output: [outputItem] },
      })}\n\n`,
    );
  });
  await new Promise((resolve) => upstream.listen(0, '127.0.0.1', resolve));

  const store = makeStore();
  const filter = createFilterServer({
    upstreamBase: `http://127.0.0.1:${upstream.address().port}`,
    upstreamToken: 'test-token',
    store,
    log: () => {},
  });
  await new Promise((resolve) => filter.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${filter.address().port}`;

  try {
    // 第一跳：记录 output
    const first = await fetch(`${base}/v1/responses`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'session-id': 's-e2e' },
      body: JSON.stringify({
        model: 'deepseek-v4-flash',
        input: [{ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'hi' }] }],
      }),
    });
    assert.equal(first.status, 200);
    assert.match(await first.text(), /response\.completed/);
    assert.equal(store.lookupResponse('s-e2e', 'resp_upstream_1')[0].id, 'msg_upstream_1');

    // 第二跳：previous_response_id 被展开成本地完整 input
    const second = await fetch(`${base}/v1/responses`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'session-id': 's-e2e' },
      body: JSON.stringify({
        model: 'deepseek-v4-flash',
        previous_response_id: 'resp_upstream_1',
        input: [
          {
            type: 'custom_tool_call',
            id: 'ctc_1',
            call_id: 'call_1',
            name: 'apply_patch',
            input: patchInput,
          },
        ],
      }),
    });
    assert.equal(second.status, 200);

    const forwarded = requests[1].body;
    assert.equal(forwarded.previous_response_id, undefined);
    assert.equal(forwarded.input[0].id, 'msg_upstream_1', '本地 output 被拼回 input');
    assert.equal(forwarded.input[1].type, 'function_call', 'custom tool 同时被降级');
    assert.equal(requests[1].headers.authorization, 'Bearer test-token');
  } finally {
    await new Promise((resolve) => filter.close(resolve));
    await new Promise((resolve) => upstream.close(resolve));
  }
});

test('/healthz 由代理直接回答，上游 400 原样透传', async () => {
  const upstreamError = {
    error: {
      message:
        'input items may be messages, function calls, function call outputs and reasoning. Item references need stored responses, which are not kept.',
      type: 'invalid_request_error',
      code: 'unsupported_input_item',
    },
  };
  let upstreamCalls = 0;
  const upstream = http.createServer((req, res) => {
    upstreamCalls += 1;
    req.resume();
    res.writeHead(400, { 'content-type': 'application/json' });
    res.end(JSON.stringify(upstreamError));
  });
  await new Promise((resolve) => upstream.listen(0, '127.0.0.1', resolve));

  const filter = createFilterServer({
    upstreamBase: `http://127.0.0.1:${upstream.address().port}`,
    upstreamToken: 'test-token',
    store: makeStore(),
    log: () => {},
  });
  await new Promise((resolve) => filter.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${filter.address().port}`;

  try {
    const health = await fetch(`${base}/healthz`);
    assert.equal(health.status, 200);
    assert.deepEqual(await health.json(), { ok: true });
    assert.equal(upstreamCalls, 0, 'healthz 不访问上游');

    const response = await fetch(`${base}/v1/responses`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'deepseek-v4-flash', input: [] }),
    });
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), upstreamError);
    assert.equal(upstreamCalls, 1);
  } finally {
    await new Promise((resolve) => filter.close(resolve));
    await new Promise((resolve) => upstream.close(resolve));
  }
});
