#!/usr/bin/env bash
# vsgXchange 原生构建总入口（Kylin V10 self-hosted runner）。
# 阶段：preflight / source / build / install / all
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT="$ROOT"
source "$ROOT/scripts/lib/common.sh"
load_build_env
source "$ROOT/config/vsgxchange.env"

export VSGXCHANGE_WORK="${VSGXCHANGE_WORK:-${WORK_DIR}/vsgx-119}"
export VSGXCHANGE_SRC_DIR="${VSGXCHANGE_WORK}/src/vsgXchange-${VSGXCHANGE_VERSION}"
export VSGXCHANGE_BUILD_DIR="${VSGXCHANGE_WORK}/build"
export VSGXCHANGE_STAGE_DIR="${VSGXCHANGE_WORK}/stage"
export VSGXCHANGE_LOCAL_ROOT="${VSGXCHANGE_WORK}/local-install"
export VSGXCHANGE_RPM_ROOT="${VSGXCHANGE_WORK}/rpm-install"
export VSGXCHANGE_RPM_TOP="${VSGXCHANGE_WORK}/rpmbuild"
export VSGXCHANGE_REPORT_DIR="${VSGXCHANGE_REPORT_DIR:-${REPORT_DIR}}"
export VSGXCHANGE_OUT_DIR="${VSGXCHANGE_OUT_DIR:-${OUT_DIR}}"
export VSGXCHANGE_BUILD_JOBS="${VSGXCHANGE_BUILD_JOBS:-${QGIS_BUILD_JOBS:-4}}"
mkdir -p "$VSGXCHANGE_WORK" "$VSGXCHANGE_REPORT_DIR/logs" "$VSGXCHANGE_OUT_DIR/rpms" \
         "$VSGXCHANGE_RPM_TOP/SPECS" "$VSGXCHANGE_RPM_TOP/RPMS"
export OSG2VSG_PREFIX GLSLANG_PREFIX ASSIMP_PREFIX

STAGE="${STAGE:-all}"
info "=============================================================="
info "Native vsgXchange ${VSGXCHANGE_VERSION} build | STAGE=${STAGE}"
info "user=$(id -un) host=$(hostname) arch=$(uname -m) kernel=$(uname -r)"
info "WORK=$VSGXCHANGE_WORK OUT=$VSGXCHANGE_OUT_DIR REPORT=$VSGXCHANGE_REPORT_DIR"
info "=============================================================="

run() {
  local name="$1" script="$2"
  info "---------- ${name} ----------"
  [[ -f "$ROOT/scripts/$script" ]] || die "阶段 ${name} 所需脚本 scripts/$script 不存在"
  bash "$ROOT/scripts/$script" 2>&1 | tee "$VSGXCHANGE_REPORT_DIR/logs/${script%.sh}.log"
}

summarize() {
  python3 - "$VSGXCHANGE_REPORT_DIR" "$VSGXCHANGE_OUT_DIR" "$STAGE" <<'PY'
import datetime, glob, hashlib, os, sys
rep, out, stage = sys.argv[1:4]
lines = ['# vsgXchange 1.1.9 · Kylin V10 原生构建报告', '',
         '- stage: `%s`' % stage,
         '- generated: %sZ' % datetime.datetime.utcnow().isoformat(), '',
         '## RPM 产物', '']
rpms = sorted(glob.glob(os.path.join(out, 'rpms', 'vsgXchange*.rpm')))
if not rpms:
    lines.append('本阶段未生成 RPM。')
else:
    for p in rpms:
        h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
        lines.append('- `%s` — %d bytes — sha256 `%s`' % (os.path.basename(p), os.path.getsize(p), h))
text = '\n'.join(lines) + '\n'
with open(os.path.join(rep, 'VSGXCHANGE_BUILD_SUMMARY.md'), 'w', encoding='utf-8') as f:
    f.write(text)
print(text)
PY
}

case "$STAGE" in
  preflight) run "0 · 原生门禁" vsgxchange-00-preflight.sh ;;
  source)    run "1 · 官方源码" vsgxchange-10-fetch-source.sh ;;
  build)     run "2 · CMake 编译 / RPM" vsgxchange-20-build.sh ;;
  install)   run "3 · RPM 安装与自测" vsgxchange-40-install-test.sh ;;
  all)
    run "0 · 原生门禁" vsgxchange-00-preflight.sh
    run "1 · 官方源码" vsgxchange-10-fetch-source.sh
    run "2 · CMake 编译 / RPM" vsgxchange-20-build.sh
    run "3 · RPM 安装与自测" vsgxchange-40-install-test.sh
    ;;
  *) die "未知 STAGE=${STAGE}" ;;
esac
summarize
info "VSGXCHANGE NATIVE BUILD DONE (STAGE=${STAGE})"
