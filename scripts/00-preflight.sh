#!/usr/bin/env bash
# 阶段 0：原生银河麒麟 V10 构建门禁。
# 与旧版区别：不再要求 Docker / KYLIN_BASE_IMAGE / *.confirmed.env，
# 也不做在线 QGIS tag 校验（源码由 05-fetch-qgis-source.sh 实测校验）。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env

info "== 阶段 0 / NATIVE PREFLIGHT =="
log "QGIS ${QGIS_VERSION} (tag ${QGIS_GIT_TAG}, commit ${QGIS_GIT_COMMIT})"
log "目标 ${TARGET_OS} / ${TARGET_ARCH} / ${TARGET_CPU}"

[[ "$(id -u)" -ne 0 ]] || die "拒绝以 root 身份编译；runner 必须使用 actionsrunner 账户"
[[ "$(uname -m)" == "x86_64" ]] || die "不是 x86_64 架构"
[[ -f /etc/os-release ]] || die "缺少 /etc/os-release"
os_id="$(grep -E '^ID=' /etc/os-release | cut -d= -f2- | tr -d '"' | tr '[:upper:]' '[:lower:]')"
os_ver="$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2- | tr -d '"')"
[[ "$os_id" == *kylin* ]] || die "ID=${os_id} 不是银河麒麟；拒绝在非目标系统出包"
[[ "$os_ver" == *10* ]] || die "VERSION_ID=${os_ver} 不是 V10"
log "系统 $(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2-) / kernel $(uname -r)"

glibc="$(ldd --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
log "glibc ${glibc:-unknown}"

for cmd in git cmake gcc g++ python3 curl tar xz bzip2 sha256sum pkg-config; do
  need_cmd "$cmd" "基础构建工具链"
done
if ! command -v ninja >/dev/null 2>&1 && ! command -v make >/dev/null 2>&1; then
  die "缺少 ninja 与 make，至少需要一个构建后端"
fi

for cmd in rpm rpmbuild rpm2cpio cpio flex bison sip qmake patchelf; do
  if command -v "$cmd" >/dev/null 2>&1; then
    log "  工具 ${cmd}: $(command -v "$cmd")"
  else
    warn "  工具 ${cmd}: 未安装（记录，不阻断诊断阶段）"
  fi
done

avail="$(free_gb "${WORK_DIR}")"
log "可用磁盘 ${avail} GB（要求 >= ${MIN_FREE_GB} GB）"
(( avail >= MIN_FREE_GB )) || die "磁盘空间不足"

mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
log "物理内存 $((mem_kb / 1024)) MiB"
(( mem_kb >= 8 * 1024 * 1024 )) || die "内存不足 8 GiB，QGIS 全量编译风险过高"

python3 - "$REPORT_DIR/preflight.json" "$QGIS_VERSION" "$QGIS_GIT_TAG" \
        "$QGIS_GIT_COMMIT" "$os_id" "$os_ver" "$(uname -r)" "${glibc:-unknown}" \
        "$(id -un)" "$avail" "$mem_kb" <<'PY'
import datetime, json, sys
keys = ('version', 'tag', 'commit', 'os_id', 'os_version', 'kernel',
        'glibc', 'user', 'free_gb', 'mem_kb')
d = dict(zip(keys, sys.argv[2:]))
d['free_gb'] = int(d['free_gb'])
d['mem_kb'] = int(d['mem_kb'])
d['result'] = 'PASS'
d['recorded_at'] = datetime.datetime.utcnow().isoformat() + 'Z'
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
PY
cp -f "$REPORT_DIR/preflight.json" "${REPO_ROOT}/reports/preflight.json" 2>/dev/null || true
info "NATIVE PREFLIGHT PASS"
