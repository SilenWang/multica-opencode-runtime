// 聚焦测试：scripts/codex-responses-filter.mjs
// 运行：node --test scripts/test-codex-responses-filter.mjs（或 pixi run test）
//
// 覆盖 SIL-1033 的修复点：Codex 回放历史里的 custom_tool_call /
// custom_tool_call_output 会被改写成上游接受的 function_call /
// function_call_output，其余请求与响应保持原样。

import assert from 'node:assert/strict';
import http from 'node:http';
import test from 'node:test';

import { createFilterServer, rewriteResponsesBody } from './codex-responses-filter.mjs';

const patchInput = '*** Begin Patch\n*** Add File: notes.txt\n+hello\n*** End Patch\n';

test('custom_tool_call 转成 function_call，且不保留依赖服务端存储的 id', () => {
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

  const { body: rewritten, rewritten: count } = rewriteResponsesBody(body);

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
  // 原始 body 不被修改
  assert.equal(body.input[1].type, 'custom_tool_call');
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

  const { body: rewritten } = rewriteResponsesBody(body);
  assert.equal(rewritten.input[0].arguments, body.input[0].input);
  assert.equal(rewritten.input[0].type, 'function_call');
});

test('message / reasoning / function_call 等标准 item 原样保留', () => {
  const standard = [
    { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'hi' }] },
    { type: 'reasoning', id: 'rs_1', summary: [], content: [], encrypted_content: null },
    { type: 'function_call', id: 'fc_1', call_id: 'call_3', name: 'exec_command', arguments: '{}' },
    { type: 'function_call_output', id: 'fco_1', call_id: 'call_3', output: 'ok' },
  ];

  const { body, rewritten } = rewriteResponsesBody({ input: standard });
  assert.equal(rewritten, 0);
  assert.equal(body.input, standard);
});

test('没有 input 或不含 custom tool 的请求体不被改写', () => {
  const body = { model: 'deepseek-v4-flash', prompt: 'x' };
  const result = rewriteResponsesBody(body);
  assert.equal(result.rewritten, 0);
  assert.equal(result.body, body);
  assert.equal(rewriteResponsesBody(null).rewritten, 0);
});

test('代理会把改写后的请求发给上游并原样流式返回响应', async () => {
  let received = null;
  const upstream = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) {
      chunks.push(chunk);
    }
    received = {
      url: req.url,
      authorization: req.headers.authorization,
      body: JSON.parse(Buffer.concat(chunks).toString('utf8')),
    };
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write('event: response.created\ndata: {"type":"response.created"}\n\n');
    res.end('event: response.completed\ndata: {"type":"response.completed"}\n\n');
  });
  await new Promise((resolve) => upstream.listen(0, '127.0.0.1', resolve));
  const upstreamPort = upstream.address().port;

  const filter = createFilterServer({
    upstreamBase: `http://127.0.0.1:${upstreamPort}`,
    upstreamToken: 'test-token',
    log: () => {},
  });
  await new Promise((resolve) => filter.listen(0, '127.0.0.1', resolve));
  const filterPort = filter.address().port;

  try {
    const response = await fetch(`http://127.0.0.1:${filterPort}/v1/responses`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: 'Bearer client-token' },
      body: JSON.stringify({
        model: 'deepseek-v4-flash',
        input: [
          {
            type: 'custom_tool_call',
            id: 'ctc_example',
            call_id: 'call_9',
            name: 'apply_patch',
            input: patchInput,
          },
        ],
      }),
    });

    assert.equal(response.status, 200);
    assert.match(response.headers.get('content-type'), /event-stream/);
    const text = await response.text();
    assert.match(text, /response\.completed/);

    // 请求已到达上游：custom_tool_call 被翻译，作者头被代理 token 覆盖
    assert.equal(received.url, '/v1/responses');
    assert.equal(received.authorization, 'Bearer test-token');
    assert.equal(received.body.input[0].type, 'function_call');
    assert.equal(received.body.input[0].call_id, 'call_9');
    assert.equal(received.body.input[0].id, undefined);
    assert.equal(received.body.input[0].arguments, JSON.stringify({ input: patchInput }));

    // /healthz 由代理直接回答
    const health = await fetch(`http://127.0.0.1:${filterPort}/healthz`);
    assert.equal(health.status, 200);
    assert.deepEqual(await health.json(), { ok: true });
  } finally {
    await new Promise((resolve) => filter.close(resolve));
    await new Promise((resolve) => upstream.close(resolve));
  }
});

test('上游 400 错误原样透传（代理不吞错误）', async () => {
  const upstreamError = {
    error: {
      message: 'input items may be messages, function calls, function call outputs and reasoning.',
      type: 'invalid_request_error',
      code: 'unsupported_input_item',
    },
  };
  const upstream = http.createServer((req, res) => {
    req.resume();
    res.writeHead(400, { 'content-type': 'application/json' });
    res.end(JSON.stringify(upstreamError));
  });
  await new Promise((resolve) => upstream.listen(0, '127.0.0.1', resolve));

  const filter = createFilterServer({
    upstreamBase: `http://127.0.0.1:${upstream.address().port}`,
    upstreamToken: 'test-token',
    log: () => {},
  });
  await new Promise((resolve) => filter.listen(0, '127.0.0.1', resolve));

  try {
    const response = await fetch(`http://127.0.0.1:${filter.address().port}/v1/responses`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'deepseek-v4-flash', input: [] }),
    });
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), upstreamError);
  } finally {
    await new Promise((resolve) => filter.close(resolve));
    await new Promise((resolve) => upstream.close(resolve));
  }
});
