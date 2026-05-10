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

容器启动后，需要自行进入容器内部执行以下两个命令来完成配置。

### 1. 配置 multica 服务连接

```bash
multica setup
```

- 注意：需要手动打开浏览器使用链接开始验证，浏览器会跳转到一个 localhost 链接，再手动复制链接，容器内 curl 访问这个链接以完成认证。

### 2. 登录 GitHub

```bash
gh auth login
```

- 注意：程序默认会尝试自行启动浏览器来进行认证，容器内并无浏览器，请手动粘贴链接到浏览器以完成认证。

完成以上配置后，即可正常使用 multica 和 opencode 进行开发工作。

## 进入容器

```bash
docker exec -it CONTAINER_ID /bin/bash
```

## 数据持久化

compose 配置中设置了两项映射，以保留 agent 的 workspace 文件，同时使用宿主机的 opencode 认证文件，避免手动配置。

- 工作空间数据：`./data/multica_workspaces` 映射到容器的 `/home/ubuntu/multica_workspaces`
- 认证信息：`~/.local/share/opencode/auth.json` 映射到容器内对应位置