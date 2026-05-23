#!/bin/bash
set -euo pipefail

# multica-opencode-runtime — Ubuntu 原生安装脚本
# 将 Multica 和 Opencode 直接安装到 Ubuntu 系统中。
# 支持从客户端侧完成升级，无需频繁构建容器。
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/SilenWang/multica-opencode-runtime/main/install.sh | bash
#   或
#   ./install.sh

REPO_URL="https://raw.githubusercontent.com/SilenWang/multica-opencode-runtime/main"

# ─── 色彩输出 ───────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERROR]${NC} %s\n" "$*"; }

# ─── 1. 检查操作系统 ──────────────────────────────────────
check_os() {
  if [ "$(uname)" != "Linux" ]; then
    err "此脚本仅在 Linux (Ubuntu) 下运行。当前系统: $(uname)"
    exit 1
  fi

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "ubuntu" ]; then
      warn "检测到发行版: $ID。脚本主要为 Ubuntu 设计，但会尝试继续安装。"
    fi
  fi
}

# ─── 2. 安装系统依赖 ─────────────────────────────────────
install_system_deps() {
  info "更新包索引并安装系统依赖..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    curl \
    git \
    sudo \
    gh
  ok "系统依赖安装完成"
}

# ─── 3. 安装 Pixi ────────────────────────────────────────
install_pixi() {
  if command -v pixi &>/dev/null; then
    info "pixi 已安装 ($(pixi --version))，跳过"
    return
  fi

  info "安装 pixi 包管理器..."
  curl -fsSL https://pixi.sh/install.sh | bash
  # 将 pixi 加入当前会话 PATH
  export PATH="$HOME/.pixi/bin:$PATH"
  ok "pixi 安装完成 ($(pixi --version))"
}

# ─── 4. 安装 Multica ─────────────────────────────────────
install_multica() {
  if command -v multica &>/dev/null; then
    info "multica 已安装 ($(multica --version 2>/dev/null || echo 'unknown'))，跳过"
    return
  fi

  info "安装 multica..."
  curl -fsSL https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.sh | bash
  ok "multica 安装完成"
}

# ─── 5. 安装 Opencode ────────────────────────────────────
install_opencode() {
  if command -v opencode &>/dev/null; then
    info "opencode 已安装，跳过"
    return
  fi

  info "安装 opencode (通过 pixi global)..."
  # 确保 pixi 在 PATH 中
  export PATH="$HOME/.pixi/bin:$PATH"
  pixi global install -c https://prefix.dev/sylens opencode
  ok "opencode 安装完成"
}

# ─── 6. 创建必要目录 ────────────────────────────────────
setup_directories() {
  info "创建数据目录..."
  mkdir -p "$HOME/.local/share/opencode"
  ok "目录创建完成"
}

# ─── 7. 配置 PATH ────────────────────────────────────────
setup_path() {
  local shell_rc

  if [ -n "${BASH_VERSION:-}" ]; then
    shell_rc="$HOME/.bashrc"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    shell_rc="$HOME/.zshrc"
  else
    shell_rc="$HOME/.profile"
  fi

  # 仅在尚未添加时追加
  if ! grep -q '\.pixi/bin' "$shell_rc" 2>/dev/null; then
    cat >> "$shell_rc" << 'EOF'

# multica-opencode-runtime
export PATH="$HOME/.pixi/bin:${PATH}"
EOF
    info "已将 pixi/bin 添加到 PATH ($shell_rc)"
  fi
}

# ─── 主流程 ──────────────────────────────────────────────
main() {
  echo ""
  echo "=============================================="
  echo "  multica-opencode-runtime — Ubuntu 安装脚本"
  echo "=============================================="
  echo ""

  check_os
  install_system_deps
  install_pixi

  # 安装后确保 pixi 可用
  export PATH="$HOME/.pixi/bin:$PATH"

  install_multica
  install_opencode
  setup_directories
  setup_path

  echo ""
  echo "=============================================="
  echo -e "  ${GREEN}安装完成!${NC}"
  echo "=============================================="
  echo ""
  echo "请执行以下命令完成初始配置:"
  echo ""
  echo "  1. 配置 Multica 服务连接:"
  echo "     multica setup"
  echo ""
  echo "  2. 登录 GitHub:"
  echo "     gh auth login"
  echo ""
  echo "安装路径已添加到 ~/.bashrc，请执行以下命令使其生效:"
  echo "     source ~/.bashrc"
  echo ""
}

main
