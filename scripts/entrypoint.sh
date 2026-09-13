#!/bin/bash
# 遇到错误立即停止运行
set -e

# 1. 配置 Reasonix（DEEPSEEK_API_KEY + NEW_API_KEY 写入 ~/.reasonix/.env + config.toml）
setup_reasonix() {
    if [ -z "${DEEPSEEK_TOKEN:-}" ] && [ -z "${NEW_API_TOKEN:-}" ]; then
        echo "WARNING: Neither DEEPSEEK_TOKEN nor NEW_API_TOKEN set. Reasonix setup skipped."
        return
    fi

    echo "Configuring Reasonix (DeepSeek official + New-API)..."
    mkdir -p /home/ubuntu/.reasonix

    # 全局密钥文件 <Reasonix home>/.env，provider 通过 api_key_env 引用
    cat > /home/ubuntu/.reasonix/.env << REASONIX_ENV
DEEPSEEK_API_KEY=${DEEPSEEK_TOKEN}
NEW_API_KEY=${NEW_API_TOKEN}
REASONIX_ENV

    # 用户级 config.toml（~/.reasonix/config.toml），接入 DeepSeek 官方 + New-API
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
models      = ["deepseek-v4-flash"]
default     = "deepseek-v4-flash"
api_key_env = "DEEPSEEK_API_KEY"

[[providers]]
name        = "newapi"
kind        = "openai"
base_url    = "${NEW_API_BASE_URL:-http://192.168.8.228:3000}/v1"
models      = ["deepseek-v4-flash", "qwen3.8-flash"]
api_key_env = "NEW_API_KEY"
REASONIX_CONFIG

    chmod 600 /home/ubuntu/.reasonix/.env /home/ubuntu/.reasonix/config.toml 2>/dev/null || true
    echo "Reasonix integration ready (providers: deepseek + newapi, default_model: ${REASONIX_DEFAULT_MODEL:-deepseek/deepseek-v4-flash})."
}

setup_reasonix

# 3. 写入 opencode auth.json（所有可用的 provider key）
echo "写入 opencode auth.json"
mkdir -p /home/ubuntu/.local/share/opencode
AUTH_JSON="{"
FIRST=true
if [ -n "$DEEPSEEK_TOKEN" ]; then
    if [ "$FIRST" = true ]; then FIRST=false; else AUTH_JSON+=", "; fi
    AUTH_JSON+="\"deepseek\": {\"type\": \"api\", \"key\": \"${DEEPSEEK_TOKEN}\"}"
fi
if [ -n "$NEW_API_TOKEN" ]; then
    if [ "$FIRST" = true ]; then FIRST=false; else AUTH_JSON+=", "; fi
    AUTH_JSON+="\"newapi\": {\"type\": \"api\", \"key\": \"${NEW_API_TOKEN}\"}"
fi
AUTH_JSON+="}"
echo "$AUTH_JSON" > /home/ubuntu/.local/share/opencode/auth.json

echo "写入 opencode.json (newapi 自定义 provider)"
if [ -n "$NEW_API_TOKEN" ]; then
    mkdir -p /home/ubuntu/.config/opencode
    cat > /home/ubuntu/.config/opencode/opencode.json <<OPENCODE_JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "deepseek/deepseek-v4-flash",
  "provider": {
    "newapi": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "New-API",
      "options": {
        "baseURL": "${NEW_API_BASE_URL:-http://192.168.8.228:3000}/v1",
        "apiKey": "${NEW_API_TOKEN}"
      },
      "models": {
        "deepseek-v4-flash": {
          "name": "DeepSeek V4 Flash (New-API)"
        }
      }
    }
  }
}
OPENCODE_JSON
fi

