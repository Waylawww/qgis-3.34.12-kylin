#!/usr/bin/env bash
# Rocky 原生构建总入口（Kylin V10 self-hosted runner）。
# 阶段：preflight / source / build / install / all
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT="$ROOT"
source "$ROOT/scripts/lib/common.sh"
load_build_env
source "$ROOT/config/rocky.env"

export ROCKY_WORK="${ROCKY_WORK:-${WORK_DIR}/rocky-102}"
export ROCKY_SRC_DIR="${ROCKY_WORK}/src/rocky-${ROCKY_VERSION}"
export ROCKY_BUILD_DIR="${ROCKY_WORK}/build"
export ROCKY_STAGE_DIR="${ROCKY_WORK}/stage"
export ROCKY_LOCAL_ROOT="${ROCKY_WORK}/local-install"
export ROCKY_RPM_ROOT="${ROCKY_WORK}/rpm-install"
export ROCKY_RPM_TOP="${ROCKY_WORK}/rpmbuild"
export ROCKY_DEPS_PREFIX="${ROCKY_WORK}/deps"
export VULKAN_HEADERS_SRC_DIR="${ROCKY_WORK}/src/Vulkan-Headers-${VULKAN_HEADERS_LABEL}"
export VULKAN_SDK_PREFIX="${ROCKY_WORK}/deps/vulkan-sdk-${VULKAN_HEADERS_LABEL}"
export ROCKY_REPORT_DIR="${ROCKY_REPORT_DIR:-${REPORT_DIR}}"
export ROCKY_OUT_DIR="${ROCKY_OUT_DIR:-${OUT_DIR}}"
export ROCKY_BUILD_JOBS="${ROCKY_BUILD_JOBS:-${QGIS_BUILD_JOBS:-4}}"
mkdir -p "$ROCKY_WORK" "$ROCKY_REPORT_DIR/logs" "$ROCKY_OUT_DIR/rpms" \
         "$ROCKY_RPM_TOP/SPECS" "$ROCKY_RPM_TOP/RPMS" "$ROCKY_DEPS_PREFIX"

STAGE="${STAGE:-all}"
info "=============================================================="
info "Native Rocky ${ROCKY_VERSION} build | STAGE=${STAGE}"
info "user=$(id -un) host=$(hostname) arch=$(uname -m) kernel=$(uname -r)"
info "WORK=$ROCKY_WORK OUT=$ROCKY_OUT_DIR REPORT=$ROCKY_REPORT_DIR"
info "=============================================================="

run() {
  local name="$1" script="$2"
  info "---------- ${name} ----------"
  [[ -f "$ROOT/scripts/$script" ]] || die "阶段 ${name} 所需脚本 scripts/$script 不存在"
  bash "$ROOT/scripts/$script" 2>&1 | tee "$ROCKY_REPORT_DIR/logs/${script%.sh}.log"
}

summarize() {
  python3 - "$ROCKY_REPORT_DIR" "$ROCKY_OUT_DIR" "$STAGE" "$ROCKY_VERSION" <<'PY'
import datetime, glob, hashlib, os, sys
rep, out, stage, version = sys.argv[1:5]
lines = ['# Rocky %s · Kylin V10 原生构建报告' % version, '',
         '- stage: `%s`' % stage,
         '- generated: %sZ' % datetime.datetime.utcnow().isoformat(), '',
         '## RPM 产物', '']
rpms = sorted(glob.glob(os.path.join(out, 'rpms', 'rocky*.rpm')))
if not rpms:
    lines.append('本阶段未生成 RPM。')
else:
    for p in rpms:
        h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
        lines.append('- `%s` — %d bytes — sha256 `%s`' % (os.path.basename(p), os.path.getsize(p), h))
text = '\n'.join(lines) + '\n'
with open(os.path.join(rep, 'ROCKY_BUILD_SUMMARY.md'), 'w', encoding='utf-8') as f:
    f.write(text)
print(text)
PY
}

case "$STAGE" in
  preflight) run "0 · 原生门禁" rocky-00-preflight.sh ;;
  source)    run "1 · 源码与依赖" rocky-10-fetch-source.sh ;;
  build)     run "2 · CMake 编译 / RPM" rocky-20-build.sh ;;
  install)   run "3 · RPM 安装与自测" rocky-40-install-test.sh ;;
  all)
    run "0 · 原生门禁" rocky-00-preflight.sh
    run "1 · 源码与依赖" rocky-10-fetch-source.sh
    run "2 · CMake 编译 / RPM" rocky-20-build.sh
    run "3 · RPM 安装与自测" rocky-40-install-test.sh
    ;;
  *) die "未知 STAGE=${STAGE}" ;;
esac
summarize
info "ROCKY NATIVE BUILD DONE (STAGE=${STAGE})"
