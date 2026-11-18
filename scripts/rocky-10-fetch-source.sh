#!/usr/bin/env bash
# 阶段 1：下载 Rocky 固定提交及依赖源码，并在私有前缀安装 header-only / 小库。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/rocky.env"

need_cmd curl "源码下载"; need_cmd tar "源码解压"
log "== 阶段 1 / FETCH ROCKY ${ROCKY_VERSION} + deps =="

SIG="${ROCKY_COMMIT}|${VULKAN_HEADERS_COMMIT}|${GLM_TAG}|${SPDLOG_TAG}|${NLOHMANN_JSON_TAG}|${CPP_HTTPLIB_TAG}|${ENTT_TAG}"
STAMP="${ROCKY_WORK}/.source-ready"
if [[ -f "${ROCKY_DEPS_PREFIX}/lib/cmake/EnTT/EnTTConfig.cmake" ]]; then
  ENTT_CONFIG="${ROCKY_DEPS_PREFIX}/lib/cmake/EnTT/EnTTConfig.cmake"
elif [[ -f "${ROCKY_DEPS_PREFIX}/lib64/cmake/EnTT/EnTTConfig.cmake" ]]; then
  ENTT_CONFIG="${ROCKY_DEPS_PREFIX}/lib64/cmake/EnTT/EnTTConfig.cmake"
else
  ENTT_CONFIG=""
fi
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$SIG" \
   && -f "${ROCKY_SRC_DIR}/CMakeLists.txt" \
   && -f "${VULKAN_SDK_PREFIX}/include/vulkan/vulkan.h" \
   && -f "${ROCKY_DEPS_PREFIX}/include/httplib.h" \
   && -f "${ROCKY_DEPS_PREFIX}/lib/cmake/glm/glmConfig.cmake" \
   && -f "${ROCKY_DEPS_PREFIX}/lib/cmake/spdlog/spdlogConfig.cmake" \
   && -f "${ROCKY_DEPS_PREFIX}/lib/cmake/nlohmann_json/nlohmann_jsonConfig.cmake" \
   && -n "$ENTT_CONFIG" ]]; then
  log "复用已缓存源码与依赖"
  stage_marker ROCKY_STAGE_1_SOURCE_OK PASS "${ROCKY_REPORT_DIR}/rocky-source-ok.json"
  info "ROCKY SOURCE PASS (cached)"; exit 0
fi

fetch_tar() {
  local name="$1" dest="$2" repo="$3" ref="$4"
  local tarball="${ROCKY_WORK}/${name}.tar.gz" url ok=0
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

main_sha="$(fetch_tar rocky "$ROCKY_SRC_DIR" 'pelicanmapping/rocky' "$ROCKY_COMMIT")"
grep -q 'VERSION 1.0.2' "${ROCKY_SRC_DIR}/CMakeLists.txt" || die "Rocky 版本不符"
grep -q 'PROJECT_VERSION_ABI 46' "${ROCKY_SRC_DIR}/CMakeLists.txt" || die "Rocky ABI 不符"

vulkan_sha="$(fetch_tar vulkan-headers "$VULKAN_HEADERS_SRC_DIR" 'KhronosGroup/Vulkan-Headers' "$VULKAN_HEADERS_COMMIT")"
grep -q '#define VK_HEADER_VERSION 268' "${VULKAN_HEADERS_SRC_DIR}/include/vulkan/vulkan_core.h" \
  || die "Vulkan-Headers 不是 1.3.268"
mkdir -p "${VULKAN_SDK_PREFIX}/include" "${VULKAN_SDK_PREFIX}/lib"
cp -a "${VULKAN_HEADERS_SRC_DIR}/include/." "${VULKAN_SDK_PREFIX}/include/"
ln -sfn /usr/lib64/libvulkan.so "${VULKAN_SDK_PREFIX}/lib/libvulkan.so"
ln -sfn /usr/lib64/libvulkan.so.1 "${VULKAN_SDK_PREFIX}/lib/libvulkan.so.1"

install_cmake_dep() {
  local name="$1" repo="$2" ref="$3"; shift 3
  local src="${ROCKY_WORK}/src/${name}-${ref}"
  fetch_tar "$name" "$src" "$repo" "$ref" >/dev/null
  cmake -G Ninja -S "$src" -B "${ROCKY_WORK}/build-${name}" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX="$ROCKY_DEPS_PREFIX" "$@" >/dev/null
  cmake --install "${ROCKY_WORK}/build-${name}" >/dev/null
}
install_cmake_dep glm g-truc/glm "$GLM_TAG" -DGLM_BUILD_TESTS=OFF
install_cmake_dep spdlog gabime/spdlog "$SPDLOG_TAG" -DSPDLOG_BUILD_SHARED=ON -DSPDLOG_BUILD_EXAMPLE=OFF -DSPDLOG_BUILD_TESTS=OFF
install_cmake_dep nlohmann-json nlohmann/json "$NLOHMANN_JSON_TAG" -DJSON_BuildTests=OFF
install_cmake_dep entt skypjack/entt "$ENTT_TAG" -DENTT_BUILD_TESTS=OFF -DENTT_BUILD_EXAMPLES=OFF -DENTT_BUILD_BENCHMARK=OFF

HTTP_SRC="${ROCKY_WORK}/src/httplib-${CPP_HTTPLIB_TAG}"
fetch_tar httplib "$HTTP_SRC" 'yhirose/cpp-httplib' "$CPP_HTTPLIB_TAG" >/dev/null
mkdir -p "${ROCKY_DEPS_PREFIX}/include"
cp -f "${HTTP_SRC}/httplib.h" "${ROCKY_DEPS_PREFIX}/include/"

python3 - "${ROCKY_REPORT_DIR}" "${main_sha}" "${vulkan_sha}" <<'PY'
import json, os, sys
rep, m, v = sys.argv[1:4]
data={'stage':'ROCKY_STAGE_1_SOURCE','sha256':{'rocky':m,'vulkan_headers':v},'verdict':'PASS'}
with open(os.path.join(rep,'rocky-source.json'),'w',encoding='utf-8') as f:
    json.dump(data,f,indent=2); f.write('\n')
print(json.dumps(data,indent=2))
PY
printf '%s\n' "$SIG" > "$STAMP"
stage_marker ROCKY_STAGE_1_SOURCE_OK PASS "${ROCKY_REPORT_DIR}/rocky-source-ok.json"
info "ROCKY SOURCE PASS"
