# multica-opencode-runtime

一个预装了 [multica](https://multica.ai/docs) 和 [opencode](https://opencode.ai) 的容器环境，可快速创建可用的 Runtime 并开始工作 。

## 功能特性

- 预装 pixi 包管理器
- 预装 multica
- 预装 opencode
- 支持 GPU (DRI)
- 已安装 GitHub CLI (gh)

## 使用方式

docker-compose 通过容器名称 `multica-runtime` 自动区分两种场景：

| 场景 | 行为 |
|---|---|
| **首次新建** | 容器不存在，`up -d` 自动创建容器和卷目录 |
| **重建** | 容器已存在，`up -d` 自动复用已有卷数据重建 |

### 首次新建

```bash
docker compose build
docker compose up -d
docker exec -it multica-runtime bash
```

进入容器后执行交互式认证（仅首次需要）：

```bash
multica setup
```
注意：需要手动打开浏览器使用链接开始验证，浏览器会跳转到一个 localhost 链接，再手动复制链接，容器内 curl 访问这个链接以完成认证。

```bash
gh auth login
```
注意：程序默认会尝试自行启动浏览器来进行认证，容器内并无浏览器，请手动粘贴链接到浏览器以完成认证。

### 重建容器（保留配置）

当宿主机更新（如显卡驱动升级）导致容器内 GPU 无法使用时：

```bash
docker compose down
docker compose build --no-cache
docker compose up -d
```

卷中已有的 multica 配置、GitHub 认证、opencode 配置、工作空间数据会全部保留，无需重新认证。

### 进入容器

```bash
docker exec -it multica-runtime bash
```

## 数据持久化

compose 配置中设置了多项卷映射，以保留 agent 的工作空间文件、配置和认证信息，避免重建容器后丢失数据。

| 宿主机路径 | 容器内路径 | 用途 |
|---|---|---|
| `./data/multica_workspaces` | `/home/ubuntu/multica_workspaces` | Agent 工作空间数据 |
| `./data/multica` | `/home/ubuntu/.multica` | Multica 配置及 Agent 运行日志 |
| `./data/opencode` | `/home/ubuntu/.local/share/opencode` | Opencode 配置（含认证信息） |
| `./data/gh` | `/home/ubuntu/.config/gh` | GitHub CLI 认证信息 |