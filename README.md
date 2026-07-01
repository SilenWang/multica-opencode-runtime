# multica-opencode-runtime

一个预装了 [multica](https://multica.ai/docs) 和 [opencode](https://opencode.ai) 的容器环境，可快速创建可用的 Runtime 并开始工作 。

## 功能特性

- 预装 pixi 包管理器
- 预装 multica
- 预装 opencode
- 支持 GPU (DRI)
- 已安装 GitHub CLI (gh)

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

## 数据持久化

compose 配置中设置了三项映射：

- 以保留 agent 的 workspace 文件以及 multica 运行时设备信息
    + 工作空间数据：`./data/multica_workspaces` 映射到容器的 `/home/ubuntu/multica_workspaces`
    + 运行时认证信息：`./data/multica_daemon` 映射到容器的 `/home/ubuntu/.multica`

- opencode 认证文件，避免手动配置。
    + 认证信息：`~/.local/share/opencode/auth.json` 映射到容器内对应位置

## 重置容器

遇到agent将容器内软件损坏，或发生意外情况需要重置容器的情况，保持配置不变，`docker compose down -v && docker compose up -d`即可

## 同时多运行时

在不同目录克隆本项目，配置`.env`使用不同的`CONTAINER_NAME`，然后进行首次配置启动，即可在单机上开启不同的运行时