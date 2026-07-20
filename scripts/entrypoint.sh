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
    local base_url="$1" token="$2"
    cat > /home/ubuntu/.claude/settings.json <<- EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "${base_url}",
    "ANTHROPIC_AUTH_TOKEN": "${token}",
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
    write_claude_settings "${OPENCODE_GO_BASE_URL:-https://api.opencode-go.com}" "${OPENCODE_GO_TOKEN}"
elif [ -n "$DEEPSEEK_TOKEN" ]; then
    echo "检测到 DEEPSEEK_TOKEN，写入 claude settings.json"
    mkdir -p /home/ubuntu/.claude
    write_claude_settings "https://api.deepseek.com/anthropic" "${DEEPSEEK_TOKEN}"
fi

# 5. 设置 Codex bridge（将 DeepSeek API 接入 Codex CLI）
setup_codex_bridge() {
    if ! command -v codex-deepseek-bridge &>/dev/null; then
        echo "WARNING: codex-deepseek-bridge not found. Codex bridge setup skipped."
        return
    fi
    export DEEPSEEK_API_KEY="${DEEPSEEK_TOKEN}"
    if [ -n "${DEEPSEEK_API_KEY:-}" ] || [ -f "/home/ubuntu/.codex/codex-deepseek-bridge/deepseek-key" ]; then
        echo "Configuring Codex bridge to use DeepSeek..."
        codex-deepseek-bridge setup --no-start --no-codex-app-install --no-upgrade-check 2>&1 || true
    else
        echo "WARNING: DEEPSEEK_TOKEN not set and no stored key found. Codex bridge not configured."
    fi
}

# 6. 生成 CodeBuddy models.json（接入 DeepSeek 官方 API 和 opencode go）
setup_codebuddy_models() {
    mkdir -p /home/ubuntu/.codebuddy

    local deepseek_key="${DEEPSEEK_TOKEN:-}"
    local opencode_go_key="${OPENCODE_GO_TOKEN:-}"
    local opencode_go_url="${OPENCODE_GO_BASE_URL:-https://api.opencode-go.com}"

    cat > /home/ubuntu/.codebuddy/models.json <<MODELS
{
  "models": [
    {
      "id": "deepseek-v4-pro",
      "name": "DeepSeek V4 Pro",
      "vendor": "DeepSeek",
      "url": "https://api.deepseek.com/v1/chat/completions",
      "apiKey": "${deepseek_key}",
      "maxInputTokens": 128000,
      "maxOutputTokens": 8192,
      "supportsToolCall": true,
      "supportsImages": false,
      "supportsReasoning": true,
      "relatedModels": {
        "lite": "deepseek-v4-flash",
        "reasoning": "deepseek-v4-pro"
      }
    },
    {
      "id": "deepseek-v4-flash",
      "name": "DeepSeek V4 Flash",
      "vendor": "DeepSeek",
      "url": "https://api.deepseek.com/v1/chat/completions",
      "apiKey": "${deepseek_key}",
      "maxInputTokens": 128000,
      "maxOutputTokens": 8192,
      "supportsToolCall": true,
      "supportsImages": false
    },
    {
      "id": "opencode-go",
      "name": "OpenCode Go",
      "vendor": "OpenCode",
      "url": "${opencode_go_url}/v1/chat/completions",
      "apiKey": "${opencode_go_key}",
      "maxInputTokens": 128000,
      "maxOutputTokens": 8192,
      "supportsToolCall": true,
      "supportsImages": false
    }
  ],
  "availableModels": [
    "deepseek-v4-pro",
    "deepseek-v4-flash",
    "opencode-go"
  ]
}
MODELS
    chmod 600 /home/ubuntu/.codebuddy/models.json 2>/dev/null || true
    echo "CodeBuddy models.json configured."
}

setup_codex_bridge
setup_codebuddy_models

# 继续运行
exec "$@"