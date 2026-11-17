#!/usr/bin/env bash
# Assimp 6.0.5 原生构建总入口（与 QGIS 共用 Kylin V10 self-hosted runner）。
# 阶段：preflight / source / build / install / all
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT="$ROOT"
source "$ROOT/scripts/lib/common.sh"
load_build_env
source "$ROOT/config/assimp.env"

export ASSIMP_WORK="${ASSIMP_WORK:-${WORK_DIR}/assimp-605}"
export ASSIMP_SRC_DIR="${ASSIMP_WORK}/src/assimp-${ASSIMP_VERSION}"
export ASSIMP_BUILD_DIR="${ASSIMP_WORK}/build"
export ASSIMP_STAGE_DIR="${ASSIMP_WORK}/stage"
export ASSIMP_LOCAL_ROOT="${ASSIMP_WORK}/local-install"
export ASSIMP_RPM_ROOT="${ASSIMP_WORK}/rpm-install"
export ASSIMP_TOOLS_DIR="${ASSIMP_WORK}/tools"
export ASSIMP_RPM_TOP="${ASSIMP_WORK}/rpmbuild"
export ASSIMP_REPORT_DIR="${ASSIMP_REPORT_DIR:-${REPORT_DIR}}"
export ASSIMP_OUT_DIR="${ASSIMP_OUT_DIR:-${OUT_DIR}}"
export ASSIMP_BUILD_JOBS="${ASSIMP_BUILD_JOBS:-${QGIS_BUILD_JOBS:-4}}"
mkdir -p "$ASSIMP_WORK" "$ASSIMP_REPORT_DIR" "$ASSIMP_REPORT_DIR/logs" \
         "$ASSIMP_OUT_DIR/rpms" "$ASSIMP_RPM_TOP/SPECS" "$ASSIMP_RPM_TOP/RPMS"

STAGE="${STAGE:-all}"
info "=============================================================="
info "Native Assimp ${ASSIMP_VERSION} build | STAGE=${STAGE}"
info "user=$(id -un) host=$(hostname) arch=$(uname -m) kernel=$(uname -r)"
info "REPO_ROOT=$ROOT"
info "WORK=$ASSIMP_WORK OUT=$ASSIMP_OUT_DIR REPORT=$ASSIMP_REPORT_DIR"
info "=============================================================="

run() {
  local name="$1" script="$2"
  info "---------- ${name} ----------"
  [[ -f "$ROOT/scripts/$script" ]] || die "阶段 ${name} 所需脚本 scripts/$script 不存在"
  bash "$ROOT/scripts/$script" 2>&1 | tee "$ASSIMP_REPORT_DIR/logs/${script%.sh}.log"
}

summarize() {
  python3 - "$ASSIMP_REPORT_DIR" "$ASSIMP_OUT_DIR" "$STAGE" "$ASSIMP_VERSION" <<'PY'
import datetime, glob, hashlib, json, os, sys
rep, out, stage, version = sys.argv[1:5]
lines = ['# Assimp %s · Kylin V10 原生构建报告' % version, '',
         '- stage: `%s`' % stage,
         '- generated: %sZ' % datetime.datetime.utcnow().isoformat(),
         '- host: `%s` / user: `%s`' % (os.uname().nodename, os.popen('id -un').read().strip()), '',
         '## RPM 产物', '']
rpms = sorted(glob.glob(os.path.join(out, 'rpms', 'assimp*.rpm')))
if not rpms:
    lines.append('本阶段未生成 RPM。')
else:
    for p in rpms:
        h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
        lines.append('- `%s` — %d bytes — sha256 `%s`' % (os.path.basename(p), os.path.getsize(p), h))
lines += ['', '## 证据文件', '']
for name in sorted(os.listdir(rep)):
    p = os.path.join(rep, name)
    if os.path.isfile(p):
        lines.append('- `%s` (%d bytes)' % (name, os.path.getsize(p)))
for d in ('install-selftest', 'logs'):
    dp = os.path.join(rep, d)
    if os.path.isdir(dp):
        lines.append('- `%s/` (%d files)' % (d, len(os.listdir(dp))))
text = '\n'.join(lines) + '\n'
with open(os.path.join(rep, 'ASSIMP_BUILD_SUMMARY.md'), 'w', encoding='utf-8') as f:
    f.write(text)
print(text)
PY
}

case "$STAGE" in
  preflight)
    run "0 · 原生门禁" assimp-00-preflight.sh
    ;;
  source)
    run "1 · 官方源码 + 本地补丁" assimp-10-fetch-source.sh
    ;;
  build)
    run "2 · CMake 编译 / 测试 / 安装 / RPM" assimp-20-build.sh
    ;;
  install)
    run "3 · RPM 安装与自测" assimp-40-install-test.sh
    ;;
  all)
    run "0 · 原生门禁" assimp-00-preflight.sh
    run "1 · 官方源码 + 本地补丁" assimp-10-fetch-source.sh
    run "2 · CMake 编译 / 测试 / 安装 / RPM" assimp-20-build.sh
    run "3 · RPM 安装与自测" assimp-40-install-test.sh
    ;;
  *)
    die "未知 STAGE=${STAGE}（可用: preflight / source / build / install / all）"
    ;;
esac
summarize
info "ASSIMP NATIVE BUILD DONE (STAGE=${STAGE})"
