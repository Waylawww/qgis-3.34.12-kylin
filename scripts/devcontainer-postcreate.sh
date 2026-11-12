#!/usr/bin/env bash
# Codespaces 创建后：显示当前状态与可执行命令，不自动启动 4~6 小时的全量编译。
set -Eeuo pipefail
cd /workspaces/qgis-kylin || exit 0
printf '\n================ QGIS 3.34.12 / Kylin V10 云端构建环境 ================\n'
printf '源码版本 : 3.34.12 (tag final-3_34_12, commit eeb6af36...)\n'
printf '目标平台 : 银河麒麟高级服务器操作系统 V10 (Halberd) / x86_64 / Hygon C86-3G\n\n'
if [[ ! -f config/kylin.confirmed.env || ! -f config/deps.confirmed.env ]]; then
  printf '[!] 依赖尚未确认。先在 Codespaces 里执行：\n'
  printf '      python3 scripts/probe-kylin.py --write\n'
  printf '    再检查 reports/dependency-matrix.json，把 config/*.confirmed.env 提交入库。\n\n'
else
  printf '[OK] 已检测到确认参数。\n\n'
fi
printf '常用命令：\n'
printf '  bash scripts/00-preflight.sh --container   # 门禁\n'
printf '  bash scripts/10-fetch-source.sh            # 拉取并校验官方源码\n'
printf '  bash scripts/20-render-spec.sh             # 渲染 SPEC\n'
printf '  bash scripts/30-rpmbuild.sh                # 全量编译 + 打 RPM\n'
printf '  bash scripts/40-verify-rpm.sh              # 静态校验\n'
printf '  bash scripts/build-all.sh                  # 以上一键执行\n'
printf '  make help                                  # 全部目标\n'
printf '\n注意：Codespaces 不提供 /dev/kvm，QEMU/KVM 目标系统验证请在 Actions 中执行。\n'
printf '========================================================================\n'
