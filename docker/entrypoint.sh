#!/usr/bin/env bash
# 构建容器入口：build / test-install / verify / shell / 任意命令
set -Eeuo pipefail
cd /opt/qgis-build
cmd="${1:-build}"
shift || true
case "${cmd}" in
  build)        exec bash scripts/build-all.sh ;;
  test-install) exec bash scripts/50-test-install.sh ;;
  verify)       exec bash scripts/40-verify-rpm.sh ;;
  check-deps)   exec python3 scripts/check-deps.py ;;
  shell)        exec /bin/bash ;;
  *)            exec "$cmd" "$@" ;;
esac
