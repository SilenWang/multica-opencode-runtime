# multica-opencode-runtime

预装了 [Multica](https://multica.ai/docs) 和 [Opencode](https://opencode.ai) 的运行时环境，支持 **Docker 容器** 和 **Ubuntu 原生安装** 两种方式。

## 功能特性

- 预装 pixi 包管理器
- 预装 multica
- 预装 opencode
- 支持 GPU (DRI)
- 已安装 GitHub CLI (gh)
- **Ubuntu 原生安装**：直接从客户端侧完成升级，无需频繁构建容器

---

## 方式一：Ubuntu 原生安装（推荐）

直接在 Ubuntu 上安装 Multica 和 Opencode，客户端侧可以独立升级，避免频繁构建容器。

### 安装

```bash
curl -fsSL https://raw.githubusercontent.com/SilenWang/multica-opencode-runtime/main/install.sh | bash
```

或克隆仓库后本地执行：

```bash
git clone https://github.com/SilenWang/multica-opencode-runtime.git
cd multica-opencode-runtime
chmod +x install.sh
./install.sh
```

### 首次配置

安装完成后，执行以下两个命令完成初始配置：

#### 1. 配置 Multica 服务连接

```bash
multica setup
```

> 需要手动打开浏览器使用链接开始验证，浏览器会跳转到一个 localhost 链接，再手动复制链接，用 curl 访问这个链接以完成认证。

#### 2. 登录 GitHub

```bash
gh auth login
```

> 程序默认会尝试自行启动浏览器来进行认证，请手动粘贴链接到浏览器以完成认证。

### 升级

Ubuntu 原生安装的可直接升级组件：

```bash
# 升级 multica
curl -fsSL https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.sh | bash

# 升级 opencode
pixi global update opencode

# 升级 pixi
pixi self-update
```

---

## 方式二：Docker 容器部署

### 构建命令

```bash
docker-compose build
```

### 启动命令

```bash
docker-compose up -d
```

### 首次配置

容器启动后，需要自行进入容器内部执行以下两个命令来完成配置。

#### 1. 配置 Multica 服务连接

```bash
multica setup
```

> 需要手动打开浏览器使用链接开始验证，浏览器会跳转到一个 localhost 链接，再手动复制链接，容器内 curl 访问这个链接以完成认证。

#### 2. 登录 GitHub

```bash
gh auth login
```

> 程序默认会尝试自行启动浏览器来进行认证，容器内并无浏览器，请手动粘贴链接到浏览器以完成认证。

### 进入容器

```bash
docker exec -it CONTAINER_ID /bin/bash
```

### 数据持久化

compose 配置中设置了两项映射，以保留 agent 的 workspace 文件，同时使用宿主机的 opencode 认证文件，避免手动配置。

- 工作空间数据：`./data/multica_workspaces` 映射到容器的 `/home/ubuntu/multica_workspaces`
- 认证信息：`~/.local/share/opencode/auth.json` 映射到容器内对应位置
