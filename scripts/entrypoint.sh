#!/bin/bash
# 遇到错误立即停止运行
set -e

# 0. 虚拟显示（方案 A：headed Chrome）
#
# 容器没有真实显示器，ego-browser 的 host 默认以 headed 模式启动 Chrome，需要
# DISPLAY。这里用 Xvfb 提供一个虚拟 X11 屏幕：headed Chrome 就是真实浏览器，
# UA / 渲染 / 语言环境都正常，不需要给上游 ego-lite-linux 打任何补丁。
# 外部已经提供可用显示时直接复用；启动失败只告警，可在 .env 设 EGO_HEADLESS=1
# 走无头降级（无头模式不需要 DISPLAY）。
setup_xvfb() {
    local display="${DISPLAY:-:99}"
    local num="${display#:}"
    num="${num%%.*}"

    if [ -n "${num}" ] && [ -S "/tmp/.X11-unix/X${num}" ]; then
        echo "X display ${display} 已存在，复用。"
        export DISPLAY="${display}"
        return 0
    fi

    if ! command -v Xvfb > /dev/null 2>&1; then
        echo "WARNING: Xvfb 未安装，Chrome 无法以 headed 模式启动；可设 EGO_HEADLESS=1 降级。"
        return 0
    fi

    echo "启动 Xvfb ${display} (${XVFB_SCREEN:-1920x1080x24})..."
    Xvfb "${display}" -screen 0 "${XVFB_SCREEN:-1920x1080x24}" -nolisten tcp > /tmp/xvfb.log 2>&1 &
    local pid=$!
    local i
    for i in $(seq 1 50); do
        if [ -S "/tmp/.X11-unix/X${num}" ]; then
            export DISPLAY="${display}"
            echo "Xvfb 已就绪：DISPLAY=${display} (pid ${pid}, log /tmp/xvfb.log)"
            return 0
        fi
        if ! kill -0 "${pid}" 2> /dev/null; then
            break
        fi
        sleep 0.1
    done

    echo "WARNING: Xvfb 启动失败（详见 /tmp/xvfb.log）；可设 EGO_HEADLESS=1 降级。" >&2
    return 0
}

# 1. 配置 Reasonix（DEEPSEEK_API_KEY + NEW_API_KEY 写入 ~/.reasonix/.env + config.toml）
setup_reasonix() {
    if [ -z "${DEEPSEEK_TOKEN:-}" ] && [ -z "${NEW_API_TOKEN:-}" ]; then
        echo "WARNING: Neither DEEPSEEK_TOKEN nor NEW_API_TOKEN set. Reasonix setup skipped."
        return
    fi

    echo "Configuring Reasonix (DeepSeek official + New-API)..."
    mkdir -p /home/ubuntu/.reasonix

    # 默认模型：有 NEW_API_TOKEN 时用 New-API 网关下的 deepseek，否则回退 DeepSeek
    # 官方。这样默认链路不依赖 DEEPSEEK_TOKEN 是否有效（它对官方直连是硬依赖）。
    local reasonix_default_model="${REASONIX_DEFAULT_MODEL:-}"
    if [ -z "${reasonix_default_model}" ]; then
        if [ -n "${NEW_API_TOKEN:-}" ]; then
            reasonix_default_model="newapi/deepseek-v4-flash"
        else
            reasonix_default_model="deepseek/deepseek-v4-flash"
        fi
    fi

    # 全局密钥文件 <Reasonix home>/.env，provider 通过 api_key_env 引用
    cat > /home/ubuntu/.reasonix/.env << REASONIX_ENV
DEEPSEEK_API_KEY=${DEEPSEEK_TOKEN}
NEW_API_KEY=${NEW_API_TOKEN}
REASONIX_ENV

    # 用户级 config.toml（~/.reasonix/config.toml），接入 DeepSeek 官方 + New-API
    cat > /home/ubuntu/.reasonix/config.toml << REASONIX_CONFIG
config_version = 1
default_model = "${reasonix_default_model}"
language = "zh"

# 不再覆盖 [sandbox]：容器已是隔离边界，容器内 reasonix 无需再套沙箱。reasonix
# 1.38.8 起权限 preset 接管 bash 沙箱，ACP 会话默认 workspace-write 且没有用户级
# 默认设置；由 /opt/reasonix-acp-full-access.mjs（daemon 经 MULTICA_REASONIX_PATH
# 选用）在会话建立时补发 tool_approval=danger-full-access，详见 Dockerfile。

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
models      = ["deepseek-v4-flash", "deepseek-v4.1-flash", "qwen3.8-flash", "kimi-k3"]
api_key_env = "NEW_API_KEY"
# Reasonix 2.x 的 provider 级图片能力声明；旧版 reasonix 不认这个字段，
# 继续用下面的 model_overrides（两处都写，兼容两代）。
vision_models = ["deepseek-v4.1-flash", "kimi-k3"]

# 显式声明支持图片输入。new-api 的 /v1/models 不返回 input_modalities，
# Reasonix 只能把模型判为 unknown，图片会走 vision_model/OCR 兜底而不是原生
# 多模态；model_overrides 是 Reasonix 的 per-model 能力覆盖，优先级高于自动
# 探测与缓存（见 Reasonix docs/MODEL_CAPABILITIES.md）。
# 模型 ID 里含 "."，TOML 点号路径必须加引号，否则会被拆成 deepseek-v4 与 1-flash。
[providers.model_overrides."deepseek-v4.1-flash"]
vision = true

[providers.model_overrides."kimi-k3"]
vision = true
REASONIX_CONFIG

    chmod 600 /home/ubuntu/.reasonix/.env /home/ubuntu/.reasonix/config.toml 2>/dev/null || true
    echo "Reasonix integration ready (providers: deepseek + newapi, default_model: ${reasonix_default_model})."
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
  "model": "newapi/deepseek-v4-flash",
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
        },
        "deepseek-v4.1-flash": {
          "name": "DeepSeek V4.1 Flash (New-API)",
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          }
        },
        "kimi-k3": {
          "name": "Kimi K3 (New-API)",
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          }
        }
      }
    }
  }
}
OPENCODE_JSON
fi

