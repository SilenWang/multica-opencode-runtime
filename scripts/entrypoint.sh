#!/bin/bash
# 遇到错误立即停止运行
set -e

# 1. 配置 Reasonix（DEEPSEEK_API_KEY + OMNIROUTE_API_KEY 写入 ~/.reasonix/.env + config.toml）
setup_reasonix() {
    if [ -z "${DEEPSEEK_TOKEN:-}" ] && [ -z "${OMNIROUTE_TOKEN:-}" ]; then
        echo "WARNING: Neither DEEPSEEK_TOKEN nor OMNIROUTE_TOKEN set. Reasonix setup skipped."
        return
    fi

    echo "Configuring Reasonix (DeepSeek official + OmniRoute)..."
    mkdir -p /home/ubuntu/.reasonix

    # 全局密钥文件 <Reasonix home>/.env，provider 通过 api_key_env 引用
    cat > /home/ubuntu/.reasonix/.env << REASONIX_ENV
DEEPSEEK_API_KEY=${DEEPSEEK_TOKEN}
OMNIROUTE_API_KEY=${OMNIROUTE_TOKEN}
REASONIX_ENV

    # 用户级 config.toml（~/.reasonix/config.toml），接入 DeepSeek 官方 + OmniRoute
    cat > /home/ubuntu/.reasonix/config.toml << REASONIX_CONFIG
config_version = 1
default_model = "${REASONIX_DEFAULT_MODEL:-deepseek/deepseek-v4-flash}"
language = "zh"

# 容器内运行无需再隔离，关闭 sandbox，避免缺少 bwrap 导致 bash 命令被拦截
[sandbox]
bash = "off"

[[providers]]
name        = "deepseek"
kind        = "openai"
base_url    = "https://api.deepseek.com"
models      = ["deepseek-v4-flash", "deepseek-v4-pro"]
default     = "deepseek-v4-flash"
api_key_env = "DEEPSEEK_API_KEY"

[[providers]]
name        = "omniroute"
kind        = "openai"
base_url    = "${OMNIROUTE_BASE_URL:-http://192.168.8.228:20128}/v1"
models      = ["deepseek-v4-flash", "deepseek-v4-pro"]
api_key_env = "OMNIROUTE_API_KEY"
REASONIX_CONFIG

    chmod 600 /home/ubuntu/.reasonix/.env /home/ubuntu/.reasonix/config.toml 2>/dev/null || true
    echo "Reasonix integration ready (providers: deepseek + omniroute, default_model: ${REASONIX_DEFAULT_MODEL:-deepseek/deepseek-v4-flash})."
}

setup_reasonix

# 2. Multica 登录
echo "准备设置Multica"
if [ -n "$MULTICA_TOKEN" ]; then
    echo "检测到 MULTICA_TOKEN 自动登录 mulitca 并启动"
    multica config set server_url https://api.multica.ai
    multica config set app_url https://multica.ai
    multica login --token ${MULTICA_TOKEN}
    multica daemon start
fi

# 3. Github登录
echo "准备设置 Github"
echo -e "\n\n\n" | gh auth login --hostname github.com -w

# 4. 写入 opencode auth.json（所有可用的 provider key）
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
if [ -n "$OMNIROUTE_TOKEN" ]; then
    if [ "$FIRST" = true ]; then FIRST=false; else AUTH_JSON+=", "; fi
    AUTH_JSON+="\"omniroute\": {\"type\": \"api\", \"key\": \"${OMNIROUTE_TOKEN}\"}"
fi
AUTH_JSON+="}"
echo "$AUTH_JSON" > /home/ubuntu/.local/share/opencode/auth.json

# 4b. opencode 自定义 provider 配置（opencode.json 中定义 omniroute 的 baseURL 和模型）
#     deepseek 仍作为 opencode 默认模型；omniroute 仅作为额外 provider 可选
echo "写入 opencode.json (omniroute 自定义 provider)"
if [ -n "$OMNIROUTE_TOKEN" ]; then
    mkdir -p /home/ubuntu/.config/opencode
    cat > /home/ubuntu/.config/opencode/opencode.json <<OPENCODE_JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "deepseek/deepseek-v4-flash",
  "provider": {
    "omniroute": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "OmniRoute",
      "options": {
        "baseURL": "${OMNIROUTE_BASE_URL:-http://192.168.8.228:20128}/v1",
        "apiKey": "${OMNIROUTE_TOKEN}"
      },
      "models": {
        "deepseek-v4-flash": {
          "name": "DeepSeek V4 Flash (OmniRoute)"
        },
        "deepseek-v4-pro": {
          "name": "DeepSeek V4 Pro (OmniRoute)"
        },
        "auto/coding": {
          "name": "OmniRoute Auto Coding"
        }
      }
    }
  }
}
OPENCODE_JSON
fi

# 5. 配置 Codex：优先接入 OmniRoute（默认），无 OMNIROUTE_TOKEN 时回退 DeepSeek 官方
setup_codex_official() {
    if [ -z "${DEEPSEEK_TOKEN:-}" ] && [ -z "${OMNIROUTE_TOKEN:-}" ]; then
        echo "WARNING: Neither DEEPSEEK_TOKEN nor OMNIROUTE_TOKEN set. Codex setup skipped."
        return
    fi

    echo "Configuring Codex..."
    mkdir -p /home/ubuntu/.codex

    # Write models.json — exact catalog from the official DeepSeek setup script
    # (includes base_instructions, required by Codex CLI >= 0.144.0)
    cp /codex-models.json /home/ubuntu/.codex/models.json

    if [ -n "${OMNIROUTE_TOKEN:-}" ]; then
        echo "Configuring Codex to use OmniRoute as the default provider..."
        # OmniRoute 提供两个 deepseek 模型：sol 映射到 pro，luna 映射到 flash；
        # slug 仍为 deepseek 原始型号，默认模型为 luna(flash) 对应的 deepseek-v4-flash
        cat > /home/ubuntu/.codex/config.toml << CODEX_CONFIG_TOML
model = "deepseek-v4-flash"
model_provider = "omniroute"
preferred_auth_method = "apikey"
forced_login_method = "api"
model_reasoning_effort = "high"
model_catalog_json = "~/.codex/models.json"

[model_providers.omniroute]
name = "omniroute"
base_url = "${OMNIROUTE_BASE_URL:-http://192.168.8.228:20128}/v1"
wire_api = "responses"
experimental_bearer_token = "${OMNIROUTE_TOKEN}"
CODEX_CONFIG_TOML
        echo "Codex OmniRoute integration ready (model: deepseek-v4-flash (luna), sol->pro / luna->flash, wire_api: responses)."
    else
        echo "Configuring Codex with official DeepSeek integration..."
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
        echo "Codex official DeepSeek integration ready (model: deepseek-v4-flash, wire_api: responses)."
    fi

    chmod 600 /home/ubuntu/.codex/config.toml 2>/dev/null || true
}
setup_codex_official

# 继续运行
exec "$@"
