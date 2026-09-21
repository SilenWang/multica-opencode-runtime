FROM ghcr.io/prefix-dev/pixi:0.76.1-noble-cuda-13.0.0

RUN apt-get update && apt-get install -y \
    curl \
    git \
    sudo \
    gh \
    xz-utils \
    docker.io \
    docker-compose-v2 \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL --connect-timeout 10 --max-time 120 \
        https://nodejs.org/dist/v22.23.2/node-v22.23.2-linux-x64.tar.xz \
        -o /tmp/node.tar.xz && \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 && \
    rm /tmp/node.tar.xz
    
# Reasonix 保持不锁版本、跟随最新。1.38.8 起权限 preset 接管 bash 沙箱，ACP 新会话
# 的 preset 被 reasonix 硬编码为 workspace-write（无用户级默认设置），只能由 ACP
# 客户端用 session/set_config_option 切换，而 multica daemon 不发这个请求。
# 容器本身已是隔离边界，容器内再套沙箱多余：用 scripts/reasonix-acp-full-access.mjs
# 作为 ACP 代理，在会话建立时补发 tool_approval=danger-full-access；daemon 通过
# MULTICA_REASONIX_PATH 使用该代理（见文件末尾 ENV）。
RUN npm config set registry https://registry.npmmirror.com && \
    npm config set @tencent-ai:registry https://mirrors.tencent.com/npm/ && \
    npm install -g \
        @openai/codex \
        pnpm \
        reasonix \
    && npm cache clean --force

# 预装 ponytail（lazy senior dev 规则集，MIT），仅由 Codex 使用且默认不开启
# 固定 tag 保证可复现（保留 .git，codex 可用本地路径 marketplace 离线安装插件）
ARG PONYTAIL_VERSION=v4.9.0
RUN git clone --depth 1 --branch ${PONYTAIL_VERSION} \
        https://github.com/DietrichGebert/ponytail.git /opt/ponytail

# CLIProxyAPI：协议转换网关，把 Codex 的 OpenAI `responses` 协议翻译成上游
# （new-api 等）只支持的 `chat/completions`。上游不支持 responses 时由
# entrypoint 在容器内拉起（见 scripts/entrypoint.sh 的 setup_cliproxyapi）。
# 官方安装途径（https://help.router-for.me/introduction/quick-start.html）里的
# 一键脚本会做交互式 systemd 配置、且安装在 sudo 需要密码的 /opt 下，不适用于
# 无人值守的容器构建，因此走同一发布物的固定版本 + SHA256 校验安装。
# 升级时 VERSION 与下面两个 checksum 必须一起改。
ENV CLI_PROXY_API_VERSION=7.2.146
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) \
            asset="linux_amd64"; \
            sha="43e112686b4a5b7b818531144cd695eeaacdd54c46dced87be6fb3967c22e149" ;; \
        arm64) \
            asset="linux_aarch64"; \
            sha="086ae6513aa522bbd1000f4e83e5b5223df6038bd69f1c6cad56619b84c06947" ;; \
        *) \
            echo "CLIProxyAPI: unsupported architecture $(dpkg --print-architecture)" >&2; \
            exit 1 ;; \
    esac; \
    curl -fsSL --connect-timeout 10 --max-time 300 \
        "https://github.com/router-for-me/CLIProxyAPI/releases/download/v${CLI_PROXY_API_VERSION}/CLIProxyAPI_${CLI_PROXY_API_VERSION}_${asset}.tar.gz" \
        -o /tmp/cli-proxy-api.tar.gz; \
    echo "${sha}  /tmp/cli-proxy-api.tar.gz" | sha256sum -c -; \
    mkdir -p /tmp/cli-proxy-api; \
    tar -xzf /tmp/cli-proxy-api.tar.gz -C /tmp/cli-proxy-api; \
    install -m 0755 /tmp/cli-proxy-api/cli-proxy-api /usr/local/bin/cliproxyapi; \
    rm -rf /tmp/cli-proxy-api /tmp/cli-proxy-api.tar.gz; \
    cliproxyapi --help 2>&1 | head -1

# 给unubtu sudo权限，方便后续agent可能要自己安装一些工具
RUN echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu \
    && chmod 0440 /etc/sudoers.d/ubuntu

# 将 ubuntu 用户加入 docker 组，使容器内的 ubuntu 用户可以直接操作 docker
RUN if ! getent group docker > /dev/null 2>&1; then groupadd -r docker; fi \
    && usermod -aG docker ubuntu

# Reasonix ACP 代理：把容器内 reasonix 会话的权限 preset 固定为 Full access
# （容器已是隔离边界，容器内不再套沙箱）。daemon 通过 MULTICA_REASONIX_PATH
# 选用该可执行文件；真实 reasonix 由代理的 REASONIX_REAL_BIN 默认值解析。
# 必须在 USER ubuntu 之前安装并加可执行位：COPY 产物默认 root 所有，
# 切到 ubuntu 后再 chmod 会 EPERM。
COPY scripts/reasonix-acp-full-access.mjs /opt/reasonix-acp-full-access.mjs
RUN chmod 0755 /opt/reasonix-acp-full-access.mjs

# 使用ubuntu，因为1000已经被使用 
USER ubuntu
WORKDIR /home/ubuntu

# 创建目录否则映射进来会变成root
RUN pixi global install -c https://prefix.dev/sylens opencode multica \
    && mkdir -p /home/ubuntu/.local/share/opencode

COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/codex-models.json /codex-models.json
COPY scripts/codex-trust-plugin-hooks.mjs /codex-trust-plugin-hooks.mjs

# 只保留 PATH；ponytail 默认级别由 entrypoint 写入 ~/.config/ponytail/config.json
# （defaultMode=off）。不设全局 PONYTAIL_DEFAULT_MODE，避免覆盖用户在命令行/会话内
# 选择的级别（命令行前缀与 `/ponytail <level>` 优先级更高）。
ENV PATH="/home/ubuntu/.local/bin:/home/ubuntu/.pixi/bin:${PATH}"
# daemon 用该路径作为 reasonix 可执行文件（支持 MULTICA_REASONIX_PATH，见
# server/internal/daemon/agents_probe.go）。
ENV MULTICA_REASONIX_PATH="/opt/reasonix-acp-full-access.mjs"

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]

CMD ["bash"]
