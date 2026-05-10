# multica-opencode-runtime

一个预装了 multica CLI 和 opencode 的容器环境，可连接 multica 服务进行软件开发工作。

## 功能特性

- 预装 pixi 包管理器
- 预装 multica CLI
- 预装 opencode 全栈编码 Agent
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

容器启动后，需要自行进入容器内部执行以下两个命令来完成配置：

### 1. 配置 multica 服务连接

```bash
multica setup
```

按照提示输入 multica 服务地址和认证信息。

### 2. 登录 GitHub

```bash
gh auth login
```

按照提示完成 GitHub 身份验证。

完成以上配置后，即可正常使用 multica 和 opencode 进行开发工作。

## 进入容器

```bash
docker exec -it multica-runtime bash
```

## 数据持久化

- 工作空间数据：`./data/multica_workspaces` 映射到容器的 `/home/ubuntu/multica_workspaces`
- 认证信息：`~/.local/share/opencode/auth.json` 映射到容器内对应位置