# 4. Codex responses 请求清洗代理（SIL-1033）
#
# Codex 0.171 会用全量历史回放会话，apply_patch 这类 freeform 工具产生的
# `custom_tool_call` / `custom_tool_call_output` item 会留在历史里。New-API 的
# responses 通道是无状态的（store 被强制为 false，previous_response_id 一律
# 400），只能靠上游保存过的 response 解析这类 item；会话间隔过长、channel
# 切换或上游存储过期后，就会返回
#   "Item references need stored responses, which are not kept"
# （code=unsupported_input_item），而 Codex 不会降级重试，任务直接失败。
#
# 同一错误也可能来自其它非白名单 item（local_shell_call、远程压缩产生的
# compaction/context_compaction、web_search_call 等），或来自
# previous_response_id / item_reference 这类需要服务端 stored response 的引用。
# 因此代理做两件事：
#   1) 用本地 transcript（缓存的 response output）展开 previous_response_id 与
#      item_reference；缓存缺失时安全降级（删字段/换成占位 message），不让请求 400；
#   2) 把白名单（message/reasoning/function_call/function_call_output）之外的
#      item 降级成 function 或占位 message。
# 其余请求、SSE 响应与错误全部原样透传；代理起不来时回退直连，不阻塞启动。
#
# 开关 CODEX_FILTER：on（默认）/ off；端口 CODEX_FILTER_PORT（默认 8321）；
# transcript 落盘 CODEX_FILTER_STATE（默认 ~/.codex/responses-filter-state.jsonl）。
CODEX_FILTER_URL=""
setup_codex_responses_filter() {
    CODEX_FILTER_PORT="${CODEX_FILTER_PORT:-8321}"
    if [ "${CODEX_FILTER:-on}" != "on" ]; then
        echo "Codex responses filter disabled (CODEX_FILTER=${CODEX_FILTER})."
        return
    fi
    if [ -z "${NEW_API_TOKEN:-}" ]; then
        return
    fi
    if ! command -v node > /dev/null 2>&1 || [ ! -f /codex-responses-filter.mjs ]; then
        echo "WARNING: node or /codex-responses-filter.mjs missing; Codex connects to New-API directly."
        return
    fi

    # 容器重启时清掉可能残留的旧实例
    if [ -f /tmp/codex-responses-filter.pid ]; then
        kill "$(cat /tmp/codex-responses-filter.pid)" 2>/dev/null || true
        rm -f /tmp/codex-responses-filter.pid
        sleep 1
    fi

    local filter_log="/tmp/codex-responses-filter.log"
    local filter_state="${CODEX_FILTER_STATE:-/home/ubuntu/.codex/responses-filter-state.jsonl}"
    mkdir -p "$(dirname "${filter_state}")"
    echo "Starting Codex responses filter on 127.0.0.1:${CODEX_FILTER_PORT} (state: ${filter_state})..."
    CODEX_FILTER_PORT="${CODEX_FILTER_PORT}" \
    CODEX_FILTER_UPSTREAM="${NEW_API_BASE_URL:-http://192.168.8.228:3000}" \
    CODEX_FILTER_TOKEN="${NEW_API_TOKEN}" \
    CODEX_FILTER_STATE="${filter_state}" \
        nohup node /codex-responses-filter.mjs >> "${filter_log}" 2>&1 &
    echo $! > /tmp/codex-responses-filter.pid

    local i
    for i in $(seq 1 20); do
        if curl -fsS --max-time 2 "http://127.0.0.1:${CODEX_FILTER_PORT}/healthz" > /dev/null 2>&1; then
            CODEX_FILTER_URL="http://127.0.0.1:${CODEX_FILTER_PORT}/v1"
            echo "Codex responses filter ready (pid $(cat /tmp/codex-responses-filter.pid), log ${filter_log})."
            return
        fi
        sleep 1
    done

    echo "WARNING: Codex responses filter did not become ready in 20s; see ${filter_log}. Codex connects to New-API directly."
    kill "$(cat /tmp/codex-responses-filter.pid)" 2>/dev/null || true
    rm -f /tmp/codex-responses-filter.pid
}
setup_codex_responses_filter

