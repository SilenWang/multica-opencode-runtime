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
    
RUN npm config set registry https://registry.npmmirror.com && \
    npm config set @tencent-ai:registry https://mirrors.tencent.com/npm/ && \
    npm install -g \
        @openai/codex \
        pnpm \
        reasonix \
    && npm cache clean --force

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

# 使用ubuntu，因为1000已经被使用 
USER ubuntu
WORKDIR /home/ubuntu

# 创建目录否则映射进来会变成root
RUN pixi global install -c https://prefix.dev/sylens opencode multica \
    && mkdir -p /home/ubuntu/.local/share/opencode

COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/codex-models.json /codex-models.json

ENV PATH="/home/ubuntu/.local/bin:/home/ubuntu/.pixi/bin:${PATH}"

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]

CMD ["bash"]
