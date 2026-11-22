#!/usr/bin/env bash
# 阶段 1：下载 VSG 固定提交与 Vulkan-Headers 1.2.131。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/vsg.env"

need_cmd curl "源码下载"; need_cmd tar "源码解压"
log "== 阶段 1 / FETCH VSG ${VSG_VERSION} + Vulkan Headers ${VULKAN_HEADERS_LABEL} =="

# GCC7 aarch64 下 vsg::ref_ptr<vsg::Duplicate> 的 inline 构造未被实例化，
# 导致 libvsg.so 缺符号。显式实例化修复（由 B 设备配置开关启用）。
patch_vsg_gcc7() {
  [[ "${VSG_PATCH_GCC7_DUP:-false}" == "true" ]] || return 0
  local cpp="${VSG_SRC_DIR}/src/vsg/core/Object.cpp"
  [[ -f "$cpp" ]] || die "VSG Object.cpp 不存在"
  if grep -q 'B_DEVICE_DUP_INSTANTIATION' "$cpp"; then
    log "VSG Duplicate 显式实例化已存在"
    return 0
  fi
  cat >> "$cpp" <<'EOF'

// B_DEVICE_DUP_INSTANTIATION: aarch64/GCC7 inline template instantiation workaround
template class ref_ptr<Duplicate>;
EOF
  log "已为 VSG Object.cpp 添加 ref_ptr<Duplicate> 显式实例化"
}

PATCH_TAG="${VSG_PATCH_GCC7_DUP:-false}"
SIG="${VSG_COMMIT}|${VULKAN_HEADERS_COMMIT}|v2|${PATCH_TAG}"
STAMP="${VSG_WORK}/.source-ready"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$SIG" \
   && -f "${VSG_SRC_DIR}/CMakeLists.txt" \
   && -f "${VULKAN_SDK_PREFIX}/include/vulkan/vulkan.h" ]]; then
  log "复用已缓存源码与 Vulkan 头文件"
  patch_vsg_gcc7
  stage_marker VSG_STAGE_1_SOURCE_OK PASS "${VSG_REPORT_DIR}/vsg-source-ok.json"
  info "VSG SOURCE PASS (cached)"; exit 0
fi

fetch_tar() {
  local name="$1" dest="$2" repo="$3" ref="$4"
  local tarball="${VSG_WORK}/${name}.tar.gz" url ok=0
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

main_sha="$(fetch_tar vsg "$VSG_SRC_DIR" 'vsg-dev/VulkanSceneGraph' "$VSG_COMMIT")"
grep -q 'VERSION 1.1.13' "${VSG_SRC_DIR}/CMakeLists.txt" || die "VSG 版本不符"
grep -q 'set(VSG_SOVERSION 15)' "${VSG_SRC_DIR}/CMakeLists.txt" || die "VSG SOVERSION 不符"
patch_vsg_gcc7

vulkan_sha="$(fetch_tar vulkan-headers "$VULKAN_HEADERS_SRC_DIR" 'KhronosGroup/Vulkan-Headers' "$VULKAN_HEADERS_COMMIT")"
grep -q '#define VK_HEADER_VERSION 131' "${VULKAN_HEADERS_SRC_DIR}/include/vulkan/vulkan_core.h" \
  || die "Vulkan-Headers 不是 1.2.131"

mkdir -p "${VULKAN_SDK_PREFIX}/include" "${VULKAN_SDK_PREFIX}/lib"
cp -a "${VULKAN_HEADERS_SRC_DIR}/include/." "${VULKAN_SDK_PREFIX}/include/"
ln -sfn /usr/lib64/libvulkan.so "${VULKAN_SDK_PREFIX}/lib/libvulkan.so"
ln -sfn /usr/lib64/libvulkan.so.1 "${VULKAN_SDK_PREFIX}/lib/libvulkan.so.1"

python3 - "${VSG_REPORT_DIR}" "${main_sha}" "${vulkan_sha}" <<'PY'
import json, os, sys
rep, v, h = sys.argv[1:4]
data={'stage':'VSG_STAGE_1_SOURCE','sha256':{'vsg':v,'vulkan_headers':h},'verdict':'PASS'}
with open(os.path.join(rep,'vsg-source.json'),'w',encoding='utf-8') as f:
    json.dump(data,f,indent=2); f.write('\n')
print(json.dumps(data,indent=2))
PY
printf '%s\n' "$SIG" > "$STAMP"
stage_marker VSG_STAGE_1_SOURCE_OK PASS "${VSG_REPORT_DIR}/vsg-source-ok.json"
info "VSG SOURCE PASS"
