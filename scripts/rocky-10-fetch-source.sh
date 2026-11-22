#!/usr/bin/env bash
# 阶段 1：下载 Rocky 固定提交及依赖源码，并在私有前缀安装 header-only / 小库。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/rocky.env"

need_cmd curl "源码下载"; need_cmd tar "源码解压"
log "== 阶段 1 / FETCH ROCKY ${ROCKY_VERSION} + deps =="

patch_no_imgui() {
  python3 - \
    "${ROCKY_SRC_DIR}/src/rocky/CMakeLists.txt" \
    "${ROCKY_SRC_DIR}/src/rocky/vsg/Application.h" \
    "${ROCKY_SRC_DIR}/src/rocky/vsg/Application.cpp" \
    "${ROCKY_SRC_DIR}/src/rocky/vsg/ecs/ECSNode.cpp" \
    "${ROCKY_SRC_DIR}/src/CMakeLists.txt" <<'PY'
import sys
cmake_path, header_path, app_path, ecs_path, src_cmake_path = sys.argv[1:6]

def edit(path, pairs):
    s = open(path, encoding='utf-8').read()
    changed = False
    for old, new, marker in pairs:
        if marker in s:
            continue
        if old in s:
            s = s.replace(old, new, 1)
            changed = True
    if changed:
        open(path, 'w', encoding='utf-8').write(s)
        print('patched ' + path.rsplit('/', 1)[-1])

edit(header_path, [(
    '    class RenderImGuiContext;\n',
    '''#ifdef ROCKY_HAS_IMGUI
    class RenderImGuiContext;
#else
    using RenderImGuiContext = vsg::Node;
#endif
''',
    'using RenderImGuiContext = vsg::Node;\n#endif')])

edit(app_path, [
    ('#include "ecs/LabelSystem.h"\n',
     '#ifdef ROCKY_HAS_IMGUI\n#include "ecs/LabelSystem.h"\n#endif\n',
     '#ifdef ROCKY_HAS_IMGUI\n#include "ecs/LabelSystem.h"\n#endif'),
    ('    ecsNode->add(LabelSystemNode::create(registry));   \n',
     '#ifdef ROCKY_HAS_IMGUI\n    ecsNode->add(LabelSystemNode::create(registry));\n#endif\n',
     '#ifdef ROCKY_HAS_IMGUI\n    ecsNode->add(LabelSystemNode::create(registry));\n#endif'),
    ('#ifndef ROCKY_HAS_IMGUI\nusing RenderImGuiContext = vsg::Node;\n#endif\n',
     '',
     'MARKER_ALIAS_NEVER_PRESENT'),
])

edit(ecs_path, [
    ('#include "LabelSystem.h"\n',
     '#ifdef ROCKY_HAS_IMGUI\n#include "LabelSystem.h"\n#endif\n',
     '#ifdef ROCKY_HAS_IMGUI\n#include "LabelSystem.h"\n#endif'),
    ('        add(LabelSystemNode::create(registry));\n',
     '#ifdef ROCKY_HAS_IMGUI\n        add(LabelSystemNode::create(registry));\n#endif\n',
     '#ifdef ROCKY_HAS_IMGUI\n        add(LabelSystemNode::create(registry));\n#endif'),
    ('        add(LabelSystem::create(registry));\n',
     '#ifdef ROCKY_HAS_IMGUI\n        add(LabelSystem::create(registry));\n#endif\n',
     '#ifdef ROCKY_HAS_IMGUI\n        add(LabelSystem::create(registry));\n#endif'),
])

edit(cmake_path, [(
    '    file(GLOB HEADERS_VSG_ECS vsg/ecs/*.h)\n    file(GLOB SOURCES_VSG_ECS vsg/ecs/*.cpp)\n',
    '''    file(GLOB HEADERS_VSG_ECS vsg/ecs/*.h)
    file(GLOB SOURCES_VSG_ECS vsg/ecs/*.cpp)
    if(NOT ROCKY_HAS_IMGUI)
      list(FILTER HEADERS_VSG_ECS EXCLUDE REGEX "LabelSystem")
      list(FILTER SOURCES_VSG_ECS EXCLUDE REGEX "LabelSystem")
    endif()
''',
    'list(FILTER SOURCES_VSG_ECS EXCLUDE REGEX "LabelSystem")')])

edit(src_cmake_path, [(
    'add_subdirectory(apps)\n',
    '# add_subdirectory(apps) # disabled: bundled demo targets need a newer VSG than 1.1.13\n',
    '# add_subdirectory(apps) # disabled: bundled demo targets need a newer VSG than 1.1.13')])
PY
}

