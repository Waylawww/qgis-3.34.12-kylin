#!/usr/bin/env bash
# Codespaces 创建前在宿主机执行：只做参数检查，不接触麒麟系统。
set -Eeuo pipefail
if [[ -z "${KYLIN_BASE_IMAGE:-}" || "${KYLIN_BASE_IMAGE}" == *"__UNCONFIRMED__"* ]]; then
  cat >&2 <<'EOF'
[Codespaces] KYLIN_BASE_IMAGE 未设置。

请在 GitHub 仓库 Settings -> Secrets and variables -> Codespaces 中添加
Repository Secret / Variable：
  KYLIN_BASE_IMAGE       = <Kylin V10 x86_64 RPM 基础镜像，建议带 @sha256:...>
  KYLIN_REPO_FILE_URL    = <可选，麒麟官方 .repo 文件 URL>
  KYLIN_EXTRA_REPO_URLS  = <可选，逗号分隔的依赖叠加源 .repo URL>

Codespaces 会把它们作为环境变量注入 devcontainer build args。
若尚无麒麟基础镜像，请先运行 .github/workflows/probe-kylin.yml 或
scripts/bootstrap/10-make-rootfs.sh（详见 docs/CONFIRM.md 第 1 节）。
EOF
  exit 1
fi
printf '[Codespaces] KYLIN_BASE_IMAGE=%s\n' "${KYLIN_BASE_IMAGE}"
