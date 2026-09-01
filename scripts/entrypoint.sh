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
NEW_API_KEY=${NEW_API_TOKEN}
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

[[providers]]
name        = "newapi"
kind        = "openai"
base_url    = "${NEW_API_BASE_URL:-http://192.168.8.228:3000}/v1"
models      = ["deepseek-v4-flash", "deepseek-v4-pro", "qwen3.8-flash"]
api_key_env = "NEW_API_KEY"
REASONIX_CONFIG

    chmod 600 /home/ubuntu/.reasonix/.env /home/ubuntu/.reasonix/config.toml 2>/dev/null || true
    echo "Reasonix integration ready (providers: deepseek + omniroute + newapi, default_model: ${REASONIX_DEFAULT_MODEL:-deepseek/deepseek-v4-flash})."
}

setup_reasonix

# 1.5 配置 dsh（DeepSeek Harness）：DEEPSEEK_API_KEY + settings.yaml（在 daemon 启动前完成）
setup_dsh() {
    if [ -z "${DEEPSEEK_TOKEN:-}" ] && [ -z "${NEW_API_TOKEN:-}" ]; then
        echo "WARNING: Neither DEEPSEEK_TOKEN nor NEW_API_TOKEN set. dsh setup skipped."
        return
    fi

    echo "Configuring dsh (DeepSeek Harness)..."

    # pi-ai 的 thinking-signature patch（让 new_api 命中 reasoning→reasoning_content
    # 映射，修复 thinking 400）已在镜像构建期由 Dockerfile 执行
    # （RUN node /scripts/patch-pi-ai.mjs）；容器运行时 USER ubuntu 对 /usr/local
    # 无写权限，故这里不再尝试写入。
    export DSH_HOME="${DSH_HOME:-/home/ubuntu/.dsh}"
    mkdir -p "${DSH_HOME}"

    # Multica 运行时 profile（镜像构建时已安装；缺失时补装）
    if [ ! -d "${DSH_HOME}/profiles/multica" ]; then
        echo "Installing dsh multica profile..."
        dsh plugin --profile multica add dsh-profile-multica || echo "WARNING: dsh multica profile install failed."
    fi

    # provider 凭证：dsh 通过 apiKeyEnv 从环境变量解析
    if [ -n "${DEEPSEEK_TOKEN:-}" ]; then
        export DEEPSEEK_API_KEY="${DEEPSEEK_TOKEN}"
    fi
    if [ -n "${NEW_API_TOKEN:-}" ]; then
        export NEW_API_KEY="${NEW_API_TOKEN}"
    fi

    # provider 配置写入 $DSH_HOME/settings.yaml（参考 dsh providers 文档：Settings → Models）
    # 注意：所有自定义 provider 必须合并进单一 llm-pi-ai.providers 节点下，
    # 重复的顶层键会导致 DUPLICATE_KEY 使 dsh profile 加载失败（multica 无法检测到 dsh）
    #
    # llm-pi-ai 路由必须显式声明 requiresReasoningContentOnAssistantMessages：
    # thinking mode 下上游要求把历史 assistant 消息的 reasoning_content 回传，而
    # pi-ai 的 openai-completions 适配层按 "model.compat ?? baseURL 指纹识别" 决定
    # 是否回传（@earendil-works/pi-ai dist/api/openai-completions.js:1201 → :924）。
    # 指纹识别里的 isDeepSeek 只在 api.deepseek.com 命中（:1155），本项目的网关走
    # 私有地址（默认 192.168.8.228）识别不到，deepseek-v4-pro 也不在 pi-ai 内置
    # catalog 里 → 开关落为 false → 重放时漏传 → 上游 400 invalid_request_error。
    # llm-deepseek 官方路由不受影响（dsh-llm-deepseek 序列化器无条件带该字段）。
    # 个别网关的 thinking 参数格式不同或不需要回传时，用 .env 里的
    # DSH_PIAI_THINKING_FORMAT / DSH_PIAI_REQUIRES_REASONING_CONTENT 覆盖。
    # reasoningEfforts 是 thinking 能力的开关本身，且 compat 开关的前置条件。
    # dsh 的 resolveModelReasoning（dsh-llm-pi-ai/lib/index.js:537-539）在模型条目未声明
    # reasoningEfforts 时回落到内置 catalog；omniroute / new_api 这类自定义路由名不在
    # catalog 里，于是 reasoning 落为 false。pi-ai 消费上面两个 compat 开关的地方
    # 都带 `&& model.reasoning`（openai-completions.js:586 发 thinking 参数、:924 回传字段），
    # 所以只写 compat 而不声明 reasoningEfforts 是一份永不执行的死配置 ——
    # 表现为 `dsh --list-models` 里这些模型没有 thinking 段。这里逐模型声明档位。
    # 路由 key 决定 model.provider（dsh-llm-pi-ai/lib/index.js:648），而 thinking 报 400
    # 的真正根因在 pi-ai 的回传键名错配（上面两个 compat 开关都治不了）：
    # pi-ai 解析流式响应时把「命中的字段名本身」当 thinkingSignature
    # （openai-completions.js:353-369，reasoningFields = reasoning_content|reasoning|
    # reasoning_text）。本网关用 `reasoning` 字段返回思考 → signature = "reasoning"；
    # 回放时拿 signature 当键名写（:869-876 `assistantMsg[signature] = <thinking 文本>`），
    # 于是真实思考文本落在非标准键 `reasoning` 上，标准键 `reasoning_content` 只剩
    # 上面开关补的空串 —— 与上游「thinking mode 必须回传 reasoning_content」的要求不符。
    # 实测证据取自出错会话的持久化日志（~/.multica/dsh-sessions/.../session.jsonl.zstd）：
    # assistant/message 的 source.replayState.blocks[0] = {type:"reasoning",
    # thinkingSignature:"reasoning"}，provider 为 new_api。离线按同一形状重放
    # （convertMessages）复现出 reasoning=<文本> + reasoning_content="" 的请求体。
    # pi-ai 只在内置 provider 为 opencode-go 时把该 signature 映射回 reasoning_content
    # （解析处 :366、回传处 :870）。本项目自建网关不想改路由名（保持 new_api），因此
    # 在镜像构建期对 pi-ai 打幂等 patch（Dockerfile RUN node /scripts/patch-pi-ai.mjs，
    # 源文件 scripts/patch-pi-ai.mjs）：把这两处特判放宽为 (opencode-go || new_api)。
    # 这是命中上游特判的规避，不是正解 —— 正解需要 dsh/pi-ai 让该映射可配置
    # （见 issue SIL-192）。
    # ⚠ patch 只对**新会话**生效：旧会话历史里记的 provider="new_api" 在新旧配置间
    # 一致（patch 后 isSameModel 成立），但 thinking 块在旧会话里已按旧逻辑降级过；
    # 若之前运行过 opencode-go 命名版本，旧会话里存的是 provider="opencode-go"，
    # 恢复 new_api 后 isSameModel 失配仍会 400 —— 这类旧会话需重开。
    # baseURL 不会被内置 catalog 顶掉（index.js:637 `request.baseURL ?? base?.baseUrl`，配置优先）。
    DSH_PIAI_THINKING_FORMAT="${DSH_PIAI_THINKING_FORMAT:-deepseek}"
    DSH_PIAI_REQUIRES_REASONING_CONTENT="${DSH_PIAI_REQUIRES_REASONING_CONTENT:-true}"
    DSH_PIAI_MODEL_EFFORTS='          reasoningEfforts:
            off: null
            low: low
            high: high
            max: max
'
    {
        printf 'llm-deepseek:\n'
        printf '  apiKeyEnv: DEEPSEEK_API_KEY\n'
        printf '  baseURL: https://api.deepseek.com\n'
        printf '  models:\n'
        printf '    - id: deepseek-v4-flash\n'
        printf '    - id: deepseek-v4-pro\n'
        if [ -n "${NEW_API_TOKEN:-}" ]; then
            printf '\nllm-pi-ai:\n  providers:\n    new_api:\n'
            printf '      apiKeyEnv: NEW_API_KEY\n'
            printf '      api: openai-completions\n'
            printf '      baseURL: "%s/v1"\n' "${NEW_API_BASE_URL:-http://192.168.8.228:3000}"
            printf '      compat:\n'
            printf '        thinkingFormat: %s\n' "${DSH_PIAI_THINKING_FORMAT}"
            printf '        requiresReasoningContentOnAssistantMessages: %s\n' "${DSH_PIAI_REQUIRES_REASONING_CONTENT}"
            printf '      models:\n'
            printf '        - id: deepseek-v4-flash\n'
            printf '%s' "${DSH_PIAI_MODEL_EFFORTS}"
            printf '        - id: deepseek-v4-pro\n'
            printf '%s' "${DSH_PIAI_MODEL_EFFORTS}"
            printf '        - id: qwen3.8-flash\n'
        fi
    } > "${DSH_HOME}/settings.yaml"

    chmod 600 "${DSH_HOME}/settings.yaml" 2>/dev/null || true

    # 守护进程只有在 dsh --profile multica --probe 成功后才注册 DeepSeek Harness
    if dsh --profile multica --probe >/dev/null 2>&1; then
        echo "dsh multica profile probe OK (DeepSeek Harness registered)."
    else
        echo "WARNING: dsh --profile multica --probe failed."
    fi
}

