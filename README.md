# multica-opencode-runtime

一个预装了 [multica](https://multica.ai/docs) 和 [opencode](https://opencode.ai) 的容器环境，可快速创建可用的 Runtime 并开始工作 。

## 功能特性

- 基于 pixi 官方镜像（`ghcr.io/prefix-dev/pixi:0.76.1-noble-cuda-13.0.0`，Ubuntu Noble + CUDA 13.0.0），预装 pixi 包管理器
- 预装 multica（自动登录并启动 daemon）
- 预装 opencode
- 预装 Codex CLI（`@openai/codex`，含官方 DeepSeek 集成配置 + OmniRoute sol/luna 模型映射）
- 预装 CodeBuddy CLI（`@tencent-ai/codebuddy-code`）
- 预装 dsh（DeepSeek Harness，`@deepseek-ai/dsh`，含 Multica 运行时 profile）
- 预装 Reasonix（含 DeepSeek 官方 API 配置）
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
- `OPENCODE_GO_TOKEN` — OpenCode Go API key
- `OMNIROUTE_TOKEN` — OmniRoute 网关 API key（配合 `OMNIROUTE_BASE_URL`，默认 `http://192.168.8.228:20128`）

这些 key 会被写入 opencode `auth.json`，并同时用于 Codex（`~/.codex/`）、CodeBuddy（`~/.codebuddy/models.json`）、dsh（`$DSH_HOME/settings.yaml` + `DEEPSEEK_API_KEY`）和 Reasonix（`~/.reasonix/`）的配置，各程序可根据需要选择使用。

### OmniRoute 网关

引入自定义 OmniRoute 网关作为 provider：

- `OMNIROUTE_TOKEN` — OmniRoute API key
- `OMNIROUTE_BASE_URL` — 网关地址，默认 `http://192.168.8.228:20128`
- **Codex** 默认接入 OmniRoute（`wire_api = "responses"`，默认模型 `deepseek-v4-flash`，即 luna）
- **opencode** 将 OmniRoute 作为额外 provider（`omniroute/*`），默认模型仍为 `deepseek/deepseek-v4-flash`
- 未设置 `OMNIROUTE_TOKEN` 时，Codex 回退为 DeepSeek 官方直连

### Codex CLI（默认接入 OmniRoute）

容器启动时优先使用 `OMNIROUTE_TOKEN` 配置 Codex 接入 OmniRoute（`~/.codex/config.toml` + `~/.codex/models.json`，`wire_api = "responses"`），未设置时回退为官方 DeepSeek 集成直连 DeepSeek 官方 API（`wire_api = "responses"`），无需第三方 bridge。

OmniRoute 网关提供两个 DeepSeek 模型，Codex 中模型名映射关系如下：

- `sol` ↔ `deepseek-v4-pro`（pro 档位）
- `luna` ↔ `deepseek-v4-flash`（flash 档位，默认）

- 默认模型：`deepseek-v4-flash`（luna）
- 模型目录 `models.json` 来自官方 DeepSeek 集成脚本（含 `base_instructions` 等字段，兼容 Codex CLI >= 0.144.0）

配置完成后直接在任意项目目录运行 `codex` 即可使用。

### CodeBuddy CLI

容器启动时自动生成 `~/.codebuddy/models.json`，包含四个模型：

- `deepseek-v4-pro` — DeepSeek API
- `deepseek-v4-flash` — DeepSeek API
- `deepseek-v4-flash-omniroute` — OmniRoute 网关（`OMNIROUTE_TOKEN`）
- `opencode-go` — OpenCode Go API（使用 `OPENCODE_GO_TOKEN` 和 `OPENCODE_GO_BASE_URL`）

配置完成后直接在任意项目目录运行 `codebuddy` 即可使用。

### dsh（DeepSeek Harness）

容器启动时自动配置 dsh 接入 DeepSeek 官方 API 和 OmniRoute 网关：

- 全局安装 `@deepseek-ai/dsh`（含 `dsh plugin --profile multica add dsh-profile-multica` 安装的 Multica 运行时 profile）
- 将 `DEEPSEEK_TOKEN` 映射为 `DEEPSEEK_API_KEY`、`OMNIROUTE_TOKEN` 映射为 `OMNIROUTE_API_KEY`（在 daemon 启动前注入）
- 写入 `$DSH_HOME/settings.yaml`（默认 `~/.dsh/settings.yaml`）：
  - `llm-deepseek` — DeepSeek 官方 API，模型 `deepseek-v4-flash` / `deepseek-v4-pro`
  - `llm-pi-ai.providers.omniroute` — OmniRoute 网关（OpenAI-compatible，`api: openai-completions`）
- 配置完成后运行 `dsh --profile multica --probe` 验证注册

模型配置参考 dsh 官方文档：模型在 Web UI 的 Settings → Models 中配置，变更在下一个请求生效、无需重启服务；DeepSeek 卡片只暴露一个 API-key 字段，key 为 write-only，存储在 `$DSH_HOME/.credentials.yaml`（settings 仅保留 credential 引用）；也支持添加 catalog provider（如 Anthropic、OpenAI）或自定义 provider（小写 Provider ID + base URL + API 协议 + 凭证 + 至少一个模型，配置写入 `$DSH_HOME/settings.yaml`）。

使用方式：在任意项目目录运行 `dsh --profile multica --stdio` 对接 Multica 执行任务，或 `dsh web` 开启 Web UI。

### Reasonix 模型设置

容器启动时自动配置 Reasonix 同时接入 DeepSeek 官方和 OmniRoute，写入 `~/.reasonix/.env`（`DEEPSEEK_API_KEY`、`OMNIROUTE_API_KEY`，配置在 GitHub 登录之前）和 `~/.reasonix/config.toml`（provider 配置）。容器内已关闭 Reasonix sandbox（`bash = "off"`），避免缺少 bwrap 导致 bash 命令被拦截。

- providers：
  - `deepseek` — DeepSeek 官方 API，模型 `deepseek-v4-flash` / `deepseek-v4-pro`
  - `omniroute` — OmniRoute 网关，模型 `deepseek-v4-flash` / `deepseek-v4-pro`
- 默认模型：`deepseek/deepseek-v4-flash`
- 可选覆盖默认模型名：
  - `REASONIX_DEFAULT_MODEL` — 默认 `deepseek/deepseek-v4-flash`
- 切换 provider：`reasonix run --model deepseek "<任务>"` 或 `reasonix run --model omniroute "<任务>"`

使用方式：在任意项目目录运行 `reasonix` 开启交互会话，或 `reasonix run "<任务>"` 无界面执行。

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
