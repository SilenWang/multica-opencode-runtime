# multica-opencode-runtime

一个预装了 [multica](https://multica.ai/docs) 和 [opencode](https://opencode.ai) 的容器环境，可快速创建可用的 Runtime 并开始工作 。

## 功能特性

- 基于 pixi 官方镜像（`ghcr.io/prefix-dev/pixi:0.76.1-noble-cuda-13.0.0`，Ubuntu Noble + CUDA 13.0.0），预装 pixi 包管理器
- 预装 multica（自动登录并启动 daemon）
- 预装 opencode
- 预装 Codex CLI（`@openai/codex`，含官方 DeepSeek / New-API 集成配置）
- 预装 CLIProxyAPI（`cliproxyapi`，为 Codex 做 `responses` ↔ `chat/completions` 协议转换）
- 预装 CodeBuddy CLI（`@tencent-ai/codebuddy-code`）
- 预装 Reasonix（含 DeepSeek 官方 API 配置）
- 预装 ponytail（lazy senior dev 规则集，容器内所有 agent 默认启用，可按会话关闭）
- 预装 Node.js v22（`v22.23.2`）
- 已安装 GitHub CLI (gh)
- 支持 GPU（NVIDIA GPU + DRI）
- 容器内可直接调用 docker（挂载宿主机 docker socket，支持容器内创建/管理容器）
- `ubuntu` 用户拥有免密 sudo 权限，方便 agent 自行安装工具

## 构建命令

```bash
docker-compose build
```

## 启动命令

```bash
docker-compose up -d
```

## 首次配置（重要）

根据`.env.example`填写`.env`。

multica 使用 token 登录：在`.env`中设置`MULTICA_TOKEN`（在 multica 工作区的`API TOKEN`项目手动生成）。容器启动后入口脚本会自动完成 multica 登录（server 固定为 `https://api.multica.ai`）并启动 daemon，无需手动操作。TOKEN本身也和运行时编码绑定，手动生成和保存也有助于恢复运行时容器。

GitHub 需要在容器启动后手动认证：使用`docker logs YOU_CONTAINER_NAME_FOR_RUNTIME`查看日志，获取 github 给的验证码，然后打开`https://github.com/login/device`进行认证。认证后权限与 github 网页端完全一致，不用额外进行 private 项目和组织权限设置。

### API 密钥配置

支持同时配置多个 provider 的 API key：

- `DEEPSEEK_TOKEN` — DeepSeek API key
- `NEW_API_TOKEN` — New-API 网关 API key（配合 `NEW_API_BASE_URL`，默认 `http://192.168.8.228:3000`）

这些 key 会被写入 opencode `auth.json`，并同时用于 Codex（`~/.codex/`）、CodeBuddy（`~/.codebuddy/models.json`）和 Reasonix（`~/.reasonix/`）的配置，各程序可根据需要选择使用。

### Codex CLI（默认接入 New-API）

容器启动时优先使用 `NEW_API_TOKEN` 配置 Codex 接入 New-API 网关（`~/.codex/config.toml` + `~/.codex/models.json`，`wire_api = "responses"`），未设置时回退为官方 DeepSeek 集成直连 DeepSeek 官方 API（`wire_api = "responses"`）。

若所选上游不支持 `responses` 协议（典型如 new-api 网关只提供 `/v1/chat/completions`），容器会自动改走内置的 CLIProxyAPI 桥接，见下节。

- 默认模型：`deepseek-v4-flash`
- 模型目录 `models.json` 来自官方 DeepSeek 集成脚本（含 `base_instructions` 等字段，兼容 Codex CLI >= 0.144.0）
- `deepseek-v4-flash` 已声明多模态输入（`input_modalities` 含 `image`），可直接用 `codex -i <图片>` 附加图片，经 CLIProxyAPI 桥接透传给上游

配置完成后直接在任意项目目录运行 `codex` 即可使用。

### CLIProxyAPI 桥接（上游不支持 responses 协议时）

Codex CLI 只会说 OpenAI 的 `responses` 协议，而 new-api 这类网关只提供 `/v1/chat/completions`（`POST /v1/responses` 返回 404），直连必然失败。镜像内置 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) 做协议转换：