# 5. 配置 Codex：经本地清洗代理连接 New-API 的 /v1/responses
#
# Codex CLI 只支持 OpenAI 的 responses 协议（chat wire_api 已在 0.x 移除），
# 因此需要一个直接提供 /v1/responses 的上游。New-API 已支持 responses 直连；
# DeepSeek 官方只有 chat/completions，不能作为 Codex 的直连上游（Reasonix /
# opencode 仍可正常使用它）。未配置 NEW_API_TOKEN 时跳过 Codex 配置。
setup_codex_official() {
    if [ -z "${NEW_API_TOKEN:-}" ]; then
        echo "WARNING: NEW_API_TOKEN not set; Codex setup skipped (Codex requires a responses-capable upstream such as New-API)."
        return
    fi

    echo "Configuring Codex..."
    mkdir -p /home/ubuntu/.codex

    # Write models.json — exact catalog from the official DeepSeek setup script
    # (includes base_instructions, required by Codex CLI >= 0.144.0)
    cp /codex-models.json /home/ubuntu/.codex/models.json

    # 清洗代理已监听 127.0.0.1 时直接用它；否则保持直连 New-API。
    # Codex 会在 base_url 后拼接 /responses，直连时要补到 /v1。
    local codex_base_url
    if [ -n "${CODEX_FILTER_URL}" ]; then
        codex_base_url="${CODEX_FILTER_URL}"
    else
        codex_base_url="${NEW_API_BASE_URL:-http://192.168.8.228:3000}"
        codex_base_url="${codex_base_url%/}"
        case "${codex_base_url}" in
            */v1) : ;;
            *) codex_base_url="${codex_base_url}/v1" ;;
        esac
    fi

    cat > /home/ubuntu/.codex/config.toml << CODEX_CONFIG_TOML
model = "deepseek-v4-flash"
model_provider = "newapi"
preferred_auth_method = "apikey"
forced_login_method = "api"
model_reasoning_effort = "high"
model_catalog_json = "~/.codex/models.json"
# 因网关只接受 function 工具，需关闭 Codex 默认开启的 web_search
web_search = "disabled"

[model_providers.newapi]
name = "newapi"
base_url = "${codex_base_url}"
wire_api = "responses"
experimental_bearer_token = "${NEW_API_TOKEN}"
CODEX_CONFIG_TOML

    echo "Codex ready (model: deepseek-v4-flash, base_url: ${codex_base_url}, responses filter: ${CODEX_FILTER_URL:-off})."
    chmod 600 /home/ubuntu/.codex/config.toml 2>/dev/null || true
}
setup_codex_official

