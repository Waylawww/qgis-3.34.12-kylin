#!/usr/bin/env bash
# QGIS 3.34.12 原生构建总入口（由 self-hosted runner 以 actionsrunner 调用）。
# 所有阶段都把完整输出留在 REPORT_DIR/logs，失败时通过 artifact 上传。
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT="$ROOT"
source "$ROOT/scripts/lib/common.sh"
load_build_env

export WORK_DIR="${WORK_DIR:-${RUNNER_TEMP:-$ROOT}/qgis-33412-work}"
export OUT_DIR="${OUT_DIR:-${RUNNER_TEMP:-$ROOT}/qgis-33412-out}"
export REPORT_DIR="${REPORT_DIR:-${RUNNER_TEMP:-$ROOT}/qgis-33412-reports}"
export LOG_DIR="$REPORT_DIR/logs"
mkdir -p "$WORK_DIR" "$OUT_DIR/rpms" "$OUT_DIR/srpms" "$REPORT_DIR/logs" "$REPORT_DIR/stages"

STAGE="${STAGE:-diagnose}"
info "=============================================================="
info "Native QGIS ${QGIS_VERSION} build | STAGE=${STAGE}"
info "user=$(id -un) host=$(hostname) arch=$(uname -m) kernel=$(uname -r)"
info "REPO_ROOT=$ROOT"
info "DEPS_PREFIX=${DEPS_PREFIX:-<unset>}"
info "WORK_DIR=$WORK_DIR  OUT_DIR=$OUT_DIR  REPORT_DIR=$REPORT_DIR"
info "=============================================================="

run() {
  local name="$1" script="$2"
  info "---------- ${name} ----------"
  if [[ ! -f "$ROOT/scripts/$script" ]]; then
    die "阶段 ${name} 所需脚本 scripts/$script 不存在（拒绝伪造成功）"
  fi
  bash "$ROOT/scripts/$script" 2>&1 | tee "$LOG_DIR/${script%.sh}.log"
}

summarize() {
  python3 - "$REPORT_DIR" "$OUT_DIR" "$STAGE" "$QGIS_VERSION" <<'PY'
import datetime, glob, hashlib, json, os, sys
rep, out, stage, version = sys.argv[1:5]
lines = ['# QGIS %s · Kylin V10 原生构建报告' % version, '',
         '- stage: `%s`' % stage,
         '- generated: %sZ' % datetime.datetime.utcnow().isoformat(),
         '- host: `%s` / user: `%s`' % (os.uname().nodename, os.popen('id -un').read().strip()), '',
         '## RPM 产物', '']
rpms = sorted(glob.glob(os.path.join(out, 'rpms', '*.rpm')))
if not rpms:
    lines.append('本阶段未生成 RPM（diagnose 阶段属预期）。')
else:
    for p in rpms:
        h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
        lines.append('- `%s` — %d bytes — sha256 `%s`' % (os.path.basename(p), os.path.getsize(p), h))
lines += ['', '## 报告文件', '']
for name in sorted(os.listdir(rep)):
    p = os.path.join(rep, name)
    if os.path.isfile(p):
        lines.append('- `%s` (%d bytes)' % (name, os.path.getsize(p)))
with open(os.path.join(rep, 'BUILD_SUMMARY.md'), 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')
print('\n'.join(lines))
PY
}

case "$STAGE" in
  diagnose)
    run "0 · 原生门禁" 00-preflight.sh
    run "1 · 官方源码下载与校验" 05-fetch-qgis-source.sh
    run "1b · CMake 真实依赖探测" 06-cmake-probe.sh
    summarize
    info "DIAGNOSE PASS —— 已取得真实主机环境、依赖矩阵、源码与 CMake 缺失清单"
    ;;
  deps)
    run "2 · 依赖源码构建" 20-build-deps.sh
    summarize
    ;;
  qgis)
    run "3 · QGIS 编译 / DESTDIR 安装 / rpmbuild" 30-build-qgis.sh
    run "4 · RPM 静态校验" 40-verify-rpm.sh
    summarize
    ;;
  install)
    run "7 · 本机安装已构建 RPM（受限 sudo）" 70-install-rpm.sh
    summarize
    ;;
  all)
    run "0 · 原生门禁" 00-preflight.sh
    run "1 · 官方源码下载与校验" 05-fetch-qgis-source.sh
    run "2 · 依赖源码构建" 20-build-deps.sh
    run "3 · QGIS 编译 / DESTDIR 安装 / rpmbuild" 30-build-qgis.sh
    run "4 · RPM 静态校验" 40-verify-rpm.sh
    summarize
    ;;
  *)
    die "未知 STAGE=${STAGE}（可用: diagnose / deps / qgis / install / all）"
    ;;
esac

info "NATIVE BUILD DONE (STAGE=${STAGE})"
