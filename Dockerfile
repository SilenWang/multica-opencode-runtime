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
    
RUN npm install -g @openai/codex && \
    npm install -g @tencent-ai/codebuddy-code && \
    npm install -g @deepseek-ai/dsh@0.1.0-rc.7 && \
    npm install -g pnpm && \
    npm install -g reasonix && \
    npm cache clean --force

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

# 为 dsh（DeepSeek Harness）安装 Multica 运行时 profile
# （daemon 只有在 dsh --profile multica --probe 成功后才注册 DeepSeek Harness）
RUN dsh plugin --profile multica add dsh-profile-multica

COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/codex-models.json /codex-models.json

ENV PATH="/home/ubuntu/.local/bin:/home/ubuntu/.pixi/bin:${PATH}"

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]

CMD ["bash"]
