#!/bin/bash
# 遇到错误立即停止运行
set -e

echo "准备设置Multica"

# 1. Github登录
echo -e "\n\n\n" | gh auth login --hostname github.com -w

# 2. Multica 登录
if [ -n "$MULTICA_TOKEN" ]; then
    echo "检测到 MULTICA_TOKEN 自动登录 mulitca 并启动"
    multica login --token ${MULTICA_TOKEN}
    multica daemon start
fi
# 3. 写入 opencode auth.json (DEEPSEEK_TOKEN)
if [ -n "$DEEPSEEK_TOKEN" ]; then
    echo "检测到 DEEPSEEK_TOKEN，写入 opencode auth.json"
    mkdir -p /home/ubuntu/.local/share/opencode
    cat > /home/ubuntu/.local/share/opencode/auth.json <<- EOF
{
  "deepseek": {
    "type": "api",
    "key": "${DEEPSEEK_TOKEN}"
  }
}
EOF
fi

# 继续运行
exec "$@"