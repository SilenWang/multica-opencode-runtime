FROM ghcr.io/prefix-dev/pixi:0.67.2-noble-cuda-13.0.0

RUN apt-get update && apt-get install -y \
    curl \
    git \
    sudo \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.sh | bash

RUN useradd -m -s /bin/bash -u 1000 -G sudo multica

USER multica
WORKDIR /home/multica

CMD ["bash"]