# 8. 配置 ponytail（lazy senior dev 规则集），仅 Codex 使用，默认不开启
# 依赖 /opt/ponytail（Dockerfile 中按固定 tag 克隆）。只给 Codex 装插件，不写
# 任何全局规则文件；默认级别 off，需要时由用户通过命令行开启（见 README）。
# 需在 codex config.toml 写入之后执行，避免被覆盖。任何失败仅告警，下次启动重试。
setup_ponytail() {
    local ponytail_dir="/opt/ponytail"
    if [ ! -d "${ponytail_dir}" ]; then
        echo "WARNING: ${ponytail_dir} not found. ponytail setup skipped."
        return
    fi

    # 默认级别 off：插件装好但不激活。只在文件缺失时写入，保留用户改动。
    # 不设全局 PONYTAIL_DEFAULT_MODE，让命令行前缀（PONYTAIL_DEFAULT_MODE=full
    # codex）和会话内 `/ponytail <level>` 都能正常覆盖。
    mkdir -p /home/ubuntu/.config/ponytail
    if [ ! -f /home/ubuntu/.config/ponytail/config.json ]; then
        printf '{\n  "defaultMode": "off"\n}\n' \
            > /home/ubuntu/.config/ponytail/config.json
    fi

    # 仅 Codex：本地路径 marketplace（指向镜像内固定 tag 的 checkout，离线、版本确定）。
    # 装好后默认 off；开启方式见 README（PONYTAIL_DEFAULT_MODE=full codex）。
    if command -v codex >/dev/null 2>&1; then
        # codex 要求 CODEX_HOME 已存在；无 token 时 setup_codex_official 会提前返回
        mkdir -p /home/ubuntu/.codex
        if codex plugin marketplace add "${ponytail_dir}" >/dev/null 2>&1 \
            && codex plugin add ponytail@ponytail >/dev/null 2>&1; then
            echo "Codex: ponytail plugin installed (default: off)."
            # 非交互式信任插件的 lifecycle hooks：Codex 默认要求交互式 `/hooks`
            # 确认，容器里做不到。改为查询本地 app-server 的 `hooks/list`，把每个
            # hook 的 trusted_hash 写进 config.toml 的 [hooks.state]，等价于在
            # `/hooks` 里选 "Trust all and continue"。失败仅告警，用户仍可手动确认。
            if ! node /codex-trust-plugin-hooks.mjs "ponytail@" "/home/ubuntu"; then
                echo "WARNING: non-interactive ponytail hook trust failed; run /hooks in codex once if needed."
            fi
        else
            echo "WARNING: Codex ponytail plugin install failed; retry on next start."
        fi
    else
        echo "WARNING: codex not found; ponytail plugin not installed."
    fi
}

setup_ponytail

# 9. BioMCP：把镜像里预装的 biomcp 注册成三个 agent 共用的 stdio MCP server
#
# biomcp 由 Dockerfile 用官方 install.sh 装到 ~/.local/bin（已在 PATH），
# 这里只做"注册"，不复制二进制；注册信息写进各 CLI 自己的全局配置，所以
# reasonix / codex / opencode 谁被 Multica 选中都能用。
#
# 必须放在 setup_reasonix / setup_codex_official 之后：那两个函数会整份重写
# config.toml，先注册会被覆盖。失败只告警，不影响容器启动。
setup_biomcp_mcp() {
    if ! command -v biomcp >/dev/null 2>&1; then
        echo "WARNING: biomcp not found (pixi global install failed?); MCP registration skipped."
        return 0
    fi

    # Codex：写入 ~/.codex/config.toml 的 [mcp_servers.biomcp]
    if command -v codex >/dev/null 2>&1; then
        mkdir -p /home/ubuntu/.codex
        # 先删后建：容器重启时覆盖旧条目，避免同名残留导致 add 失败
        codex mcp remove biomcp >/dev/null 2>&1 || true
        if codex mcp add biomcp -- biomcp serve >/dev/null 2>&1; then
            echo "Codex: biomcp MCP registered (stdio: biomcp serve)."
        else
            echo "WARNING: Codex biomcp MCP registration failed."
        fi
    fi

    # Reasonix：写入 ~/.reasonix/config.toml（全局层）
    if command -v reasonix >/dev/null 2>&1; then
        mkdir -p /home/ubuntu/.reasonix
        reasonix mcp remove biomcp >/dev/null 2>&1 || true
        if reasonix mcp add biomcp -- biomcp serve >/dev/null 2>&1; then
            echo "Reasonix: biomcp MCP registered (stdio: biomcp serve)."
        else
            echo "WARNING: Reasonix biomcp MCP registration failed."
        fi
    fi

    # opencode：读-改-写 ~/.config/opencode/opencode.json 的 mcp 段（保留 provider）
    if node /opencode-mcp.mjs >/dev/null 2>&1; then
        echo "opencode: biomcp MCP registered (stdio: biomcp serve)."
    else
        echo "WARNING: opencode biomcp MCP registration failed."
    fi
}

setup_biomcp_mcp

# 1.5 虚拟显示：headed Chrome 需要 DISPLAY（失败不影响容器启动，可降级为无头）
setup_xvfb