setup_dsh

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
if [ -n "$OMNIROUTE_TOKEN" ]; then
    if [ "$FIRST" = true ]; then FIRST=false; else AUTH_JSON+=", "; fi
    AUTH_JSON+="\"omniroute\": {\"type\": \"api\", \"key\": \"${OMNIROUTE_TOKEN}\"}"
fi
if [ -n "$NEW_API_TOKEN" ]; then
    if [ "$FIRST" = true ]; then FIRST=false; else AUTH_JSON+=", "; fi
    AUTH_JSON+="\"newapi\": {\"type\": \"api\", \"key\": \"${NEW_API_TOKEN}\"}"
fi
AUTH_JSON+="}"
echo "$AUTH_JSON" > /home/ubuntu/.local/share/opencode/auth.json

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
    },
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
        },
        "deepseek-v4-pro": {
          "name": "DeepSeek V4 Pro (New-API)"
        }
      }
    }
  }
}
OPENCODE_JSON
fi

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

    if [ -n "${NEW_API_TOKEN:-}" ]; then
        echo "Configuring Codex to use New-API as the default provider..."
        # New-API 提供两个 deepseek 模型：sol 映射到 pro，luna 映射到 flash；
        # slug 仍为 deepseek 原始型号，默认模型为 luna(flash) 对应的 deepseek-v4-flash
        cat > /home/ubuntu/.codex/config.toml << CODEX_CONFIG_TOML
model = "deepseek-v4-flash"
model_provider = "newapi"
preferred_auth_method = "apikey"
forced_login_method = "api"
model_reasoning_effort = "high"
model_catalog_json = "~/.codex/models.json"
# 因 New API 网关只接受 function 工具，需关闭 Codex 默认开启的 web_search
web_search = "disabled"

[model_providers.newapi]
name = "newapi"
base_url = "${NEW_API_BASE_URL:-http://192.168.8.228:3000}"
wire_api = "responses"
experimental_bearer_token = "${NEW_API_TOKEN}"
CODEX_CONFIG_TOML
        echo "Codex New API integration ready (model: deepseek-v4-flash (luna), sol->pro / luna->flash, wire_api: responses)."
    else
        echo "Configuring Codex with official DeepSeek integration..."
        cat > /home/ubuntu/.codex/config.toml << CODEX_CONFIG_TOML
model = "deepseek-v4-flash"
model_provider = "deepseek"
preferred_auth_method = "apikey"
forced_login_method = "api"
model_reasoning_effort = "high"
model_catalog_json = "~/.codex/models.json"
web_search = "disabled"

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