# 3.5 CLIProxyAPI：Codex 的 responses → 上游 chat/completions 协议转换网关
#
# Codex CLI 只会说 OpenAI 的 `responses` 协议，而 new-api 网关只提供
# `/v1/chat/completions`（`/v1/responses` 返回 404），直连必然失败。
# 这里在容器内拉起 CLIProxyAPI：Codex → 127.0.0.1:8317（responses）
# → CLIProxyAPI 转换 → 上游（chat/completions）。
# 用法参考 https://help.router-for.me/agent-client/codex.html
# 与 https://help.router-for.me/configuration/provider/openai-compatibility.html
#
# 开关 CLIPROXY_BRIDGE：
#   auto（默认）—— 探测上游 /v1/responses：404/405/501 明确不支持时启用；上游为
#           上游为 newapi 时 401/403 也启用（其鉴权早于路由匹配）；探测不通时保持直连
#   on  —— 无条件启用
#   off —— 禁用，保持直连
setup_cliproxyapi() {
    CLIPROXY_BRIDGE="${CLIPROXY_BRIDGE:-auto}"
    CLIPROXY_PORT="${CLIPROXY_PORT:-8317}"
    CLIPROXY_HOME="${CLIPROXY_HOME:-/home/ubuntu/.cli-proxy-api}"
    CODEX_BRIDGE_URL=""

    # Codex 的直连上游，与下面 setup_codex_official 的优先级保持一致
    if [ -n "${NEW_API_TOKEN:-}" ]; then
        BRIDGE_UPSTREAM="newapi"
        BRIDGE_BASE_URL="${NEW_API_BASE_URL:-http://192.168.8.228:3000}"
        BRIDGE_TOKEN="${NEW_API_TOKEN}"
        BRIDGE_MODELS_DEFAULT="deepseek-v4-flash,qwen3.8-flash"
    else
        BRIDGE_UPSTREAM="deepseek"
        BRIDGE_BASE_URL="https://api.deepseek.com"
        BRIDGE_TOKEN="${DEEPSEEK_TOKEN:-}"
        BRIDGE_MODELS_DEFAULT="deepseek-v4-flash"
    fi

    if [ "${CLIPROXY_BRIDGE}" = "off" ]; then
        echo "CLIProxyAPI bridge disabled (CLIPROXY_BRIDGE=off); Codex connects to ${BRIDGE_UPSTREAM} directly."
        return
    fi
    if [ -z "${BRIDGE_TOKEN}" ]; then
        echo "CLIProxyAPI bridge skipped: no token for upstream ${BRIDGE_UPSTREAM}."
        return
    fi
    if ! command -v cliproxyapi > /dev/null 2>&1; then
        echo "WARNING: cliproxyapi not installed; Codex will connect to ${BRIDGE_UPSTREAM} directly."
        return
    fi

    # 探测上游是否已经支持 responses 协议；只有明确不支持时才插进桥接
    if [ "${CLIPROXY_BRIDGE}" != "on" ]; then
        local probe_base="${BRIDGE_BASE_URL%/}"
        case "${probe_base}" in
            */v1) : ;;
            *) probe_base="${probe_base}/v1" ;;
        esac
        local probe_code
        probe_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
            -X POST "${probe_base}/responses" \
            -H "Authorization: Bearer ${BRIDGE_TOKEN}" \
            -H 'content-type: application/json' \
            -d "{\"model\":\"$(printf '%s' "${BRIDGE_MODELS_DEFAULT}" | cut -d, -f1)\",\"input\":\"ping\",\"stream\":false}" \
            2>/dev/null) || true
        # 连不上时 curl 自身输出 000
        probe_code="${probe_code:-000}"
        if [ "${BRIDGE_UPSTREAM}" = "newapi" ]; then
            # new-api 是本次要解决的目标上游，只提供 /v1/chat/completions。
            # 它对 POST /v1/responses 的响应不是 404：实测返回 400
            # invalid_request_error（端点存在但拒绝 responses 负载）；鉴权还可能
            # 先于路由返回 401/403。除了明确 200，其余（400/401/403/404/405/501/
            # 000 暂时不可达）都说明直连 responses 不可用，统一走本地桥接；
            # 上游暂时不可达时桥接会自行重试，不影响后续恢复。
            if [ "${probe_code}" = "200" ]; then
                echo "Upstream newapi already serves /v1/responses (HTTP 200); bridge not needed."
                return
            fi
            echo "Upstream newapi does not serve /v1/responses (HTTP ${probe_code}); enabling CLIProxyAPI bridge."
        else
            # 其它上游（如 DeepSeek 官方）只在明确不支持 responses 时桥接，
            # 结论不明（401/403/5xx/网络不通）时保持既有直连行为。
            case "${probe_code}" in
                404|405|501|400)
                    echo "Upstream ${BRIDGE_UPSTREAM} does not serve /v1/responses (HTTP ${probe_code}); enabling CLIProxyAPI bridge." ;;
                *)
                    echo "CLIProxyAPI bridge skipped: /v1/responses probe inconclusive (HTTP ${probe_code})."
                    return ;;
            esac
        fi
    else
        echo "CLIProxyAPI bridge forced on (CLIPROXY_BRIDGE=on) for upstream ${BRIDGE_UPSTREAM}."
    fi

    mkdir -p "${CLIPROXY_HOME}/auth" "${CLIPROXY_HOME}/logs"

    # 桥接自身的访问 key：外部给定优先，否则复用/生成一个（只监听 127.0.0.1）
    if [ -z "${CLIPROXY_API_KEY:-}" ]; then
        if [ -s "${CLIPROXY_HOME}/api_key" ]; then
            CLIPROXY_API_KEY=$(cat "${CLIPROXY_HOME}/api_key")
        else
            CLIPROXY_API_KEY="sk-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        fi
        printf '%s' "${CLIPROXY_API_KEY}" > "${CLIPROXY_HOME}/api_key"
    fi

    # 模型映射：上游真实模型名 -> Codex 侧名字（默认同名，沿用 ~/.codex/models.json）
    # 可用 CLIPROXY_MODELS="upstream:alias,..." 覆盖
    local models_yaml=""
    local entry
    for entry in $(printf '%s' "${CLIPROXY_MODELS:-${BRIDGE_MODELS_DEFAULT}}" | tr ',' ' '); do
        local m_name="${entry%%:*}" m_alias="${entry##*:}"
        models_yaml="${models_yaml}      - name: \"${m_name}\"
        alias: \"${m_alias}\"
