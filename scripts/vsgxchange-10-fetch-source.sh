#!/usr/bin/env bash
# 阶段 1：下载 vsgXchange 固定提交源码。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/vsgxchange.env"

need_cmd curl "源码下载"; need_cmd tar "源码解压"
log "== 阶段 1 / FETCH VSGXCHANGE ${VSGXCHANGE_VERSION} =="

SIG="${VSGXCHANGE_COMMIT}|v1"
STAMP="${VSGXCHANGE_WORK}/.source-ready"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$SIG" && -f "${VSGXCHANGE_SRC_DIR}/CMakeLists.txt" ]]; then
  log "复用已缓存源码"
  stage_marker VSGXCHANGE_STAGE_1_SOURCE_OK PASS "${VSGXCHANGE_REPORT_DIR}/vsgxchange-source-ok.json"
  info "VSGXCHANGE SOURCE PASS (cached)"; exit 0
fi

fetch_tar() {
  local name="$1" dest="$2" repo="$3" ref="$4"
  local tarball="${VSGXCHANGE_WORK}/${name}.tar.gz" url ok=0
  rm -f "$tarball"
  for url in \
    "https://ghproxy.net/https://github.com/${repo}/archive/${ref}.tar.gz" \
    "https://codeload.github.com/${repo}/tar.gz/${ref}" \
    "https://github.com/${repo}/archive/${ref}.tar.gz"; do
    log "${name}: 尝试 ${url}"
    if curl -fL --retry 4 --retry-delay 3 --connect-timeout 20 --max-time 1800 \
         -o "$tarball" "$url" && tar -tzf "$tarball" >/dev/null 2>&1; then ok=1; break; fi
    rm -f "$tarball"
  done
  [[ "$ok" -eq 1 ]] || die "${name} 下载失败"
  rm -rf "$dest"; mkdir -p "$dest"
  tar -xzf "$tarball" --strip-components=1 -C "$dest"
  sha256sum "$tarball" | awk '{print $1}'
}

main_sha="$(fetch_tar vsgxchange "$VSGXCHANGE_SRC_DIR" 'vsg-dev/vsgXchange' "$VSGXCHANGE_COMMIT")"
grep -q 'VERSION 1.1.9' "${VSGXCHANGE_SRC_DIR}/CMakeLists.txt" || die "vsgXchange 版本不符"
grep -q 'VSGXCHANGE_SOVERSION 2' "${VSGXCHANGE_SRC_DIR}/CMakeLists.txt" || die "vsgXchange SOVERSION 不符"

python3 - "${VSGXCHANGE_REPORT_DIR}" "${main_sha}" <<'PY'
import json, os, sys
rep, sha = sys.argv[1:3]
data={'stage':'VSGXCHANGE_STAGE_1_SOURCE','sha256':{'vsgXchange':sha},'verdict':'PASS'}
with open(os.path.join(rep,'vsgxchange-source.json'),'w',encoding='utf-8') as f:
    json.dump(data,f,indent=2); f.write('\n')
print(json.dumps(data,indent=2))
PY
printf '%s\n' "$SIG" > "$STAMP"
stage_marker VSGXCHANGE_STAGE_1_SOURCE_OK PASS "${VSGXCHANGE_REPORT_DIR}/vsgxchange-source-ok.json"
info "VSGXCHANGE SOURCE PASS"
