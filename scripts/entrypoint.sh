#!/bin/bash
# 遇到错误立即停止运行
set -e

# 1. Multica 登录
echo "准备设置Multica"
if [ -n "$MULTICA_TOKEN" ]; then
    echo "检测到 MULTICA_TOKEN 自动登录 mulitca 并启动"
    multica config set server_url https://api.multica.ai
    multica config set app_url https://multica.ai
    multica login --token ${MULTICA_TOKEN}
    multica daemon start
fi

# 2. Github登录
echo "准备设置 Github"
echo -e "\n\n\n" | gh auth login --hostname github.com -w

# 3. 写入 opencode auth.json（所有可用的 provider key）
echo "写入 opencode auth.json"
mkdir -p /home/ubuntu/.local/share/opencode
AUTH_JSON="{"
FIRST=true
if [ -n "$DEEPSEEK_TOKEN" ]; then
    if [ "$FIRST" = true ]; then FIRST=false; else AUTH_JSON+=", "; fi
    AUTH_JSON+="\"deepseek\": {\"type\": \"api\", \"key\": \"${DEEPSEEK_TOKEN}\"}"
fi
if [ -n "$OPENCODE_GO_TOKEN" ]; then
    if [ "$FIRST" = true ]; then FIRST=false; else AUTH_JSON+=", "; fi
    AUTH_JSON+="\"opencode-go\": {\"type\": \"api\", \"key\": \"${OPENCODE_GO_TOKEN}\"}"
fi
AUTH_JSON+="}"
echo "$AUTH_JSON" > /home/ubuntu/.local/share/opencode/auth.json

# 4. 设置 claude settings.json（根据 CLAUDE_PROVIDER 选择使用哪个 key）
CLAUDE_PROVIDER="${CLAUDE_PROVIDER:-deepseek}"
write_claude_settings() {
    local base_url="$1" auth_token="$2" api_key="$3"
    cat > /home/ubuntu/.claude/settings.json <<- EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "${base_url}",
    "ANTHROPIC_AUTH_TOKEN": "${auth_token}",
    "ANTHROPIC_API_KEY": "${api_key}",
    "ANTHROPIC_MODEL": "${CLAUDE_OPUS_MODEL:-deepseek-v4-pro[1m]}",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "${CLAUDE_OPUS_MODEL:-deepseek-v4-pro[1m]}",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "${CLAUDE_SONNET_MODEL:-deepseek-v4-pro[1m]}",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "${CLAUDE_HAIKU_MODEL:-deepseek-v4-flash}",
    "CLAUDE_CODE_SUBAGENT_MODEL": "${CLAUDE_SUBAGENT_MODEL:-deepseek-v4-flash}",
    "CLAUDE_CODE_EFFORT_LEVEL": "max"
  }
}
EOF
}

if [ "$CLAUDE_PROVIDER" = "opencode-go" ] && [ -n "$OPENCODE_GO_TOKEN" ]; then
    echo "检测到 CLAUDE_PROVIDER=opencode-go，写入 claude settings.json"
    mkdir -p /home/ubuntu/.claude
    write_claude_settings "${OPENCODE_GO_BASE_URL:-https://opencode.ai/zen/go/}" "" "${OPENCODE_GO_TOKEN}"
elif [ -n "$DEEPSEEK_TOKEN" ]; then
    echo "检测到 DEEPSEEK_TOKEN，写入 claude settings.json"
    mkdir -p /home/ubuntu/.claude
    write_claude_settings "https://api.deepseek.com/anthropic" "${DEEPSEEK_TOKEN}"
fi

# 继续运行
exec "$@"