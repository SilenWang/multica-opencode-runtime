# multica-opencode-runtime

一个开箱即用的 Multica Runtime 容器：预装 [multica](https://multica.ai/docs)、[opencode](https://opencode.ai)、Codex CLI、Reasonix 等 agent，并内置 New-API / DeepSeek 的接入。构建后填入 `.env` 即可启动一个可用的运行时容器。

## 目录

- [内置组件](#内置组件)
- [构建与启动](#构建与启动)
- [首次配置](#首次配置)
- [Agent 与 API 接入](#agent-与-api-接入)
- [插件](#插件)
- [浏览器（ego-browser）](#浏览器ego-browser)
- [数据持久化](#数据持久化)
- [容器内使用 Docker](#容器内使用-docker)
- [重置容器](#重置容器)
- [同时多运行时](#同时多运行时)

## 内置组件

基础镜像为 `ghcr.io/prefix-dev/pixi:0.76.1-noble-cuda-13.0.0`（Ubuntu Noble + CUDA 13.0.0），已预装 pixi。容器内软件如下（`Dockerfile` 未固定版本的会在构建时取最新，括号内为当前镜像的实测版本）：

| 组件 | 版本 | 安装方式 | 说明 |
| --- | --- | --- | --- |
| pixi | 0.76.1 | 基础镜像 | 包/环境管理器；multica、opencode 通过 `pixi global` 安装 |
| Node.js | v22.23.2 | 官方 tarball 解压到 `/usr/local` | 供 npm 全局工具、ponytail 的 hooks 使用 |
| npm | 10.9.8 | 随 Node | registry 设为 `registry.npmmirror.com`，`@tencent-ai` 走腾讯镜像 |
| pnpm | 12.4.1 | `npm -g` | |
| multica | 0.4.43 | `pixi global`（channel `https://prefix.dev/sylens`） | Runtime 本体：自动登录并启动 daemon |
| opencode | 1.18.30 | `pixi global`（同上 channel） | |
| Codex CLI | 0.154.0 | `npm -g @openai/codex` | |
| Reasonix | 最新 | `npm -g reasonix` | 容器内 bash 沙箱依赖 `bubblewrap`（见 [Reasonix](#reasonix) 章节） |
| gt (Gitea CLI) | 2.0.0 | dl.gitea.com 固定版本 + SHA256 校验，装到 `/usr/local/bin/gt` | Gitea 官方新一代命令行工具（取代 tea）；未预置登录，用 `gt auth login` 认证 |
| ponytail | v4.9.0 | `git clone --depth 1 --branch v4.9.0` → `/opt/ponytail` | 仅 Codex 的插件，默认关闭 |
| gh (GitHub CLI) | 2.45.0 | `apt` | 容器启动时检测登录（未登录不阻塞，可手动认证） |
| docker CLI | 29.1.3 | `apt docker.io` | 配合挂载的宿主机 docker socket |
| docker compose | 2.40.3 | `apt docker-compose-v2` | |
| Google Chrome | 最新 stable | `apt google-chrome-stable` | 无头浏览器二进制 |
| ego-browser | v0.2.0（ego-lite-linux，未打补丁） | `install-linux.sh` 构建后装到 `~/.local/bin` | agent 驱动浏览器的 CLI + host daemon（见 [浏览器](#浏览器ego-browser)） |
| curl / git / sudo / xz-utils | - | `apt` | |
| fontconfig / fonts-noto-cjk / fonts-noto-color-emoji | - | `apt` | CJK 字体与彩色 emoji（`fontconfig` 提供 `fc-cache`/`fc-list`/`fc-match`），另附 `scripts/fonts-noto-cjk-zh.conf` 补 `lang=zh` 映射；缺失时浏览器截图里的中文会渲染成方块 |

其它环境特性：

- 支持 GPU（NVIDIA GPU + DRI 设备）。
- `ubuntu` 用户拥有免密 sudo，且已加入镜像内的 `docker` 组。
- 容器内可直接调用宿主机 Docker（见 [容器内使用 Docker](#容器内使用-docker)）。

## 构建与启动

```bash
docker-compose build
docker-compose up -d
```

## 首次配置

按 `.env.example` 填写 `.env`。关键变量：

| 变量 | 必填 | 说明 |
| --- | --- | --- |
| `MULTICA_TOKEN` | 是 | 在 Multica 工作区的 `API TOKEN` 中生成。容器启动后自动登录（server 固定为 `https://api.multica.ai`）并启动 daemon |
| `CONTAINER_NAME` | 是 | 运行时容器名 |
| `DEEPSEEK_TOKEN` | 二选一 | DeepSeek 官方 API key |
| `NEW_API_TOKEN` | 二选一 | New-API 网关 key（优先使用） |
| `NEW_API_BASE_URL` | 否 | New-API 地址，默认 `http://192.168.8.228:3000` |
| `DOCKER_HOST_GID` | 否 | 宿主机 docker 组 GID，默认 `999`（见下） |

- multica 使用 token 登录：`MULTICA_TOKEN` 与运行时编码绑定，手动生成并保存有助于恢复运行时容器。
- GitHub 未登录不会影响容器启动：容器会正常保持运行。进入容器后执行 `BROWSER=false gh auth login` 完成认证（或在 `.env` 里设置 `GH_TOKEN` / `GITHUB_TOKEN`，启动时自动登录）。认证后权限与 GitHub 网页端一致，无需额外配置私有仓库/组织权限。
  - 推荐用 **PAT**（`GH_TOKEN`，classic scopes：`repo, read:org, gist, workflow`）。容器启动时会把它写进 `~/.config/gh/hosts.yml` 并执行 `gh auth setup-git`，因为只放在 env 里不够：
    - Codex 的每任务 `codex-home/config.toml` 带一段 multica-managed `[shell_environment_policy]`，其 `include_only` 白名单不含 `GH_TOKEN`/`GITHUB_TOKEN`，Codex 的 shell 里 `gh` 会完全没凭据（报 `To get started with GitHub CLI`）；
    - `git` 不读 `GH_TOKEN`，没有 credential helper 时 `git push` 报 `could not read Username for github.com`。
    - `hosts.yml` 是文件，不受 agent shell 的 env 白名单影响，`gh` 和 `git`（经 helper）都能用。
  - 为什么要带 `BROWSER=false`：镜像里预装了 headed Chrome + Xvfb，`gh` 检测到浏览器可打开时会尝试自己拉起浏览器，设备验证码看不到（日志里也刷不出来）。关掉浏览器后 `gh` 会把 one-time code 直接打印在终端里，按提示粘贴到 `https://github.com/login/device` 即可。
- Gitea 同理：`gt` 已预装（`gt --version`），但没有任何站点凭证。进入容器后执行 `gt auth login --host https://your.gitea.example --token <token>`（凭证写入 `~/.config/gt/config.yaml`）即可使用 `gt repo list`、`gt issue list`、`gt pr create` 等命令。

## Agent 与 API 接入

### API 提供方

容器支持两个上游，可同时配置：

| 提供方 | 地址 | 凭证 |
| --- | --- | --- |
| DeepSeek 官方 | `https://api.deepseek.com` | `DEEPSEEK_TOKEN` |
| New-API 网关 | `NEW_API_BASE_URL`（默认 `http://192.168.8.228:3000`） | `NEW_API_TOKEN` |

Codex 固定走 **New-API**（直接使用其 `responses` 接口，容器内不再做协议转换）；未设置 `NEW_API_TOKEN` 时跳过 Codex 配置。Reasonix 两个都接入，opencode 默认用 DeepSeek 官方、同时也可选 New-API。

> 网关当前可用 `deepseek-v4-flash`、`deepseek-v4.1-flash` 与 `kimi-k3`（上游为
> `moonshotai/Kimi-K3`）；`kimi-k3` 的文本与图片输入都已实测可用。

### multica

`pixi global` 安装。容器启动时若设置了 `MULTICA_TOKEN`，自动执行：

```bash
multica config set server_url https://api.multica.ai
multica config set app_url https://multica.ai
multica login --token "$MULTICA_TOKEN"
multica daemon start
```

### opencode

启动时写入两份配置：

- `~/.local/share/opencode/auth.json`：写入所有已提供的 provider key（`deepseek`、`newapi`）。
- `~/.config/opencode/opencode.json`：注册自定义 provider `newapi`（`@ai-sdk/openai-compatible`，`baseURL = $NEW_API_BASE_URL/v1`），并设默认模型 `newapi/deepseek-v4-flash`（New-API 网关下的 deepseek）。该 provider 下注册了 `deepseek-v4-flash`、`deepseek-v4.1-flash` 与 `kimi-k3`；`deepseek-v4.1-flash` 用 `"modalities": { "input": ["text","image"] }` 显式声明图片输入能力（opencode 的图片能力只看 `modalities.input`，`attachment: true` 只会打开 `capabilities.attachment`，不会打开 `capabilities.input.image`，两者实测互不替代）。

默认模型 `newapi/deepseek-v4-flash` 走 New-API 网关；想切回 DeepSeek 官方时：

```bash
opencode --model deepseek/deepseek-v4-flash
opencode --model newapi/deepseek-v4.1-flash
opencode --model newapi/kimi-k3
```

或在交互会话里用 `/models` 切换。

### Codex CLI

启动时（`setup_codex_official`）生成：

- `~/.codex/config.toml`：

  ```toml
  model = "deepseek-v4-flash"
  model_provider = "newapi"
  preferred_auth_method = "apikey"
  forced_login_method = "api"
  model_reasoning_effort = "high"
  model_catalog_json = "~/.codex/models.json"
  web_search = "disabled"            # 网关只接受 function 工具
  [model_providers.newapi]
  base_url = "http://192.168.8.228:3000/v1"   # $NEW_API_BASE_URL 自动补 /v1
  wire_api = "responses"
  ```

- `~/.codex/models.json`：模型目录，含 `deepseek-v4-flash`、`deepseek-v4.1-flash` 与 `kimi-k3`（都带 `base_instructions`，兼容 Codex CLI >= 0.144.0）。三个模型都通过 `input_modalities = ["text", "image"]` 显式声明支持图片输入（`kimi-k3` 已实测能看图）。
- 项目 `/home/ubuntu` 默认标记为 `trust_level = "trusted"`。

用法：

```bash
codex                             # 在任意项目目录直接使用（默认 deepseek-v4-flash）
codex -m deepseek-v4.1-flash      # 换用网关上的 deepseek-v4.1-flash
codex -m kimi-k3                  # 换用 Kimi K3
codex -i screenshot.png           # deepseek 两个模型都声明了图片输入能力
```

Codex 经本机的**请求清洗代理**连接 New-API 的 `/v1/responses`（默认
`127.0.0.1:8321`）：

```
codex ──responses──> 127.0.0.1:8321 (codex-responses-filter) ──responses──> New-API
```

代理不做协议转换，只做两件兼容改写：把上游白名单（message / reasoning /
function_call / function_call_output）之外的 item 降级成等价形态；并在请求携带
`previous_response_id` / `item_reference` 时用本地 transcript 展开成完整 item。
其余请求、SSE 响应与错误原样透传；代理起不来时自动回退直连。原因见
[Codex 长会话稳定性](#codex-长会话稳定性)。

Codex 只支持 `responses` 协议，所以未配置 `NEW_API_TOKEN` 时不会生成 Codex 配置；
DeepSeek 官方（只有 `chat/completions`）仍可供 Reasonix / opencode 使用。

### Codex 长会话稳定性

移除 CLIProxyAPI 直连 New-API 后，长会话（尤其跨小时/跨天继续的 Codex 会话）会
偶发整轮失败，错误为：

```
input items may be messages, function calls, function call outputs and reasoning.
Item references need stored responses, which are not kept.
code: unsupported_input_item  (HTTP 400, url: $NEW_API_BASE_URL/v1/responses)
```

实测定位（SIL-1033）：

1. Codex 0.171 的 HTTP responses 请求**不发 `previous_response_id`**，每跳都回放
   全量历史（抓包：`store=false`、`previous_response_id` 缺失）。所以问题不是
   `previous_response_id` 复用，而是历史里的 **item 类型**。
2. `apply_patch` 在 `models.json` 里是 `"apply_patch_tool_type": "freeform"`，对应
   请求 tools 里的 `{"type":"custom","name":"apply_patch"}`；模型用它改文件后，
   历史中会出现 `custom_tool_call` / `custom_tool_call_output`。
3. New-API 的 responses 通道无状态（`store` 被改回 `false`，任何
   `previous_response_id` 都返回 `400 invalid response ID`），它把这两类 item 当成
   “item reference”，要求上游保存过对应 response。会话间隔过长、上游 channel
   切换或响应存储过期后无法解析，于是 400 `unsupported_input_item`；
   Codex 对该错误不降级重试（`will_retry=false`），任务直接失败。
4. 用失败会话 rollout 里的原始 `custom_tool_call` 回放可直接复现同样的 400；把同一
   item 改写成 `function_call` 后返回 200（见 `scripts/test-codex-responses-filter.mjs`）。
5. 同一错误也可能来自其它非白名单 item：Codex 的 `ResponseItem` 还包含
   `local_shell_call`、`compaction` / `context_compaction`（`remote_compaction_v2`
   压缩产物，只有加密内容，跨上游无法解密）、`web_search_call`、
   `image_generation_call`、`tool_search_*`、`additional_tools` 等。上游对这些
   未识别 item 统一回同一句 “Item references need stored responses”，所以不能只
   按错误文本区分来源（另一 vybio 工作区的报错即属此类）。
6. 对 `previous_response_id` / `item_reference` 的核查：Codex 0.171 的 HTTP 请求
   **两者都不发送**（抓包确认；源码里 `previous_response_id` 仅出现在 websocket
   分支，`item_reference` 不在 `ResponseItem` 枚举中）。但只要客户端/版本改成增量
   模式，这类引用就依赖服务端 stored response；New-API 侧 `store=false` 且
   `previous_response_id` 恒 400，因此代理必须能自行展开。

因此容器不恢复完整的 CLIProxyAPI（那是重量级第三方协议转换，且曾需要
`disable-cooling` 来规避单凭据冷却导致的 503），而是在 `entrypoint.sh` 里启动
`scripts/codex-responses-filter.mjs`：

- **白名单降级**：`custom_tool_call`(`_output`) → `function_call`(`_output`)；
  `local_shell_call` → `function_call`；压缩/搜索/图片/未知类型 → 占位 message；
  转换后的 item 去掉依赖服务端存储的 `id`。
- **本地 transcript 重建**：代理按请求头 `session-id` 分会话，缓存每个
  `response.completed` 的 output（response id → output、item id → item，落盘
  JSONL）。请求带 `previous_response_id` 时用缓存的 output 拼回完整 input 并删掉
  该字段；带 `item_reference` 时展开成完整 item；缓存缺失时用占位 message 降级，
  绝不让请求因引用失效而 400。

相关开关：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `CODEX_FILTER` | `on` | `off` 时关闭代理、直连 New-API（旧行为，长会话仍可能失败） |
| `CODEX_FILTER_PORT` | `8321` | 代理端口（仅绑 `127.0.0.1`） |
| `CODEX_FILTER_STATE` | `~/.codex/responses-filter-state.jsonl` | transcript 落盘位置；容器重建后旧会话的引用仍可展开 |

排查：`tail -f /tmp/codex-responses-filter.log`（改写会打印
`session=… rewrote N item(s), expanded M`）。

> 未覆盖：若本地 transcript 也缺失（换容器且状态未持久化），展开会降级为占位
> message —— 请求不会失败，但该段上下文会丢失，需重跑相关步骤。此外 Codex CLI
> 在 Dockerfile 里未固定版本（构建时取 npm 最新），行为可能随版本变化。

### Reasonix

启动时（`setup_reasonix`）写入：

- `~/.reasonix/.env`：`DEEPSEEK_API_KEY`、`NEW_API_KEY`。
- `~/.reasonix/config.toml`：

  ```toml
  default_model = "newapi/deepseek-v4-flash"
  language = "zh"

  [[providers]]                # deepseek 官方
  name = "deepseek"
  base_url = "https://api.deepseek.com"
  models = ["deepseek-v4-flash"]

  [[providers]]                # newapi 网关
  name = "newapi"
  base_url = "$NEW_API_BASE_URL/v1"
  models = ["deepseek-v4-flash", "deepseek-v4.1-flash", "qwen3.8-flash", "kimi-k3"]

  # 显式声明图片输入能力（new-api 的 /v1/models 不带 input_modalities，
  # 不声明就只会被判为 unknown，图片会走 vision_model/OCR 兜底）
  [providers.model_overrides."deepseek-v4.1-flash"]
  vision = true
  ```

用法：

```bash
reasonix                                   # 交互会话
reasonix run "帮我改个 bug"                # 无界面执行
reasonix run --model newapi "..."          # 切到 New-API
reasonix run --model newapi/deepseek-v4.1-flash "..."   # 指定新模型
reasonix run --model newapi/kimi-k3 "..."                # 指定 Kimi K3
reasonix run --model deepseek "..."        # 切到 DeepSeek 官方
```

> `model_overrides` 是 Reasonix 的 per-model 能力覆盖，优先级高于它的自动探测
> （精选预设 / 本地目录 / 在线缓存）。模型 ID 里带 `.`，TOML 点号路径必须写成
> `[providers.model_overrides."deepseek-v4.1-flash"]`，不加引号会被拆成
> `deepseek-v4` 与 `1-flash` 两层。新版 reasonix 2.x 也认 provider 级的
> `vision_models` 字段，模板里两处都写，兼容新旧版本。详见 Reasonix 的
> `docs/MODEL_CAPABILITIES.md`。

可选：`REASONIX_DEFAULT_MODEL` 覆盖默认模型（有 `NEW_API_TOKEN` 时默认 `newapi/deepseek-v4-flash`，否则回退 `deepseek/deepseek-v4-flash`）。

> **bash 沙箱（已启用）**：Reasonix **1.38.8 起权限 preset（read-only / workspace-write）
> 接管 bash 沙箱**，ACP 新会话的 preset 是 `workspace-write`，reasonix 会用
> **bubblewrap** 把每条 bash 关进沙箱；`[sandbox] bash = "off"` 在该版本起不再生效
> （`[desktop] default_tool_approval_mode` / `[bot] tool_approval_mode` 也不作用于 ACP，
> 实测无效）。若容器里 bwrap 起不来，preset 会 **fail closed**，任何 bash 调用都拿不到
> shell。
>
> 因此本容器把沙箱真正跑起来：
> - `Dockerfile` 安装 `bubblewrap`；
> - `docker-compose.yml` 放开 `security_opt: [seccomp=unconfined, apparmor=unconfined]`
>   并 `cap_add: [SYS_ADMIN]` —— Docker 默认 seccomp 拦 `unshare`/`clone(CLONE_NEW*)`、
>   默认 AppArmor 拦 `mount`，缺这三项 bwrap 会报 `Creating new namespace failed` /
>   `Failed to make / slave`。
>
> 这样 reasonix 跟随最新版本，同时保留自身的 bash 沙箱（容器边界 + bwrap 双层）。
> 注意这三项放宽了容器的 seccomp/AppArmor 并多给了 `SYS_ADMIN`；若不需要沙箱，可去掉
> 它们并改用其它方式（如把会话切到 Full access）。
> 若只想快速恢复而暂不改 compose，也可降级到 `reasonix@1.38.7` 并设
> `[sandbox] bash = "off"`（该版本仍认这个设置）。

## 插件

### ponytail（仅 Codex，默认关闭）

[ponytail](https://github.com/DietrichGebert/ponytail) 是一个“lazy senior dev”规则集（MIT）：写代码前逐级判断（YAGNI → 复用已有代码 → 标准库 → 平台原生能力 → 已装依赖 → 一行代码 → 最后才写最小实现）。

- 只给 **Codex** 安装，其他 agent（opencode / Reasonix 等）不安装、不启用，也不写全局规则文件。
- 安装方式：`setup_ponytail` 通过 `codex plugin marketplace add /opt/ponytail` + `codex plugin add ponytail@ponytail`（本地路径 marketplace，完全离线、版本固定）。
- **默认级别 `off`**：`~/.config/ponytail/config.json` 的 `defaultMode` 为 `off`，不注入任何规则。

在命令行临时开启（只影响本次会话）：

```bash
PONYTAIL_DEFAULT_MODE=full codex     # full 级别
PONYTAIL_DEFAULT_MODE=ultra codex    # 更激进
PONYTAIL_DEFAULT_MODE=lite codex     # 更宽松
codex                                # 默认：off
```

取值 `lite` / `full` / `ultra` / `off`。想改容器默认级别：改 `~/.config/ponytail/config.json` 的 `defaultMode`，或在 `.env` 里设 `PONYTAIL_DEFAULT_MODE=full`。

**hooks 信任**：Codex 默认要求交互式 `/hooks` 确认插件 hooks，容器里无法交互，因此 `setup_ponytail` 装好插件后会调用 `scripts/codex-trust-plugin-hooks.mjs`：查询本地 app-server 的 `hooks/list`，把每个 ponytail hook 的 `trusted_hash` 写入 `~/.codex/config.toml` 的 `[hooks.state."<key>"]`（等价于在 `/hooks` 里选 “Trust all and continue”）。因此 `PONYTAIL_DEFAULT_MODE=full codex` 可直接每轮自动注入规则。

> 该 hash 是 hook 定义的内容哈希（事件、matcher、命令模板、timeout、statusMessage 等），插件或 Codex 版本变化时会变。脚本每次启动现算现写，所以始终匹配；若该步骤失败（打印 WARNING），仍可手动 `/hooks`，或临时用 `codex --dangerously-bypass-hook-trust` 绕过。

会话内可用 ponytail 的 skills：`@ponytail`（ruleset）、`@ponytail-review`、`@ponytail-audit`、`@ponytail-debt`、`@ponytail-gain`、`@ponytail-help`。

> 想在项目内以“指令式”方式使用 ponytail（不装插件），把 `/opt/ponytail/AGENTS.md` 复制到项目根即可。Multica workspace 内由平台注入自己的 `AGENTS.md`，容器不会改动它。

## 浏览器（ego-browser）

容器内预装 [ego-browser](https://github.com/iagogfe/ego-lite-linux)（社区 Linux host + Google Chrome），agent 可以直接驱动一个共享浏览器：

```bash
ego-browser nodejs <<'EOF'
const task = await taskSpaces.useOrCreate('打开示例页')
await browser.openOrReuseTab('https://example.com', { wait: true, timeout: 20000 })
console.log(await page.title())
EOF
```

浏览器以 **headed 模式**运行：entrypoint 在容器启动时拉起一个 Xvfb 虚拟显示（`DISPLAY=:99`，屏幕
`1920x1080x24`），ego-linux-host 按默认的 headed 路径启动 Chrome。这样 Chrome 就是真实浏览器——
UA 不含 `HeadlessChrome`、语言/渲染/扩展环境都是真的，闲鱼这类按 UA 做风控的站点会返回正常首页，
而不是“非法访问 / 请使用正常浏览器访问”。上游 ego-lite-linux 按 tag 原样构建，**没有为浏览器身份
打任何补丁**。

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `DISPLAY` | `:99` | Xvfb 显示号；entrypoint 发现该显示已存在时直接复用 |
| `XVFB_SCREEN` | `1920x1080x24` | Xvfb 屏幕尺寸与色深 |
| `LANG` / `LANGUAGE` | `zh_CN.UTF-8` / `zh_CN:zh` | Chrome 界面语言 → `navigator.language(s)` |
| `TZ` | `Asia/Shanghai` | 容器时区，避免 UA / 语言 / 时区互相矛盾 |
| `EGO_HEADLESS` | 未设置（headed） | 设为 `1` 走无头降级：不依赖 Xvfb，但 UA 会带 `HeadlessChrome` |

Xvfb 启动失败只告警，容器照常运行；此时可以设 `EGO_HEADLESS=1` 降级，或自行提供可用的 `DISPLAY`。
headed Chrome 需要更大的 `/dev/shm`，compose 里已设置 `shm_size`。日志在容器内 `/tmp/xvfb.log`。

这层设置只让浏览器以真实浏览器身份工作，用于合法浏览与取数，不用于绕过登录、验证码或访问控制；
遇到验证码按 ego-browser 规范走 `taskSpaces.handOff` 交给用户。

## 数据持久化

compose 配置中设置了三项映射：

- 保留 agent 的 workspace 文件以及 multica 运行时设备信息：
  - 工作空间数据：`./data/multica_workspaces` → 容器 `/home/ubuntu/multica_workspaces`
  - 运行时认证信息：`./data/multica_daemon` → 容器 `/home/ubuntu/.multica`
- opencode 认证文件，避免每次手动配置：
  - 认证信息：`~/.local/share/opencode/auth.json` → 容器内对应位置

## 容器内使用 Docker

compose 将宿主机 Docker socket（`/var/run/docker.sock`）挂载进运行时容器，并在镜像内预装 docker CLI（`docker.io`）与 `docker compose` 插件。

为了让容器内的 `ubuntu` 用户可以直接操作 docker：

- Dockerfile 中已把 `ubuntu` 用户加入镜像内的 `docker` 组。
- compose 通过 `group_add` 把宿主机 docker 组的 GID（`DOCKER_HOST_GID`，默认 `999`）注入容器进程，使容器内所有进程（包括 multica daemon 派生的 agent 进程）都能访问宿主机 docker socket。

首次配置时请确认 `.env` 中的 `DOCKER_HOST_GID` 与宿主机一致，在宿主机上执行以下命令获取真实值：

```bash
stat -c %g /var/run/docker.sock
```

配置正确后，容器内 agent 可直接执行 `docker run`、`docker build`、`docker compose up` 等命令创建和管理容器，无需 sudo。

> 注意：容器内创建的容器是宿主机上的同级容器，并非真正的嵌套运行时。如果宿主机没有 Docker 运行环境，需要先安装 Docker。

## 重置容器

遇到 agent 将容器内软件损坏，或发生意外情况需要重置容器的情况，保持配置不变，执行：

```bash
docker compose down -v && docker compose up -d
```

## 同时多运行时

在不同目录克隆本项目，配置 `.env` 使用不同的 `CONTAINER_NAME`，然后进行首次配置启动，即可在单机上开启不同的运行时。
