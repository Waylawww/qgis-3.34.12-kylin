#!/usr/bin/env bash
# 阶段 1：下载 osg2vsg 及其私有依赖 OSG / VSG 的固定 commit 源码。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/osg2vsg.env"

need_cmd curl "源码下载"; need_cmd tar "源码解压"
log "== 阶段 1 / FETCH OSG2VSG ${OSG2VSG_VERSION} + OSG ${OSG_VERSION} + VSG ${VSG_VERSION} =="

SIG="${OSG2VSG_COMMIT}|${OSG_COMMIT}|${VSG_COMMIT}"
STAMP="${OSG2VSG_WORK}/.source-ready"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$SIG" \
   && -f "${OSG2VSG_SRC_DIR}/CMakeLists.txt" \
   && -f "${OSG_SRC_DIR}/CMakeLists.txt" \
   && -f "${VSG_SRC_DIR}/CMakeLists.txt" ]]; then
  log "复用已缓存的三份源码"
  stage_marker OSG2VSG_STAGE_1_SOURCE_OK PASS "${OSG2VSG_REPORT_DIR}/osg2vsg-source-ok.json"
  info "OSG2VSG SOURCE PASS (cached)"; exit 0
fi

fetch_tar() {
  local name="$1" dest="$2" repo="$3" commit="$4"
  local tarball="${OSG2VSG_WORK}/${name}.tar.gz" url ok=0
  rm -f "$tarball"
  for url in \
    "https://ghproxy.net/https://github.com/${repo}/archive/${commit}.tar.gz" \
    "https://codeload.github.com/${repo}/tar.gz/${commit}" \
    "https://github.com/${repo}/archive/${commit}.tar.gz"; do
    log "${name}: 尝试 ${url}"
    if curl -fL --retry 4 --retry-delay 3 --connect-timeout 20 --max-time 1800 \
         -o "$tarball" "$url" && tar -tzf "$tarball" >/dev/null 2>&1; then ok=1; break; fi
    rm -f "$tarball"
  done
  [[ "$ok" -eq 1 ]] || die "${name} 所有下载地址失败"
  rm -rf "$dest"; mkdir -p "$dest"
  tar -xzf "$tarball" --strip-components=1 -C "$dest"
  sha256sum "$tarball" | awk '{print $1}'
}

m="$(fetch_tar osg2vsg "$OSG2VSG_SRC_DIR" 'vsg-dev/osg2vsg' "$OSG2VSG_COMMIT")"
o="$(fetch_tar osg "$OSG_SRC_DIR" 'openscenegraph/OpenSceneGraph' "$OSG_COMMIT")"
v="$(fetch_tar vsg "$VSG_SRC_DIR" 'vsg-dev/VulkanSceneGraph' "$VSG_COMMIT")"
grep -q 'VERSION 0.4.0' "${OSG2VSG_SRC_DIR}/CMakeLists.txt" || die "osg2vsg 版本不符"
grep -q 'set(OPENSCENEGRAPH_MAJOR_VERSION 3)' "${OSG_SRC_DIR}/CMakeLists.txt" || die "OSG 版本不符"
grep -q 'find_package(Vulkan)' "${VSG_SRC_DIR}/CMakeLists.txt" || die "VSG 源码不完整"

python3 - "${OSG2VSG_REPORT_DIR}" "${m}" "${o}" "${v}" <<'PY'
import json, os, sys
rep, m, o, v = sys.argv[1:5]
data={'stage':'OSG2VSG_STAGE_1_SOURCE','sha256':{'osg2vsg':m,'osg':o,'vsg':v},'verdict':'PASS'}
with open(os.path.join(rep,'osg2vsg-source.json'),'w',encoding='utf-8') as f:
    json.dump(data,f,indent=2); f.write('\n')
print(json.dumps(data,indent=2))
PY
printf '%s\n' "$SIG" > "$STAMP"
stage_marker OSG2VSG_STAGE_1_SOURCE_OK PASS "${OSG2VSG_REPORT_DIR}/osg2vsg-source-ok.json"
info "OSG2VSG SOURCE PASS"
