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

# 4. 设置 cc
if [ -n "$DEEPSEEK_TOKEN" ]; then
    echo "检测到 DEEPSEEK_TOKEN，写入 claude settings.json"
    mkdir -p /home/ubuntu/.claude
    cat > /home/ubuntu/.claude/settings.json <<- EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "${DEEPSEEK_TOKEN}",
    "ANTHROPIC_MODEL": "deepseek-v4-pro[1m]",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro[1m]",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-pro[1m]",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-flash",
    "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-v4-flash",
    "CLAUDE_CODE_EFFORT_LEVEL": "max"
  }
}
EOF
fi


# 继续运行
exec "$@"