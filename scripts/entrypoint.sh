#!/bin/bash
# 遇到错误立即停止运行
set -e

echo "准备设置Multica"

# 1. Github登录
# 环境变量有token，不需要额外登录

# 2. Multica 登录
if [ -n "$MULTICA_TOKEN" ]; then
    echo "检测到 MULTICA_TOKEN 自动登录 mulitca 并启动"
    multica login --token ${MULTICA_TOKEN}
    multica daemon start
fi
# 继续运行
exec "$@"