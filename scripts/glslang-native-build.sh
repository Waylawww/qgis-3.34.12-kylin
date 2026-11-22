#!/usr/bin/env bash
# glslang 原生构建总入口（Kylin V10 self-hosted runner）。
# 阶段：preflight / source / build / install / all
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT="$ROOT"
source "$ROOT/scripts/lib/common.sh"
load_build_env
source "$ROOT/config/glslang.env"

export GLSLANG_WORK="${GLSLANG_WORK:-${WORK_DIR}/glslang-1610}"
export GLSLANG_SRC_DIR="${GLSLANG_WORK}/src/glslang-${GLSLANG_VERSION}"
export GLSLANG_BUILD_DIR="${GLSLANG_WORK}/build"
export GLSLANG_STAGE_DIR="${GLSLANG_WORK}/stage"
export GLSLANG_LOCAL_ROOT="${GLSLANG_WORK}/local-install"
export GLSLANG_RPM_ROOT="${GLSLANG_WORK}/rpm-install"
export GLSLANG_TOOLS_DIR="${GLSLANG_WORK}/tools"
export GLSLANG_RPM_TOP="${GLSLANG_WORK}/rpmbuild"
export GLSLANG_REPORT_DIR="${GLSLANG_REPORT_DIR:-${REPORT_DIR}}"
export GLSLANG_OUT_DIR="${GLSLANG_OUT_DIR:-${OUT_DIR}}"
export GLSLANG_BUILD_JOBS="${GLSLANG_BUILD_JOBS:-${QGIS_BUILD_JOBS:-4}}"
mkdir -p "$GLSLANG_WORK" "$GLSLANG_REPORT_DIR" "$GLSLANG_REPORT_DIR/logs" \
         "$GLSLANG_OUT_DIR/rpms" "$GLSLANG_RPM_TOP/SPECS" "$GLSLANG_RPM_TOP/RPMS"

STAGE="${STAGE:-all}"
info "=============================================================="
info "Native glslang ${GLSLANG_VERSION} build | STAGE=${STAGE}"
info "user=$(id -un) host=$(hostname) arch=$(uname -m) kernel=$(uname -r)"
info "WORK=$GLSLANG_WORK OUT=$GLSLANG_OUT_DIR REPORT=$GLSLANG_REPORT_DIR"
info "=============================================================="

run() {
  local name="$1" script="$2"
  info "---------- ${name} ----------"
  [[ -f "$ROOT/scripts/$script" ]] || die "阶段 ${name} 所需脚本 scripts/$script 不存在"
  bash "$ROOT/scripts/$script" 2>&1 | tee "$GLSLANG_REPORT_DIR/logs/${script%.sh}.log"
}

summarize() {
  python3 - "$GLSLANG_REPORT_DIR" "$GLSLANG_OUT_DIR" "$STAGE" "$GLSLANG_VERSION" <<'PY'
import datetime, glob, hashlib, json, os, sys
rep, out, stage, version = sys.argv[1:5]
lines = ['# glslang %s · Kylin V10 原生构建报告' % version, '',
         '- stage: `%s`' % stage,
         '- generated: %sZ' % datetime.datetime.utcnow().isoformat(),
         '- host: `%s` / user: `%s`' % (os.uname().nodename, os.popen('id -un').read().strip()), '',
         '## RPM 产物', '']
rpms = sorted(glob.glob(os.path.join(out, 'rpms', 'glslang*.rpm')))
if not rpms:
    lines.append('本阶段未生成 RPM。')
else:
    for p in rpms:
        h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
        lines.append('- `%s` — %d bytes — sha256 `%s`' % (os.path.basename(p), os.path.getsize(p), h))
lines += ['', '## 证据文件', '']
for name in sorted(os.listdir(rep)):
    if os.path.isfile(os.path.join(rep, name)):
        lines.append('- `%s`' % name)
text = '\n'.join(lines) + '\n'
with open(os.path.join(rep, 'GLSLANG_BUILD_SUMMARY.md'), 'w', encoding='utf-8') as f:
    f.write(text)
print(text)
PY
}

case "$STAGE" in
  preflight) run "0 · 原生门禁" glslang-00-preflight.sh ;;
  source)    run "1 · 官方源码与 External 依赖" glslang-10-fetch-source.sh ;;
  build)     run "2 · CMake 编译 / ctest / RPM" glslang-20-build.sh ;;
  install)   run "3 · RPM 安装与自测" glslang-40-install-test.sh ;;
  all)
    run "0 · 原生门禁" glslang-00-preflight.sh
    run "1 · 官方源码与 External 依赖" glslang-10-fetch-source.sh
    run "2 · CMake 编译 / ctest / RPM" glslang-20-build.sh
    run "3 · RPM 安装与自测" glslang-40-install-test.sh
    ;;
  *) die "未知 STAGE=${STAGE}（可用: preflight / source / build / install / all）" ;;
esac
summarize
info "GLSLANG NATIVE BUILD DONE (STAGE=${STAGE})"
