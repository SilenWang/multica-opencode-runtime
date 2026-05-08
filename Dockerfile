FROM ghcr.io/prefix-dev/pixi:0.67.2-noble-cuda-13.0.0

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    git \
    sudo \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.sh | bash

RUN mkdir -p /root/.opencode/bin && \
    curl -fsSL https://opencode.ai/install | bash

RUN chmod +x /root/.local/bin/multica && \
    chmod +x /root/.opencode/bin/opencode

RUN useradd -m -s /bin/bash multica

RUN mkdir -p /home/multica/.multica /home/multica/.opencode && \
    chown -R multica:multica /home/multica

COPY --chown=multica:multica docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER multica
WORKDIR /home/multica

ENV PATH="/root/.local/bin:/root/.opencode/bin:$PATH"
ENV MULTICA_HOME=/home/multica/.multica
ENV OPENCODE_CONFIG_DIR=/home/multica/.opencode

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["bash"]