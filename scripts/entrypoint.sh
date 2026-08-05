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

# 5. 使用官方方式配置 Codex 接入 DeepSeek（config.toml + models.json，不依赖第三方 bridge）
setup_codex_official() {
    if [ -z "${DEEPSEEK_TOKEN:-}" ]; then
        echo "WARNING: DEEPSEEK_TOKEN not set. Codex DeepSeek setup skipped."
        return
    fi

    echo "Configuring Codex with official DeepSeek integration..."
    mkdir -p /home/ubuntu/.codex

    # Write models.json — exact catalog from the official DeepSeek setup script
    # (includes base_instructions, required by Codex CLI >= 0.144.0)
    cp /codex-models.json /home/ubuntu/.codex/models.json

    # Write config.toml
    cat > /home/ubuntu/.codex/config.toml << CODEX_CONFIG_TOML
model = "deepseek-v4-flash"
model_provider = "deepseek"
preferred_auth_method = "apikey"
forced_login_method = "api"
model_reasoning_effort = "high"
model_catalog_json = "~/.codex/models.json"

[model_providers.deepseek]
name = "deepseek"
base_url = "https://api.deepseek.com/"
wire_api = "responses"
experimental_bearer_token = "${DEEPSEEK_TOKEN}"
CODEX_CONFIG_TOML

    chmod 600 /home/ubuntu/.codex/config.toml 2>/dev/null || true
    echo "Codex official DeepSeek integration ready (model: deepseek-v4-flash, wire_api: responses)."
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

# 7. 配置 Reasonix 接入 DeepSeek 官方 API（config.toml + 全局 .env）
setup_reasonix() {
    if [ -z "${DEEPSEEK_TOKEN:-}" ]; then
        echo "WARNING: DEEPSEEK_TOKEN not set. Reasonix DeepSeek setup skipped."
        return
    fi

    echo "Configuring Reasonix with official DeepSeek integration..."
    mkdir -p /home/ubuntu/.reasonix

    # 全局密钥文件 <Reasonix home>/.env，provider 通过 api_key_env 引用
    cat > /home/ubuntu/.reasonix/.env << REASONIX_ENV
DEEPSEEK_API_KEY=${DEEPSEEK_TOKEN}
REASONIX_ENV

    # 用户级 config.toml（~/.reasonix/config.toml），直连 DeepSeek 官方 API
    cat > /home/ubuntu/.reasonix/config.toml << REASONIX_CONFIG
default_model = "${REASONIX_DEFAULT_MODEL:-deepseek-v4-flash}"

[[providers]]
name = "deepseek-flash"
kind = "openai"
base_url = "https://api.deepseek.com"
model = "deepseek-v4-flash"
api_key_env = "DEEPSEEK_API_KEY"

[[providers]]
name = "deepseek-pro"
kind = "openai"
base_url = "https://api.deepseek.com"
model = "deepseek-v4-pro"
api_key_env = "DEEPSEEK_API_KEY"
REASONIX_CONFIG

    chmod 600 /home/ubuntu/.reasonix/.env /home/ubuntu/.reasonix/config.toml 2>/dev/null || true
    echo "Reasonix DeepSeek integration ready (default_model: ${REASONIX_DEFAULT_MODEL:-deepseek-v4-flash})."
}

setup_codex_official
setup_codebuddy_models
setup_reasonix

# 继续运行
exec "$@"
