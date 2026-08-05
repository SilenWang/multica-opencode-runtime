# multica-opencode-runtime

一个预装了 [multica](https://multica.ai/docs) 和 [opencode](https://opencode.ai) 的容器环境，可快速创建可用的 Runtime 并开始工作 。

## 功能特性

- 预装 pixi 包管理器
- 预装 multica
- 预装 opencode
- 支持 GPU (DRI)
- 已安装 GitHub CLI (gh)
- 预装 Reasonix（含 DeepSeek 官方 API 配置）
- 容器内可直接调用 docker（挂载宿主机 docker socket，支持容器内创建/管理容器）

## 构建命令

```bash
docker-compose build
```

## 启动命令

```bash
docker-compose up -d
```

## 首次配置（重要）

根据`.env.example`填写`.env`，`MULTICA_SERVER_URL`非自部署无需修改。

multica 登录需要在`.env`文件中设置`MULTICA_TOKEN`，需要在multica工作区的`API TOKEN`项目手动生成。TOKEN本身也和运行时编码绑定，手动生成和保存也有助于回复运行时容器。

容器启动后需要登录github和multica，前者使用`docker logs YOU_CONTAINER_NAME_FOR_RUNTIME`来查看日志，获取github给的验证码，然后打开`https://github.com/login/device`进行认证。认证后权限与github网页端完全一致，不用额外进行privte项目和组织权限设置。

### API 密钥配置

支持同时配置多个 provider 的 API key：

- `DEEPSEEK_TOKEN` — DeepSeek API key
- `OPENCODE_GO_TOKEN` — OpenCode Go API key

所有配置的 key 都会写入 opencode `auth.json`，opencode 程序可根据需要选择使用。

### Claude Code 提供商选择

通过 `CLAUDE_PROVIDER` 环境变量选择 Claude Code 使用的后端 API：

- `deepseek`（默认）— 使用 DeepSeek 的 Anthropic 兼容接口
- `opencode-go` — 使用 OpenCode Go 的 API 接口（需设置 `OPENCODE_GO_TOKEN` 和 `OPENCODE_GO_BASE_URL`）

### 可选模型覆盖

可在 `.env` 中设置以下变量覆盖 Claude Code 使用的默认模型名：

- `CLAUDE_OPUS_MODEL` — 默认 `deepseek-v4-pro[1m]`
- `CLAUDE_SONNET_MODEL` — 默认 `deepseek-v4-pro[1m]`
- `CLAUDE_HAIKU_MODEL` — 默认 `deepseek-v4-flash`
- `CLAUDE_SUBAGENT_MODEL` — 默认 `deepseek-v4-flash`

### Reasonix 模型设置

容器启动时使用 `DEEPSEEK_TOKEN` 自动配置 Reasonix 直连 DeepSeek 官方 API，写入 `~/.reasonix/config.toml`（provider 配置）和 `~/.reasonix/.env`（密钥）。

- 默认模型：`deepseek-v4-flash`（provider：`deepseek-flash` / `deepseek-pro`）
- 可选覆盖默认模型名：
  - `REASONIX_DEFAULT_MODEL` — 默认 `deepseek-v4-flash`

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