# multica-opencode-runtime

一个开箱即用的 Multica Runtime 容器：预装 [multica](https://multica.ai/docs)、[opencode](https://opencode.ai)、Codex CLI、Reasonix 等 agent，并内置 New-API / DeepSeek 的接入与协议转换。构建后填入 `.env` 即可启动一个可用的运行时容器。

## 目录

- [内置组件](#内置组件)
- [构建与启动](#构建与启动)
- [首次配置](#首次配置)
- [Agent 与 API 接入](#agent-与-api-接入)
- [插件](#插件)
- [CLIProxyAPI 桥接](#cliproxyapi-桥接)
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
| Reasonix | 最新 | `npm -g reasonix` | 容器内默认 Full access（ACP 代理，见 [Reasonix](#reasonix) 章节） |
| CLIProxyAPI | 7.2.146 | GitHub Release 固定版本 + SHA256 校验，装到 `/usr/local/bin/cliproxyapi` | Codex 协议转换桥接 |
| ponytail | v4.9.0 | `git clone --depth 1 --branch v4.9.0` → `/opt/ponytail` | 仅 Codex 的插件，默认关闭 |
| gh (GitHub CLI) | 2.45.0 | `apt` | 容器启动时交互式登录 |
| docker CLI | 29.1.3 | `apt docker.io` | 配合挂载的宿主机 docker socket |
| docker compose | 2.40.3 | `apt docker-compose-v2` | |
| curl / git / sudo / xz-utils | - | `apt` | |

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
- GitHub 需在容器启动后手动认证：用 `docker logs YOU_CONTAINER_NAME_FOR_RUNTIME` 查看日志里的验证码，打开 `https://github.com/login/device` 完成认证。认证后权限与 GitHub 网页端一致，无需额外配置私有仓库/组织权限。

## Agent 与 API 接入

### API 提供方

容器支持两个上游，可同时配置：

| 提供方 | 地址 | 凭证 |
| --- | --- | --- |
| DeepSeek 官方 | `https://api.deepseek.com` | `DEEPSEEK_TOKEN` |
| New-API 网关 | `NEW_API_BASE_URL`（默认 `http://192.168.8.228:3000`） | `NEW_API_TOKEN` |

优先级：设置了 `NEW_API_TOKEN` 时 **Codex 默认走 New-API**，否则回退 DeepSeek 官方。Reasonix 两个都接入。opencode 默认用 DeepSeek 官方，同时也可选 New-API。

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
- `~/.config/opencode/opencode.json`：注册自定义 provider `newapi`（`@ai-sdk/openai-compatible`，`baseURL = $NEW_API_BASE_URL/v1`），并设默认模型 `deepseek/deepseek-v4-flash`。

默认模型 `deepseek/deepseek-v4-flash` 走 DeepSeek 官方；想用 New-API 网关时：

```bash
opencode --model newapi/deepseek-v4-flash
```

或在交互会话里用 `/models` 切换。

### Codex CLI

启动时（`setup_codex_official`）生成：

- `~/.codex/config.toml`：

  ```toml
  model = "deepseek-v4-flash"
  model_provider = "newapi"          # 无 NEW_API_TOKEN 时为 deepseek
  preferred_auth_method = "apikey"
  forced_login_method = "api"
  model_reasoning_effort = "high"
  model_catalog_json = "~/.codex/models.json"
  web_search = "disabled"            # 网关只接受 function 工具
  [model_providers.newapi]
  base_url = "http://127.0.0.1:8317/v1"   # 桥接就绪时；否则上游直连地址
  wire_api = "responses"
  ```

- `~/.codex/models.json`：模型目录，当前仅 `deepseek-v4-flash`（含 `base_instructions`，兼容 Codex CLI >= 0.144.0）。
- 项目 `/home/ubuntu` 默认标记为 `trust_level = "trusted"`。

用法：

```bash
codex                       # 在任意项目目录直接使用
codex -i screenshot.png     # deepseek-v4-flash 支持图片输入
```

New-API 上游会经内置的 CLIProxyAPI 桥接（见下节）；DeepSeek 官方则按需探测后决定是否桥接。

### Reasonix

启动时（`setup_reasonix`）写入：

- `~/.reasonix/.env`：`DEEPSEEK_API_KEY`、`NEW_API_KEY`。
- `~/.reasonix/config.toml`：

  ```toml
  default_model = "deepseek/deepseek-v4-flash"
  language = "zh"

  [[providers]]                # deepseek 官方
  name = "deepseek"
  base_url = "https://api.deepseek.com"
  models = ["deepseek-v4-flash"]

  [[providers]]                # newapi 网关
  name = "newapi"
  base_url = "$NEW_API_BASE_URL/v1"
  models = ["deepseek-v4-flash", "qwen3.8-flash"]
  ```

用法：

```bash
reasonix                                   # 交互会话
reasonix run "帮我改个 bug"                # 无界面执行
reasonix run --model newapi "..."          # 切到 New-API
reasonix run --model deepseek "..."        # 切到 DeepSeek 官方
```

可选：`REASONIX_DEFAULT_MODEL` 覆盖默认模型（默认 `deepseek/deepseek-v4-flash`）。

> **bash 沙箱**：Reasonix **1.38.8 起权限 preset（read-only / workspace-write）接管
> bash 沙箱并强制 `enforce`**，`[sandbox] bash = "off"` 不再生效；ACP 新会话的 preset
> 被 reasonix 硬编码为 `workspace-write`，且 reasonix 没有用户级默认设置可以改它
> （`[desktop] default_tool_approval_mode` / `[bot] tool_approval_mode` 都不作用于
> ACP，实测无效）。唯一开关是 ACP 协议里的
> `session/set_config_option {configId: "tool_approval", value: "danger-full-access"}`，
> 而 multica daemon 目前不发这个请求。
>
> 本容器已是隔离边界，容器内无需再套沙箱，因此用
> `scripts/reasonix-acp-full-access.mjs` 作为 ACP 代理：daemon 经
> `MULTICA_REASONIX_PATH` 使用它，它在会话建立时补发 `tool_approval=danger-full-access`
> 再放行会话响应。这样 reasonix 可继续跟随最新版本，且容器内不再因缺 bubblewrap
> 而 fail closed。
>
> **注意**：`resume` 的会话会被 reasonix 按默认 `workspace-write` preset 重建 executor，
> 代理补发也改不动（跨进程 resume 实测一律失败）。所以代理把 `session/resume` /
> `session/load` 改写成 `session/new` —— 每次运行都用新建会话，Full access 才真正生效。
> **代价是不再续接 daemon 的历史会话**（每次运行都是新会话，靠 issue / 评论重建上下文）。
>
> 如果更希望保留会话续接，则需让容器能运行 bubblewrap：安装 `bubblewrap` 并给 compose
> 加 `security_opt: [seccomp=unconfined, apparmor=unconfined]`（Docker 默认 seccomp 拦
> `unshare`/`clone(CLONE_NEW*)`、默认 AppArmor 拦 `mount`），让 reasonix 自身的沙箱
> 可用；也可降级到 `reasonix@1.38.7`（仍认 `[sandbox] bash = "off"`）。

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

## CLIProxyAPI 桥接

Codex CLI 只会说 OpenAI 的 `responses` 协议，而 new-api 网关的 `responses` 支持不完整——非流式探测可能返回 200，但 Codex 实际使用的流式请求会中途断开（`stream closed before response.completed`）。镜像内置 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) 做协议转换：

```
codex ──responses──> 127.0.0.1:8317 (CLIProxyAPI) ──chat/completions──> new-api
```

容器启动时 `setup_cliproxyapi` 会：

1. 决定是否插入桥接：上游为 new-api 时始终启用（不做 200 跳过判断，避免非流式探测误判）；其它上游探测 `POST /v1/responses`，404/405/501/400 明确不支持时启用，其余保持直连；
2. 生成 `~/.cli-proxy-api/config.yaml`（只绑 `127.0.0.1`，上游配在 `openai-compatibility` 下），拉起 `cliproxyapi` 并等 `/v1/models` 就绪（30s 超时，失败则回退直连）；
3. 把 `~/.codex/config.toml` 的 `base_url` 指到 `http://127.0.0.1:8317/v1`，`experimental_bearer_token` 换成桥接自身的 key。

生成的 `config.yaml` 里固定写入 `disable-cooling: true`。桥接只有一条上游凭据，而 CLIProxyAPI 默认会对上游失败做凭据/模型冷却：一次瞬时失败（5xx/超时/断流）就把唯一凭据置入冷却（默认 60s，401/403 为 30m，404 为 12h），冷却期内所有请求直接返回 `503 auth_unavailable: no auth available`。单凭据场景下没有可切换的备用凭据，冷却只是把上游抖动放大成整段黑屏（表现为“用一段时间就 503”）。关闭冷却后，真实的上游错误会直接透传，由 Codex 与 `request-retry` 重试。

相关环境变量（均有默认值，通常无需设置）：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `CLIPROXY_BRIDGE` | `auto` | `auto` 按上游类型启用（new-api 始终启用，其它上游探测后决定）/ `on` 强制启用 / `off` 禁用 |
| `CLIPROXY_PORT` | `8317` | 桥接监听端口（仅 127.0.0.1） |
| `CLIPROXY_HOME` | `/home/ubuntu/.cli-proxy-api` | 配置、auth 目录、日志、pid 所在位置 |
| `CLIPROXY_API_KEY` | 自动生成 | 桥接访问 key，自动生成后持久化在 `$CLIPROXY_HOME/api_key` |
| `CLIPROXY_MODELS` | 跟随上游 | 模型映射 `上游模型名:Codex侧名字`，逗号分隔，省略 `:别名` 时两边同名 |

排查：`tail -f ~/.cli-proxy-api/logs/cliproxyapi.log`，或 `curl -s http://127.0.0.1:8317/v1/models -H "Authorization: Bearer $(cat ~/.cli-proxy-api/api_key)"`。

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
