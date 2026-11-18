#!/usr/bin/env bash
# osg2vsg 原生构建总入口（Kylin V10 self-hosted runner）。
# 阶段：preflight / source / build / install / all
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT="$ROOT"
source "$ROOT/scripts/lib/common.sh"
load_build_env
source "$ROOT/config/osg2vsg.env"

export OSG2VSG_WORK="${OSG2VSG_WORK:-${WORK_DIR}/osg2vsg-040}"
export OSG2VSG_SRC_DIR="${OSG2VSG_WORK}/src/osg2vsg-${OSG2VSG_VERSION}"
export VSG_SRC_DIR="${OSG2VSG_WORK}/src/VulkanSceneGraph-${VSG_VERSION}"
export OSG_SRC_DIR="${OSG2VSG_WORK}/src/OpenSceneGraph-${OSG_VERSION}"
export OSG_PREFIX="${OSG2VSG_WORK}/deps/osg-${OSG_VERSION}"
export VSG_PREFIX="${OSG2VSG_WORK}/deps/vsg-${VSG_VERSION}"
export OSG2VSG_BUILD_DIR="${OSG2VSG_WORK}/build"
export OSG2VSG_STAGE_DIR="${OSG2VSG_WORK}/stage"
export OSG2VSG_LOCAL_ROOT="${OSG2VSG_WORK}/local-install"
export OSG2VSG_RPM_ROOT="${OSG2VSG_WORK}/rpm-install"
export OSG2VSG_RPM_TOP="${OSG2VSG_WORK}/rpmbuild"
export OSG2VSG_REPORT_DIR="${OSG2VSG_REPORT_DIR:-${REPORT_DIR}}"
export OSG2VSG_OUT_DIR="${OSG2VSG_OUT_DIR:-${OUT_DIR}}"
export OSG2VSG_BUILD_JOBS="${OSG2VSG_BUILD_JOBS:-${QGIS_BUILD_JOBS:-${OSG2VSG_BUILD_JOBS_DEFAULT}}}"
mkdir -p "$OSG2VSG_WORK" "$OSG2VSG_REPORT_DIR/logs" "$OSG2VSG_OUT_DIR/rpms" \
         "$OSG2VSG_RPM_TOP/SPECS" "$OSG2VSG_RPM_TOP/RPMS"

STAGE="${STAGE:-all}"
info "=============================================================="
info "Native osg2vsg ${OSG2VSG_VERSION} build | STAGE=${STAGE}"
info "user=$(id -un) host=$(hostname) arch=$(uname -m) kernel=$(uname -r)"
info "WORK=$OSG2VSG_WORK OUT=$OSG2VSG_OUT_DIR REPORT=$OSG2VSG_REPORT_DIR"
info "=============================================================="

run() {
  local name="$1" script="$2"
  info "---------- ${name} ----------"
  [[ -f "$ROOT/scripts/$script" ]] || die "阶段 ${name} 所需脚本 scripts/$script 不存在"
  bash "$ROOT/scripts/$script" 2>&1 | tee "$OSG2VSG_REPORT_DIR/logs/${script%.sh}.log"
}

summarize() {
  python3 - "$OSG2VSG_REPORT_DIR" "$OSG2VSG_OUT_DIR" "$STAGE" <<'PY'
import datetime, glob, hashlib, os, sys
rep, out, stage = sys.argv[1:4]
lines = ['# osg2vsg 0.4.0 · Kylin V10 原生构建报告', '',
         '- stage: `%s`' % stage,
         '- generated: %sZ' % datetime.datetime.utcnow().isoformat(), '',
         '## RPM 产物', '']
rpms = sorted(glob.glob(os.path.join(out, 'rpms', 'osg2vsg*.rpm')))
if not rpms:
    lines.append('本阶段未生成 RPM。')
else:
    for p in rpms:
        h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
        lines.append('- `%s` — %d bytes — sha256 `%s`' % (os.path.basename(p), os.path.getsize(p), h))
text = '\n'.join(lines) + '\n'
with open(os.path.join(rep, 'OSG2VSG_BUILD_SUMMARY.md'), 'w', encoding='utf-8') as f:
    f.write(text)
print(text)
PY
}

case "$STAGE" in
  preflight) run "0 · 依赖门禁" osg2vsg-00-preflight.sh ;;
  source)    run "1 · 官方源码" osg2vsg-10-fetch-source.sh ;;
  build)     run "2 · CMake 编译 / RPM" osg2vsg-20-build.sh ;;
  install)   run "3 · RPM 安装与自测" osg2vsg-40-install-test.sh ;;
  all)
    run "0 · 依赖门禁" osg2vsg-00-preflight.sh
    run "1 · 官方源码" osg2vsg-10-fetch-source.sh
    run "2 · CMake 编译 / RPM" osg2vsg-20-build.sh
    run "3 · RPM 安装与自测" osg2vsg-40-install-test.sh
    ;;
  *) die "未知 STAGE=${STAGE}" ;;
esac
summarize
info "OSG2VSG NATIVE BUILD DONE (STAGE=${STAGE})"
