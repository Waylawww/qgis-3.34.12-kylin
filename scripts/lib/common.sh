#!/usr/bin/env bash
# 公共函数库。所有脚本先 source 本文件。
set -Eeuo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${COMMON_DIR}/../.." && pwd)}"
export REPO_ROOT

WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work}"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/out}"
REPORT_DIR="${REPORT_DIR:-${REPO_ROOT}/reports}"
LOG_DIR="${LOG_DIR:-${REPORT_DIR}/logs}"
export WORK_DIR OUT_DIR REPORT_DIR LOG_DIR

mkdir -p "${WORK_DIR}" "${OUT_DIR}" "${REPORT_DIR}" "${LOG_DIR}"

BUILD_ENV="${REPO_ROOT}/config/build.env"
KYLIN_ENV="${REPO_ROOT}/config/kylin.confirmed.env"
DEPS_ENV="${REPO_ROOT}/config/deps.confirmed.env"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
info() { printf '\033[0;32m[%s] %s\033[0m\n' "$(date -u +%H:%M:%S)" "$*"; }
warn() { printf '\033[0;33m[%s] WARN: %s\033[0m\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[0;31m[%s] FATAL: %s\033[0m\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

# 失败定位：set -e 只交出退出码，CI 日志里往往"最后一行之后直接 exit 1"，
# 完全看不出死在哪。这里挂一个 ERR trap（set -E 让函数与子 shell 一并继承），
# 把出错文件:行号与命令打到 stderr；被 if / && / || 保护的命令不会触发，
# 与 set -e 的抑制规则一致。用内联 trap 而不是函数，这样 BASH_SOURCE/LINENO
# 指向的是真正出错的位置。
trap 'rc=$?; printf "[%s] ERR: rc=%s @ %s:%s\n        %s\n" \
  "$(date -u +%H:%M:%S)" "$rc" "${BASH_SOURCE[0]##*/}" "$LINENO" "$BASH_COMMAND" >&2' ERR

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1  ($2)"
}

load_env() {
  local f="$1"
  [[ -f "${f}" ]] || die "缺少文件 ${f}；请先运行 scripts/probe-kylin.py --write 或阅读 docs/CONFIRM.md"
  set -a
  # shellcheck disable=SC1090
  source "${f}"
  set +a
}

load_build_env() { load_env "${BUILD_ENV}"; }

# 麒麟确认参数必须由 probe 生成；CI 中不允许带 __UNCONFIRMED__
reject_placeholders() {
  local f="$1"
  shift
  local keys=("$@")
  local k v
  for k in "${keys[@]}"; do
    v="$(grep -E "^${k}=" "${f}" | tail -n1 | cut -d= -f2- | tr -d "\"'" || true)"
    if [[ -z "${v}" || "${v}" == *"__UNCONFIRMED__"* || "${v}" == *"REPLACE_ME"* ]]; then
      die "${f} 中 ${k} 尚未确认（当前值: '${v}'）。请先按 docs/CONFIRM.md 完成确认。"
    fi
  done
}

free_gb() {
  df -Pk "$1" | awk 'NR==2 {printf "%d", $4/1024/1024}'
}

stage_marker() {
  # stage_marker STAGE_A_SOURCE_BUILD_OK PASS file.json
  local name="$1" status="$2" out="$3"
  python3 - "$name" "$status" "$out" <<'PY'
import datetime, json, os, sys
name, status, path = sys.argv[1:4]
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump({"stage": name, "status": status,
               "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat()},
              f, ensure_ascii=False, indent=2)
PY
}

sha256_file() { sha256sum "$1" | awk '{print $1}'; }

require_linux_or_container() {
  [[ "$(uname -s)" == "Linux" ]] || die "本工程所有构建/验证步骤必须在 Linux 容器内执行"
}

# 依赖源码统一安装到独立前缀；workflow 通过环境变量注入持久化目录，
# 本地运行时回退到仓库 .cache/。绝不写入 /usr，不覆盖系统 Qt/PROJ/GEOS/GDAL。
DEPS_PREFIX="${DEPS_PREFIX:-${REPO_ROOT}/${DEPS_PREFIX_DEFAULT:-.cache/qgis-334-deps}}"
CACHE_DIR="${CACHE_DIR:-${REPO_ROOT}/${CACHE_DIR_DEFAULT:-.cache/qgis-334-src}}"
export DEPS_PREFIX CACHE_DIR
mkdir -p "${DEPS_PREFIX}" "${CACHE_DIR}"
