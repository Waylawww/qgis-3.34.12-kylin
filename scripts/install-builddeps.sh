#!/usr/bin/env bash
# 在 Kylin V10 构建镜像中安装「已确认」的原生 RPM 构建依赖。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
load_env "${KYLIN_ENV}"
load_env "${DEPS_ENV}"

PM="${KYLIN_PACKAGE_MANAGER}"
[[ -n "${PM}" && "${PM}" != "__UNCONFIRMED__" ]] || die "KYLIN_PACKAGE_MANAGER 未确认"
command -v "${PM}" >/dev/null 2>&1 || die "镜像中没有包管理器 ${PM}"

if [[ -z "${QGIS_BUILDREQUIRES}" || "${QGIS_BUILDREQUIRES}" == *"__UNCONFIRMED__"* ]]; then
  die "config/deps.confirmed.env 中的 QGIS_BUILDREQUIRES 未确认。
请先在真实 Kylin V10 环境中执行：python3 scripts/probe-kylin.py --write
（可由 .github/workflows/probe-kylin.yml 云端生成），再重新构建镜像。"
fi

# 基础镜像里 curl/wget/python3 未必齐全，按可用性选择下载方式
fetch_url() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$dest" "$url"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,urllib.request;urllib.request.urlretrieve(sys.argv[1],sys.argv[2])' "$url" "$dest"
  else die "镜像中没有 curl/wget/python3，无法注入 Kylin repo 定义"; fi
}

# 注入确认过的软件源
if [[ -n "${KYLIN_REPO_FILE_URL:-}" ]]; then
  fetch_url "${KYLIN_REPO_FILE_URL}" /etc/yum.repos.d/kylin-ci.repo
fi
if [[ -n "${KYLIN_EXTRA_REPO_URLS:-}" ]]; then
  IFS=',' read -ra urls <<< "${KYLIN_EXTRA_REPO_URLS}"
  i=0
  for u in "${urls[@]}"; do
    i=$((i+1))
    fetch_url "$u" "/etc/yum.repos.d/qgis-extra-${i}.repo"
  done
fi

info "== 安装麒麟原生构建依赖 (${PM}) =="
log "包名来源：config/deps.confirmed.env（由 probe-kylin.py 实测解析）"
printf '%s\n' ${QGIS_BUILDREQUIRES} | sed 's/^/    /'

${PM} -y install ${QGIS_BUILDREQUIRES} 2>&1 | tee "${LOG_DIR}/builddeps-install.log"
${PM} clean all >/dev/null 2>&1 || true

info "== 复核依赖最低版本 =="
python3 "${REPO_ROOT}/scripts/check-deps.py" | tee "${LOG_DIR}/deps-check.log"

info "INSTALL BUILDDEPS PASS"