# GCC7 (Kylin V10) 无 <filesystem>，但有 <experimental/filesystem>。
# 将 rocky 源码中的 std::filesystem 映射到 std::experimental::filesystem。
patch_filesystem() {
  [[ "${ROCKY_FS_COMPAT:-}" == "experimental" ]] || return 0
  log "patch filesystem -> std::experimental::filesystem (GCC7 compat)"
  python3 - "${ROCKY_SRC_DIR}/src" <<'PY'
import os, sys
root = sys.argv[1]
changed = 0
for dirpath, _, names in os.walk(root):
    for name in names:
        if not name.endswith(('.h', '.hpp', '.hh', '.cpp', '.cc', '.cxx')):
            continue
        p = os.path.join(dirpath, name)
        with open(p, encoding='utf-8', errors='surrogateescape') as f:
            src = f.read()
        out = src.replace('#include <filesystem>', '#include <experimental/filesystem>')
        out = out.replace('std::filesystem::', 'std::experimental::filesystem::')
        out = out.replace('namespace std { namespace filesystem',
                          'namespace std { namespace experimental { namespace filesystem')
        if out != src:
            with open(p, 'w', encoding='utf-8', errors='surrogateescape') as f:
                f.write(out)
            changed += 1
            print('patched fs: ' + os.path.relpath(p, root))
print('filesystem patched files: %d' % changed)
PY
}

# 从 yum 源下载 libstdc++-static RPM，解包出 libstdc++fs.a 到私有前缀。
# 不修改系统、无需 root。experimental::filesystem 需要该静态库。
ensure_libstdcxxfs() {
  [[ "${ROCKY_FS_COMPAT:-}" == "experimental" ]] || return 0
  local dest="${ROCKY_DEPS_PREFIX}/lib/libstdc++fs.a"
  if [[ -f "$dest" ]]; then
    log "libstdc++fs.a cached: $dest"
    return 0
  fi
  need_cmd curl "下载 libstdc++-static"
  need_cmd rpm2cpio "解包 libstdc++-static"
  need_cmd cpio "解包 libstdc++-static"
  local url=""
  if command -v repoquery >/dev/null 2>&1; then
    url="$(repoquery --location libstdc++-static 2>/dev/null | head -n1)"
  fi
  if [[ -z "$url" ]] && command -v dnf >/dev/null 2>&1; then
    url="$(dnf repoquery --location libstdc++-static 2>/dev/null | head -n1)"
  fi
  if [[ -z "$url" ]] && command -v yumdownloader >/dev/null 2>&1; then
    url="$(yumdownloader --url --resolve libstdc++-static 2>/dev/null | head -n1)"
  fi
  [[ -n "$url" ]] || die "无法定位 libstdc++-static RPM（repoquery/yumdownloader 均无结果）"
  log "libstdc++-static RPM: $url"
  local rpmf="${ROCKY_WORK}/libstdc++-static.rpm" ex="${ROCKY_WORK}/libstdcxxfs-extract"
  curl -fL --retry 4 --retry-delay 3 --connect-timeout 20 -o "$rpmf" "$url" \
    || die "下载 libstdc++-static 失败"
  rm -rf "$ex"; mkdir -p "$ex"
  ( cd "$ex" && rpm2cpio "$rpmf" | cpio -idm --quiet ) || die "解包 libstdc++-static 失败"
  local found
  found="$(find "$ex" -name 'libstdc++fs.a' -type f -print -quit)"
  [[ -n "$found" ]] || die "libstdc++-static RPM 中无 libstdc++fs.a"
  mkdir -p "${ROCKY_DEPS_PREFIX}/lib" "${ROCKY_DEPS_PREFIX}/lib64"
  cp -f "$found" "${ROCKY_DEPS_PREFIX}/lib/libstdc++fs.a"
  cp -f "$found" "${ROCKY_DEPS_PREFIX}/lib64/libstdc++fs.a"
  log "installed libstdc++fs.a sha256=$(sha256sum "$found" | awk '{print $1}')"
}