```
codex ──responses──> 127.0.0.1:8317 (CLIProxyAPI) ──chat/completions──> new-api
```

容器启动时 `setup_cliproxyapi` 会：

1. 探测上游 `POST /v1/responses`：404/405/501 明确不支持时启用桥接；上游为 new-api 时 401/403 也启用（其鉴权早于路由匹配）；返回 200 或探测不通时保持原有直连，不改变既有行为；
2. 生成 `~/.cli-proxy-api/config.yaml`（只绑 `127.0.0.1`，上游配在 `openai-compatibility` 下），拉起 `cliproxyapi` 并等 `/v1/models` 就绪（30s 超时，失败则回退直连）；
3. 把 `~/.codex/config.toml` 的 `base_url` 指到 `http://127.0.0.1:8317/v1`，`experimental_bearer_token` 换成桥接自身的 key。

相关环境变量（均有默认值，通常无需设置）：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `CLIPROXY_BRIDGE` | `auto` | `auto` 探测后启用 / `on` 强制启用 / `off` 禁用 |
| `CLIPROXY_PORT` | `8317` | 桥接监听端口（仅 127.0.0.1） |
| `CLIPROXY_HOME` | `/home/ubuntu/.cli-proxy-api` | 配置、auth 目录、日志、pid 所在位置 |
| `CLIPROXY_API_KEY` | 自动生成 | 桥接访问 key，自动生成后持久化在 `$CLIPROXY_HOME/api_key` |
| `CLIPROXY_MODELS` | 跟随上游 | 模型映射 `上游模型名:Codex侧名字`，逗号分隔，省略 `:别名` 时两边同名 |

排查：`tail -f ~/.cli-proxy-api/logs/cliproxyapi.log`，或 `curl -s http://127.0.0.1:8317/v1/models -H "Authorization: Bearer $(cat ~/.cli-proxy-api/api_key)"`。

### CodeBuddy CLI

容器启动时自动生成 `~/.codebuddy/models.json`，包含以下模型：

- `deepseek-v4-flash` — DeepSeek API

配置完成后直接在任意项目目录运行 `codebuddy` 即可使用。

### Reasonix 模型设置

容器启动时自动配置 Reasonix 同时接入 DeepSeek 官方和 New-API，写入 `~/.reasonix/.env`（`DEEPSEEK_API_KEY`、`NEW_API_KEY`，配置在 GitHub 登录之前）和 `~/.reasonix/config.toml`（provider 配置）。容器内已关闭 Reasonix sandbox（`bash = "off"`），避免缺少 bwrap 导致 bash 命令被拦截。

- providers：
  - `deepseek` — DeepSeek 官方 API，模型 `deepseek-v4-flash`
  - `newapi` — New-API 网关，模型 `deepseek-v4-flash` / `qwen3.8-flash`
- 默认模型：`deepseek/deepseek-v4-flash`
- 可选覆盖默认模型名：
  - `REASONIX_DEFAULT_MODEL` — 默认 `deepseek/deepseek-v4-flash`
- 切换 provider：`reasonix run --model deepseek "<任务>"` 或 `reasonix run --model newapi "<任务>"`

使用方式：在任意项目目录运行 `reasonix` 开启交互会话，或 `reasonix run "<任务>"` 无界面执行。

### ponytail（所有 agent 的 lazy senior dev 规则集）

