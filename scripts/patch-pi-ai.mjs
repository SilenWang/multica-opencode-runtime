// 对 pi-ai openai-completions.js 打幂等 patch：
// 把 model.provider === "opencode-go" && reasoning/reasoning_content
// 放宽为 (model.provider === "opencode-go" || model.provider === "new_api") && ...
// 跑法：node patch-pi-ai.mjs [目标路径]
// 默认目标：dsh 全局安装位置（镜像内路径）
//
// 语义：找不到文件/目标字符串时仅告警并退出 0（不炸镜像构建）；幂等重跑安全。
import fs from 'node:fs';

const TARGET = process.argv[2] || '/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js';

if (!fs.existsSync(TARGET)) {
  console.error(`WARN: ${TARGET} not found; skipping pi-ai patch (thinking 400 may persist)`);
  process.exit(0);
}

let code = fs.readFileSync(TARGET, 'utf8');
const orig = code;

// 两处替换：(A && B) -> ((A || C) && B) 保持运算符优先级
code = code.replace(
  `model.provider === "opencode-go" && foundReasoningField === "reasoning"`,
  `(model.provider === "opencode-go" || model.provider === "new_api") && foundReasoningField === "reasoning"`
);
code = code.replace(
  `model.provider === "opencode-go" && signature === "reasoning"`,
  `(model.provider === "opencode-go" || model.provider === "new_api") && signature === "reasoning"`
);

if (code === orig) {
  // 可能已被之前跑过打过了，检查另一种形态
  if (orig.includes('|| model.provider === "new_api"')) {
    console.log(`already patched (skipped): ${TARGET}`);
  } else {
    console.error(`WARN: patchable targets not found in ${TARGET} (pi-ai version drift?); skipping`);
  }
  process.exit(0);
} else {
  fs.writeFileSync(TARGET, code, 'utf8');
  console.log(`patched (2 replacements): ${TARGET}`);
  process.exit(0);
}