"
    done

    cat > "${CLIPROXY_HOME}/config.yaml" << CLIPROXY_CONFIG
# 由 entrypoint.sh 生成，请勿手工编辑（容器重启即覆盖）
host: "127.0.0.1"
port: ${CLIPROXY_PORT}
remote-management:
  allow-remote: false
  secret-key: ""
  disable-control-panel: true
auth-dir: "${CLIPROXY_HOME}/auth"
api-keys:
  - "${CLIPROXY_API_KEY}"
debug: false
logging-to-file: true
logs-max-total-size-mb: 20
usage-statistics-enabled: false
request-retry: 2
max-retry-interval: 10
openai-compatibility:
  - name: "${BRIDGE_UPSTREAM}"
    disabled: false
    base-url: "${BRIDGE_BASE_URL%/}/v1"
    api-key-entries:
      - api-key: "${BRIDGE_TOKEN}"
    models:
${models_yaml}
CLIPROXY_CONFIG
    chmod 600 "${CLIPROXY_HOME}/config.yaml" "${CLIPROXY_HOME}/api_key" 2>/dev/null || true

    # 容器重启时清掉可能残留的旧实例
    if [ -f "${CLIPROXY_HOME}/cliproxyapi.pid" ]; then
        kill "$(cat "${CLIPROXY_HOME}/cliproxyapi.pid")" 2>/dev/null || true
        sleep 1
    fi

    echo "Starting CLIProxyAPI on 127.0.0.1:${CLIPROXY_PORT} (upstream: ${BRIDGE_UPSTREAM})..."
    nohup cliproxyapi --config "${CLIPROXY_HOME}/config.yaml" \
        >> "${CLIPROXY_HOME}/logs/cliproxyapi.log" 2>&1 &
    echo $! > "${CLIPROXY_HOME}/cliproxyapi.pid"

    # 健康检查：/v1/models 能列出桥接模型才算真正起来
    local ready=false
    local _
    for _ in $(seq 1 30); do
        if curl -s --max-time 5 "http://127.0.0.1:${CLIPROXY_PORT}/v1/models" \
                -H "Authorization: Bearer ${CLIPROXY_API_KEY}" 2>/dev/null \
                | grep -q '"id"'; then
            ready=true
            break
        fi
        sleep 1
    done
    if [ "${ready}" != "true" ]; then
        echo "WARNING: CLIProxyAPI did not become ready in 30s; see ${CLIPROXY_HOME}/logs/cliproxyapi.log. Codex falls back to direct ${BRIDGE_UPSTREAM}."
        CODEX_BRIDGE_URL=""
        return
    fi
    CODEX_BRIDGE_URL="http://127.0.0.1:${CLIPROXY_PORT}/v1"
    echo "CLIProxyAPI bridge ready (pid $(cat "${CLIPROXY_HOME}/cliproxyapi.pid"), models: ${CLIPROXY_MODELS:-${BRIDGE_MODELS_DEFAULT}})."
}