# 2. Multica 登录
echo "准备设置Multica"
if [ -n "$MULTICA_TOKEN" ]; then
    echo "检测到 MULTICA_TOKEN 自动登录 mulitca 并启动"
    multica config set server_url https://api.multica.ai
    multica config set app_url https://multica.ai
    multica login --token ${MULTICA_TOKEN}
    multica daemon start
fi


# 5. Github 登录（放最后，避免阻塞前面的自动化配置）
#
# 关键：GitHub 未登录时绝不能中断 entrypoint。旧实现直接执行
# `echo ... | gh auth login -w`（设备码 web 登录）：容器无人值守时它会一直阻塞
# 等待用户在浏览器完成授权，超时后返回非零，配合文件顶部的 `set -e` 直接让
# entrypoint 退出、`exec "$@"` 永不执行，容器随之关闭。
# 现在只在已登录或提供了 token 时自动认证；否则仅打印提示并继续，容器保持运行，
# 用户可随时进入容器执行 `BROWSER=false gh auth login` 完成登录。
#
# 为什么带 BROWSER=false：镜像里装了 headed Chrome + Xvfb，gh 检测到浏览器后会走
# 自动打开浏览器的分支，设备验证码刷不出来或一闪而过，日志里看不到。关掉浏览器
# 打开后 gh 会老老实实把 one-time code 打印在终端/日志里，用户自己粘贴到网页即可。
setup_github() {
    if ! command -v gh > /dev/null 2>&1; then
        echo "WARNING: gh not installed; GitHub setup skipped."
        return 0
    fi

    # 必须提供 token 时"每次启动都落地到 hosts.yml"，不能因为 env 里能用就跳过：
    #
    # 1) gh 只在"进程 env 里确实带着 GH_TOKEN"时才用它。Multica 为 Codex 生成的
    #    每任务 codex-home/config.toml 会写一段 multica-managed
    #    [shell_environment_policy]，include_only 是一份固定白名单，里面没有
    #    GH_TOKEN / GITHUB_TOKEN。于是 Codex 的 shell 里 gh 完全看不到凭据，报
    #    "To get started with GitHub CLI, please run: gh auth login"。
    #    hosts.yml 是文件，不受 env 白名单过滤影响，任何 agent 都能读到。
    # 2) git 不读 GH_TOKEN，只认 credential helper。以前跳过 gh auth login 时
    #    从没执行过 gh auth setup-git，~/.gitconfig 里没有 helper，也没有
    #    hosts.yml，`git push` 直接报 "could not read Username for github.com"，
    #    agent 无法推分支/建 PR（Codex、Reasonix、opencode 都一样）。
    #
    # 所以：只要给了 token，就无条件写入 hosts.yml 并配置 git credential helper；
    # 没给 token 且已登录（例如容器内手动 gh auth login 后重启）才跳过。
    local gh_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    if [ -n "${gh_token}" ]; then
        mkdir -p /home/ubuntu/.config/gh
        # gh 在 GH_TOKEN 存在时拒绝把 token 写进 hosts.yml（会打印
        # "The value of the GH_TOKEN environment variable is being used for
        # authentication"），因此子进程里先清掉再登录。
        if printf '%s\n' "${gh_token}" | env -u GH_TOKEN -u GITHUB_TOKEN \
                gh auth login --hostname github.com --with-token > /dev/null 2>&1; then
            chmod 600 /home/ubuntu/.config/gh/hosts.yml 2> /dev/null || true
            # 让 git 通过 `gh auth git-credential` 取 hosts.yml 里的 token
            gh auth setup-git > /dev/null 2>&1 || true
            echo "GitHub CLI 已通过 GH_TOKEN/GITHUB_TOKEN 登录（已写入 hosts.yml 并配置 git credential helper）。"
        else
            echo "WARNING: GitHub token 登录失败；容器继续运行，可稍后手动执行 'BROWSER=false gh auth login'。"
        fi
        return 0
    fi

    if gh auth status --hostname github.com > /dev/null 2>&1; then
        echo "GitHub CLI 已登录，跳过。"
        # 兜底：历史上手动登录过但没有 git helper 的容器，重启时补一次
        gh auth setup-git > /dev/null 2>&1 || true
        return 0
    fi

    echo "GitHub CLI 未登录。容器保持运行；进入容器后执行 'BROWSER=false gh auth login'，按提示把设备验证码粘贴到网页完成认证。"
    return 0
}

echo "准备设置 Github"
setup_github

# 继续运行
exec "$@"
