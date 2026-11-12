#!/usr/bin/env bash
# GitHub 托管 runner 可用磁盘通常只有 ~14-25GB，QGIS 全量编译需要 25-40GB。
# 清理预装 SDK；本脚本只在 CI 宿主上执行，不进入构建容器。
set -Eeuo pipefail
log() { printf '[free-space] %s\n' "$*"; }
log "清理前:"; df -h / /mnt 2>/dev/null || true
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache/CodeQL \
            /usr/local/share/boost /usr/share/swift /usr/local/.ghcup 2>/dev/null || true
sudo apt-get clean >/dev/null 2>&1 || true
sudo docker image prune -af >/dev/null 2>&1 || true
log "清理后:"; df -h / /mnt 2>/dev/null || true
