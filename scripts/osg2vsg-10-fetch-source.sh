#!/usr/bin/env bash
# 阶段 1：下载 osg2vsg 及其私有依赖 OSG / VSG 的固定 commit 源码。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/osg2vsg.env"

need_cmd curl "源码下载"; need_cmd tar "源码解压"
log "== 阶段 1 / FETCH OSG2VSG ${OSG2VSG_VERSION} + OSG ${OSG_VERSION} + VSG ${VSG_VERSION} =="

# 可选源码补丁（B 设备跳过 applications；A 设备未配置则跳过）
PATCH_SHA_CONFIG=''
if [[ -n "${OSG2VSG_PATCH_REL:-}" ]]; then
  PATCH="${REPO_ROOT}/${OSG2VSG_PATCH_REL}"
  [[ -f "$PATCH" ]] || die "缺少补丁 ${OSG2VSG_PATCH_REL}"
  PATCH_SHA_CONFIG="$(sha256sum "$PATCH" | awk '{print $1}')"
  [[ "$PATCH_SHA_CONFIG" == "${OSG2VSG_PATCH_SHA256:-}" ]] \
    || die "补丁指纹不符：期望 ${OSG2VSG_PATCH_SHA256}，实际 ${PATCH_SHA_CONFIG}"
fi

SIG="v4|${OSG2VSG_COMMIT}|${OSG_COMMIT}|${VSG_COMMIT}|${VULKAN_HEADERS_COMMIT}|${PATCH_SHA_CONFIG}"
STAMP="${OSG2VSG_WORK}/.source-ready"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$SIG" \
   && -f "${OSG2VSG_SRC_DIR}/CMakeLists.txt" \
   && -f "${OSG_SRC_DIR}/CMakeLists.txt" \
   && -f "${VSG_SRC_DIR}/CMakeLists.txt" \
   && -f "${VULKAN_SDK_PREFIX}/include/vulkan/vulkan.h" ]]; then
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
vh="$(fetch_tar vulkan-headers "$VULKAN_HEADERS_SRC_DIR" 'KhronosGroup/Vulkan-Headers' "$VULKAN_HEADERS_COMMIT")"
mkdir -p "${VULKAN_SDK_PREFIX}/include" "${VULKAN_SDK_PREFIX}/lib"
cp -a "${VULKAN_HEADERS_SRC_DIR}/include/." "${VULKAN_SDK_PREFIX}/include/"
ln -sfn /usr/lib64/libvulkan.so "${VULKAN_SDK_PREFIX}/lib/libvulkan.so"
ln -sfn /usr/lib64/libvulkan.so.1 "${VULKAN_SDK_PREFIX}/lib/libvulkan.so.1"
grep -q '#define VK_HEADER_VERSION 131' "${VULKAN_SDK_PREFIX}/include/vulkan/vulkan_core.h" \
  || die "Vulkan-Headers 版本不是 1.2.131"
grep -q 'VERSION 0.4.0' "${OSG2VSG_SRC_DIR}/CMakeLists.txt" || die "osg2vsg 版本不符"
grep -qi 'SET(OPENSCENEGRAPH_MAJOR_VERSION 3)' "${OSG_SRC_DIR}/CMakeLists.txt" || die "OSG 版本不符"
grep -q 'find_package(Vulkan' "${VSG_SRC_DIR}/CMakeLists.txt" || die "VSG 源码不完整"

# 应用可选补丁（B 设备跳过 applications），幂等处理。
if [[ -n "${OSG2VSG_PATCH_REL:-}" ]]; then
  if grep -q 'skip them' "${OSG2VSG_SRC_DIR}/CMakeLists.txt"; then
    log "补丁已应用，跳过"
  else
    ( cd "$OSG2VSG_SRC_DIR" && git apply --check "$PATCH" ) \
      || ( cd "$OSG2VSG_SRC_DIR" && patch -p1 --dry-run --forward < "$PATCH" ) \
      || die "补丁 ${OSG2VSG_PATCH_REL} 无法应用"
    ( cd "$OSG2VSG_SRC_DIR" && git apply "$PATCH" ) \
      || ( cd "$OSG2VSG_SRC_DIR" && patch -p1 --forward < "$PATCH" ) \
      || die "补丁应用失败"
  fi
  grep -q 'skip them' "${OSG2VSG_SRC_DIR}/CMakeLists.txt" \
    || die "补丁应用后仍未跳过 applications"
  log "已应用补丁 ${OSG2VSG_PATCH_REL} (sha256=${PATCH_SHA_CONFIG})"
fi

python3 - "${OSG2VSG_REPORT_DIR}" "${m}" "${o}" "${v}" "${vh}" "${PATCH_SHA_CONFIG}" <<'PY'
import json, os, sys
rep, m, o, v, vh, patch_sha = sys.argv[1:7]
data={'stage':'OSG2VSG_STAGE_1_SOURCE','sha256':{'osg2vsg':m,'osg':o,'vsg':v,'vulkan_headers':vh,'patch':patch_sha},'verdict':'PASS'}
with open(os.path.join(rep,'osg2vsg-source.json'),'w',encoding='utf-8') as f:
    json.dump(data,f,indent=2); f.write('\n')
print(json.dumps(data,indent=2))
PY
printf '%s\n' "$SIG" > "$STAMP"
stage_marker OSG2VSG_STAGE_1_SOURCE_OK PASS "${OSG2VSG_REPORT_DIR}/osg2vsg-source-ok.json"
info "OSG2VSG SOURCE PASS"