setup_cliproxyapi

# 4. 配置 Codex：优先接入 New-API（默认），无 NEW_API_TOKEN 时回退 DeepSeek 官方
setup_codex_official() {
    if [ -z "${DEEPSEEK_TOKEN:-}" ] && [ -z "${NEW_API_TOKEN:-}" ]; then
        echo "WARNING: Neither DEEPSEEK_TOKEN nor NEW_API_TOKEN set. Codex setup skipped."
        return
    fi

    echo "Configuring Codex..."
    mkdir -p /home/ubuntu/.codex

    # Write models.json — exact catalog from the official DeepSeek setup script
    # (includes base_instructions, required by Codex CLI >= 0.144.0)
    cp /codex-models.json /home/ubuntu/.codex/models.json

    # 上游名字与直连地址沿用既有优先级（New-API 优先，否则 DeepSeek 官方）
    local codex_provider codex_direct_url codex_direct_token
    if [ -n "${NEW_API_TOKEN:-}" ]; then
        codex_provider="newapi"
        codex_direct_url="${NEW_API_BASE_URL:-http://192.168.8.228:3000}"
        codex_direct_token="${NEW_API_TOKEN}"
    else
        codex_provider="deepseek"
        codex_direct_url="https://api.deepseek.com/"
        codex_direct_token="${DEEPSEEK_TOKEN}"
    fi

    # 桥接就绪时改走 CLIProxyAPI（responses -> chat/completions 转换），否则直连
    local codex_url="${codex_direct_url}" codex_token="${codex_direct_token}"
    if [ -n "${CODEX_BRIDGE_URL:-}" ]; then
        codex_url="${CODEX_BRIDGE_URL}"
        codex_token="${CLIPROXY_API_KEY}"
    fi

    cat > /home/ubuntu/.codex/config.toml << CODEX_CONFIG_TOML
model = "deepseek-v4-flash"
model_provider = "${codex_provider}"
preferred_auth_method = "apikey"
forced_login_method = "api"
model_reasoning_effort = "high"
model_catalog_json = "~/.codex/models.json"
# 因网关只接受 function 工具，需关闭 Codex 默认开启的 web_search
web_search = "disabled"

[model_providers.${codex_provider}]
name = "${codex_provider}"
base_url = "${codex_url}"
wire_api = "responses"
experimental_bearer_token = "${codex_token}"
CODEX_CONFIG_TOML

    if [ -n "${CODEX_BRIDGE_URL:-}" ]; then
        echo "Codex ready via CLIProxyAPI bridge (model: deepseek-v4-flash, ${codex_provider} -> ${codex_url}, wire_api: responses)."
    else
        echo "Codex ready with direct ${codex_provider} integration (model: deepseek-v4-flash, wire_api: responses)."
    fi

    chmod 600 /home/ubuntu/.codex/config.toml 2>/dev/null || true
}
setup_codex_official

# 2. Multica 登录
echo "准备设置Multica"
if [ -n "$MULTICA_TOKEN" ]; then
    echo "检测到 MULTICA_TOKEN 自动登录 mulitca 并启动"
    multica config set server_url https://api.multica.ai
    multica config set app_url https://multica.ai
    multica login --token ${MULTICA_TOKEN}
    multica daemon start
fi


# 5. Github登录（放最后，避免阻塞前面的自动化配置）
echo "准备设置 Github"
echo -e "\n\n\n" | gh auth login --hostname github.com -w

# 继续运行
exec "$@"