容器预装 [ponytail](https://github.com/DietrichGebert/ponytail)（MIT，固定 tag `v4.9.0` 克隆到 `/opt/ponytail`），理念是让 agent 像"公司里最懒的高级开发"：写最少、最简单的代码——写代码前先逐级判断（YAGNI → 复用已有代码 → 标准库 → 平台原生能力 → 已装依赖 → 一行代码 → 最后才写最小实现）。

容器启动时（`scripts/entrypoint.sh` 的 `setup_ponytail`）自动为所有 agent 启用，无需手动操作：

- **opencode** — 把插件路径合并进已有的全局配置 `~/.config/opencode/opencode.json`（保留 provider 配置），并提供全局规则 `~/.config/opencode/AGENTS.md`
- **Claude Code** — 通过 `claude plugin marketplace add /opt/ponytail` + `claude plugin install ponytail@ponytail` 安装并启用；另有全局 memory `~/.claude/CLAUDE.md` 兜底（未安装 `claude` 时跳过）
- **Codex** — 通过 `codex plugin marketplace add /opt/ponytail` + `codex plugin add ponytail@ponytail` 安装并默认启用；另有全局规则 `~/.codex/AGENTS.md` 兜底（插件 hooks 默认需在 `/hooks` 里手动信任，全局文件保证规则常驻）
- **multica daemon 派生的 agent 及所有进程** — 通过环境变量 `PONYTAIL_DEFAULT_MODE`（Dockerfile `ENV` 默认 `full`）全局生效；插件命令会注入到 Agent 工具派生的 subagent

Claude Code / Codex 的插件 marketplace 直接指向镜像内的 `/opt/ponytail`（固定 tag 的本地 checkout），安装完全离线、版本确定，不依赖启动时网络；相关 CLI 命令均幂等，失败只告警不阻塞（下次启动自动重试）。全局规则文件采用"缺失才写入"，不会覆盖 agent 或用户的本地修改。

#### 在 Codex 中按会话开启 / 关闭

Codex 的 ponytail 由插件（hooks + skills）加一份全局 `~/.codex/AGENTS.md` 共同提供，所以"完全关闭"需要同时避开这两者。`setup_ponytail` 为此准备了一个独立 home 和便捷命令，默认会话与关闭会话可以同时运行：

```bash
codex          # 默认：加载 ponytail（级别由 PONYTAIL_DEFAULT_MODE / config.json 决定）
codex-plain    # 完全不加载 ponytail：独立 CODEX_HOME，无插件、无全局规则
```

`codex-plain` 等价于：

```bash
CODEX_HOME=~/.codex-plain PONYTAIL_DEFAULT_MODE=off codex -p ponytail-off
```

其中 `~/.codex-plain` 只 symlink 了 `~/.codex` 的 provider/models 配置，没有 ponytail 插件、也没有 `AGENTS.md`；`-p ponytail-off` 使用 `~/.codex/ponytail-off.config.toml`（`[plugins."ponytail@ponytail"] enabled = false`）确保插件被禁用。只禁用插件（保留全局规则）也可以用：

```bash
codex -p ponytail-off              # 关掉插件 hooks/skills，但全局 AGENTS.md 规则仍在
PONYTAIL_DEFAULT_MODE=off codex    # 本会话不注入规则，但 ponytail skills 仍可见
```

> 注：若想在某项目内以"指令式"方式使用 ponytail（不装插件），把 `/opt/ponytail/AGENTS.md` 复制到项目根即可。

#### 级别与命令

调整默认级别：在 `.env` 中设置 `PONYTAIL_DEFAULT_MODE`（`lite` / `full` / `ultra` / `off`），或会话内用 `/ponytail <level>` 切换（持久化用 `/ponytail default <level>`）。

常用命令（Claude Code / Codex / opencode 内）：`/ponytail [lite|full|ultra|off]`、`/ponytail-review`、`/ponytail-audit`、`/ponytail-debt`、`/ponytail-gain`、`/ponytail-help`。

> 注：multica 的 workspace 内由平台注入自己的 `AGENTS.md`，容器不会改动它；opencode/Claude 的全局规则文件是额外的兜底层。

## 数据持久化

compose 配置中设置了三项映射：

- 以保留 agent 的 workspace 文件以及 multica 运行时设备信息
    + 工作空间数据：`./data/multica_workspaces` 映射到容器的 `/home/ubuntu/multica_workspaces`
    + 运行时认证信息：`./data/multica_daemon` 映射到容器的 `/home/ubuntu/.multica`

- opencode 认证文件，避免手动配置。
    + 认证信息：`~/.local/share/opencode/auth.json` 映射到容器内对应位置

## 容器内使用 Docker

compose 配置将宿主机 Docker socket（`/var/run/docker.sock`）挂载进运行时容器，并在镜像内预装 docker CLI（`docker.io`）与 `docker compose` 插件。

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

遇到agent将容器内软件损坏，或发生意外情况需要重置容器的情况，保持配置不变，`docker compose down -v && docker compose up -d`即可

## 同时多运行时

在不同目录克隆本项目，配置`.env`使用不同的`CONTAINER_NAME`，然后进行首次配置启动，即可在单机上开启不同的运行时
