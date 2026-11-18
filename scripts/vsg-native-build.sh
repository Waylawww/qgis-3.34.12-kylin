#!/usr/bin/env bash
# VulkanSceneGraph 原生构建总入口（Kylin V10 self-hosted runner）。
# 阶段：preflight / source / build / install / all
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT="$ROOT"
source "$ROOT/scripts/lib/common.sh"
load_build_env
source "$ROOT/config/vsg.env"

export VSG_WORK="${VSG_WORK:-${WORK_DIR}/vsg-1113}"
export VSG_SRC_DIR="${VSG_WORK}/src/VulkanSceneGraph-${VSG_VERSION}"
export VSG_BUILD_DIR="${VSG_WORK}/build"
export VSG_STAGE_DIR="${VSG_WORK}/stage"
export VSG_LOCAL_ROOT="${VSG_WORK}/local-install"
export VSG_RPM_ROOT="${VSG_WORK}/rpm-install"
export VSG_RPM_TOP="${VSG_WORK}/rpmbuild"
export VULKAN_HEADERS_SRC_DIR="${VSG_WORK}/src/Vulkan-Headers-${VULKAN_HEADERS_LABEL}"
export VULKAN_SDK_PREFIX="${VSG_WORK}/deps/vulkan-sdk-${VULKAN_HEADERS_LABEL}"
export VSG_REPORT_DIR="${VSG_REPORT_DIR:-${REPORT_DIR}}"
export VSG_OUT_DIR="${VSG_OUT_DIR:-${OUT_DIR}}"
export VSG_BUILD_JOBS="${VSG_BUILD_JOBS:-${QGIS_BUILD_JOBS:-4}}"
mkdir -p "$VSG_WORK" "$VSG_REPORT_DIR/logs" "$VSG_OUT_DIR/rpms" \
         "$VSG_RPM_TOP/SPECS" "$VSG_RPM_TOP/RPMS"
export GLSLANG_PREFIX

STAGE="${STAGE:-all}"
info "=============================================================="
info "Native VSG ${VSG_VERSION} build | STAGE=${STAGE}"
info "user=$(id -un) host=$(hostname) arch=$(uname -m) kernel=$(uname -r)"
info "WORK=$VSG_WORK OUT=$VSG_OUT_DIR REPORT=$VSG_REPORT_DIR"
info "=============================================================="

run() {
  local name="$1" script="$2"
  info "---------- ${name} ----------"
  [[ -f "$ROOT/scripts/$script" ]] || die "阶段 ${name} 所需脚本 scripts/$script 不存在"
  bash "$ROOT/scripts/$script" 2>&1 | tee "$VSG_REPORT_DIR/logs/${script%.sh}.log"
}

summarize() {
  python3 - "$VSG_REPORT_DIR" "$VSG_OUT_DIR" "$STAGE" <<'PY'
import datetime, glob, hashlib, os, sys
rep, out, stage = sys.argv[1:4]
lines = ['# VSG 1.1.13 · Kylin V10 原生构建报告', '',
         '- stage: `%s`' % stage,
         '- generated: %sZ' % datetime.datetime.utcnow().isoformat(), '',
         '## RPM 产物', '']
rpms = sorted(glob.glob(os.path.join(out, 'rpms', 'vsg*.rpm')))
if not rpms:
    lines.append('本阶段未生成 RPM。')
else:
    for p in rpms:
        h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
        lines.append('- `%s` — %d bytes — sha256 `%s`' % (os.path.basename(p), os.path.getsize(p), h))
text = '\n'.join(lines) + '\n'
with open(os.path.join(rep, 'VSG_BUILD_SUMMARY.md'), 'w', encoding='utf-8') as f:
    f.write(text)
print(text)
PY
}

case "$STAGE" in
  preflight) run "0 · 原生门禁" vsg-00-preflight.sh ;;
  source)    run "1 · 源码与依赖" vsg-10-fetch-source.sh ;;
  build)     run "2 · CMake 编译 / RPM" vsg-20-build.sh ;;
  install)   run "3 · RPM 安装与自测" vsg-40-install-test.sh ;;
  all)
    run "0 · 原生门禁" vsg-00-preflight.sh
    run "1 · 源码与依赖" vsg-10-fetch-source.sh
    run "2 · CMake 编译 / RPM" vsg-20-build.sh
    run "3 · RPM 安装与自测" vsg-40-install-test.sh
    ;;
  *) die "未知 STAGE=${STAGE}" ;;
esac
summarize
info "VSG NATIVE BUILD DONE (STAGE=${STAGE})"