apply_fs_compat() {
  [[ "${ROCKY_FS_COMPAT:-}" == "experimental" ]] || return 0
  local stamp="${ROCKY_WORK}/.fs-compat-ready"
  if [[ -f "$stamp" && "$(cat "$stamp")" == "$ROCKY_FS_COMPAT" \
      && -f "${ROCKY_DEPS_PREFIX}/lib/libstdc++fs.a" ]] \
     && grep -q 'experimental/filesystem' "${ROCKY_SRC_DIR}/src/rocky/GDAL.cpp" 2>/dev/null; then
    log "filesystem 兼容补丁已应用（缓存）"
    return 0
  fi
  patch_filesystem
  ensure_libstdcxxfs
  printf '%s\n' "$ROCKY_FS_COMPAT" > "$stamp"
}

HTTPLIB_COMPAT_TAG=openssl111-v1
SIG="${ROCKY_COMMIT}|${VULKAN_HEADERS_COMMIT}|${GLM_TAG}|${SPDLOG_TAG}|${NLOHMANN_JSON_TAG}|${CPP_HTTPLIB_TAG}|${ENTT_TAG}|${HTTPLIB_COMPAT_TAG}"
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
  patch_no_imgui
  apply_fs_compat
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
patch_no_imgui
apply_fs_compat

vulkan_sha="$(fetch_tar vulkan-headers "$VULKAN_HEADERS_SRC_DIR" 'KhronosGroup/Vulkan-Headers' "$VULKAN_HEADERS_COMMIT")"
grep -q '#define VK_HEADER_VERSION 268' "${VULKAN_HEADERS_SRC_DIR}/include/vulkan/vulkan_core.h" \
  || die "Vulkan-Headers 不是 1.3.268"
mkdir -p "${VULKAN_SDK_PREFIX}/include" "${VULKAN_SDK_PREFIX}/lib"
cp -a "${VULKAN_HEADERS_SRC_DIR}/include/." "${VULKAN_SDK_PREFIX}/include/"
ln -sfn /usr/lib64/libvulkan.so "${VULKAN_SDK_PREFIX}/lib/libvulkan.so"
ln -sfn /usr/lib64/libvulkan.so.1 "${VULKAN_SDK_PREFIX}/lib/libvulkan.so.1"

install_cmake_dep() {
  local name="$1" repo="$2" ref="$3"; shift 3
  local src="${ROCKY_WORK}/src/${name}-${ref}" build="${ROCKY_WORK}/build-${name}"
  fetch_tar "$name" "$src" "$repo" "$ref" >/dev/null
  rm -rf "$build"
  cmake -G Ninja -S "$src" -B "$build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX="$ROCKY_DEPS_PREFIX" "$@" >/dev/null
  cmake --build "$build" --parallel "${ROCKY_BUILD_JOBS:-4}" >/dev/null
  cmake --install "$build" >/dev/null
}
install_cmake_dep glm g-truc/glm "$GLM_TAG" -DGLM_BUILD_TESTS=OFF -DGLM_BUILD_LIBRARY=OFF
install_cmake_dep spdlog gabime/spdlog "$SPDLOG_TAG" -DSPDLOG_BUILD_SHARED=ON -DSPDLOG_BUILD_EXAMPLE=OFF -DSPDLOG_BUILD_TESTS=OFF
install_cmake_dep nlohmann-json nlohmann/json "$NLOHMANN_JSON_TAG" -DJSON_BuildTests=OFF
install_cmake_dep entt skypjack/entt "$ENTT_TAG" -DENTT_BUILD_TESTS=OFF -DENTT_BUILD_EXAMPLES=OFF -DENTT_BUILD_BENCHMARK=OFF

HTTP_SRC="${ROCKY_WORK}/src/httplib-${CPP_HTTPLIB_TAG}"
fetch_tar httplib "$HTTP_SRC" 'yhirose/cpp-httplib' "$CPP_HTTPLIB_TAG" >/dev/null
mkdir -p "${ROCKY_DEPS_PREFIX}/include"
cp -f "${HTTP_SRC}/httplib.h" "${ROCKY_DEPS_PREFIX}/include/"
python3 - "${ROCKY_DEPS_PREFIX}/include/httplib.h" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = '#error Sorry, OpenSSL versions prior to 3.0.0 are not supported'
new = '#define SSL_get1_peer_certificate SSL_get_peer_certificate'
if old in s:
    s = s.replace(old, new, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print('patched cpp-httplib for OpenSSL 1.1.1 compatibility')
PY

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
