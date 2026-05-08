FROM ghcr.io/prefix-dev/pixi:0.67.2-noble-cuda-13.0.0

RUN apt-get update && apt-get install -y \
    curl \
    git \
    sudo \
    gh \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.sh | bash

# 给sudo权限，方便后续agent可能要自己安装一些工具
RUN useradd -m -s /bin/bash -G sudo multica 

# 使用ubuntu，因为1000已经被使用 
USER ubuntu
WORKDIR /home/ubuntu

# 创建目录否则映射进来会变成root
RUN pixi global install -c https://prefix.dev/sylens opencode \
    && mkdir -p /home/ubuntu/.local/share/opencode \
    && mkdir -p /home/ubuntu/multica_workspaces
ENV PATH="/home/ubuntu/.pixi/bin:${PATH}"

CMD ["bash"]
