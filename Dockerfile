FROM ghcr.io/prefix-dev/pixi:0.76.1-noble-cuda-13.0.0

# fonts-noto-cjk：基础镜像只自带 fonts-liberation（纯拉丁），Chrome/fontconfig 找不到
# CJK 字形，中文网页会整片渲染成方块（tofu）。这里预装 Noto CJK（含 SC/TC/JP/HK/KR）
# 与彩色 emoji 字体。必须在镜像里装：放到 entrypoint 或运行时手动 apt install，
# 容器重建后会丢失。
# fontconfig 必须显式写在这里：fc-cache / fc-list / fc-match 都由 fontconfig 包提供，
# 而 fonts-noto-cjk 没有任何 Depends，基础镜像里是后面 Chrome 的 .deb 才把 fontconfig
# 拉进来的——那时下面的 fc-cache 早已执行，构建会直接 "fc-cache: not found"。
RUN apt-get update && apt-get install -y \
    curl \
    git \
    sudo \
    gh \
    xz-utils \
    docker.io \
    docker-compose-v2 \
    bubblewrap \
    xvfb \
    locales \
    tzdata \
    fontconfig \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
    && (grep -q '^zh_CN.UTF-8 UTF-8$' /etc/locale.gen || echo 'zh_CN.UTF-8 UTF-8' >> /etc/locale.gen) \
    && (grep -q '^en_US.UTF-8 UTF-8$' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen) \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

# fonts-noto-cjk 自带的 70-fonts-noto-cjk.conf 只映射 zh-cn / zh-tw / zh-hk，
# 查询写 lang=zh 时仍会退回拉丁字体，因此补一条通用 zh 的映射并重建缓存；
# 同时在构建期断言字体真的可用，避免"构建成功但中文仍是方块"这类问题拖到运行期才暴露。
COPY scripts/fonts-noto-cjk-zh.conf /etc/fonts/conf.d/71-fonts-noto-cjk-zh.conf
RUN fc-cache -f \
    && test "$(fc-list :lang=zh | wc -l)" -gt 0 \
    && fc-match 'sans-serif:lang=zh' | grep -q 'Noto Sans CJK SC'

# Node 走 npmmirror 镜像（国内构建网络下 nodejs.org 常超时），失败再回退官方源。
RUN curl -fsSL --connect-timeout 10 --max-time 300 \
        https://registry.npmmirror.com/-/binary/node/v22.23.2/node-v22.23.2-linux-x64.tar.xz \
        -o /tmp/node.tar.xz \
    || curl -fsSL --connect-timeout 10 --max-time 300 \
        https://nodejs.org/dist/v22.23.2/node-v22.23.2-linux-x64.tar.xz \
        -o /tmp/node.tar.xz; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 && \
    rm /tmp/node.tar.xz
    
# Reasonix 保持不锁版本、跟随最新。1.38.8 起权限 preset 接管 bash 沙箱：ACP 新会话的
# preset 是 workspace-write，reasonix 会用 bubblewrap 把每条 bash 关进沙箱。容器里
# 因此必须能真正运行 bwrap（见 Dockerfile 的 bubblewrap 依赖与 docker-compose.yml 的
# security_opt / cap_add），否则 preset 会 fail closed，任何 bash 调用都拿不到 shell。
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

# ---------------------------------------------------------------------------
# 可选：浏览器上网能力（ego-browser / ego-lite-linux + Google Chrome，headed + Xvfb）
# ---------------------------------------------------------------------------
# 说明：上游 citrolabs/ego-lite 官方只发 macOS DMG；这里用社区 Linux host
# iagogfe/ego-lite-linux（MIT，MVP v0.2.0），它基于 stock Chromium + CDP，
# 不改内核、不 fork 浏览器，只要求 Node ≥22 与一个 Chrome/Chromium。
# 容器已有 seccomp/apparmor=unconfined + SYS_ADMIN + 可用 userns（bubblewrap
# 所需），Chrome 命名空间沙箱因此可直接工作，无需 --no-sandbox。
# 浏览器走 headed 模式（方案 A）：容器没有真实显示器，由 entrypoint 启动一个
# Xvfb 提供 DISPLAY，ego-linux-host 按默认（headed）路径拉起 Chrome。headed Chrome
# 本身就是真实浏览器：UA 不含 HeadlessChrome、语言/渲染/扩展环境都是真的，因此
# 不需要给上游 ego-lite-linux 打任何补丁，上游代码按 tag 原样构建。
# EGO_HEADLESS=1 仍可作为显式降级（不依赖 Xvfb），只是不再是默认路径。
ARG EGO_LITE_REF=v0.2.0

# Google Chrome（.deb 会带上全部运行库依赖）
RUN arch="$(dpkg --print-architecture)" \
    && sudo install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL --connect-timeout 10 --max-time 120 https://dl.google.com/linux/linux_signing_key.pub \
        | sudo gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg \
    && echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
        | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null \
    && sudo apt-get update \
    && sudo apt-get install -y google-chrome-stable \
    && sudo rm -rf /var/lib/apt/lists/* \
    && google-chrome-stable --version

# ego-lite-linux：构建 ego-browser CLI + host daemon，symlink 到 ~/.local/bin
RUN sudo git clone --depth 1 --branch "${EGO_LITE_REF}" \
        https://github.com/iagogfe/ego-lite-linux.git /opt/ego-lite-linux \
    && sudo chown -R ubuntu:ubuntu /opt/ego-lite-linux \
    && cd /opt/ego-lite-linux \
    && CI=true bash skills/ego-browser/scripts/install-linux.sh --no-doctor \
    && rm -rf /opt/ego-lite-linux/.git \
    && mkdir -p /home/ubuntu/.config/opencode/skills \
    && cp -r /opt/ego-lite-linux/skills/ego-browser /home/ubuntu/.config/opencode/skills/ego-browser \
    && command -v ego-browser \
    && ego-browser --version 2>/dev/null || true

# Xvfb 的显示号固定为 :99，entrypoint 启动时拉起（已存在则复用，见 scripts/entrypoint.sh）。
# LANG/LANGUAGE 让 headed Chrome 以中文界面运行（navigator.language = zh-CN），
# TZ 跟随中国时区，避免 UA / 语言 / 时区互相矛盾；三者都是容器级设置，
# 不依赖任何上游改动。
ENV DISPLAY=:99 \
    LANG=zh_CN.UTF-8 \
    LANGUAGE=zh_CN:zh \
    TZ=Asia/Shanghai

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]

CMD ["bash"]
