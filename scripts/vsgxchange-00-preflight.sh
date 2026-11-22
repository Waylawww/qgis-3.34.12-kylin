#!/usr/bin/env bash
# 阶段 0：vsgXchange 原生构建门禁。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/vsgxchange.env"
# B 设备前缀恢复（config/vsgxchange.env 会把依赖前缀覆盖为 A 设备 /opt 路径）
[[ -n "${B_OSG2VSG_PREFIX:-}" ]] && OSG2VSG_PREFIX="$B_OSG2VSG_PREFIX"
[[ -n "${B_GLSLANG_PREFIX:-}" ]] && GLSLANG_PREFIX="$B_GLSLANG_PREFIX"
[[ -n "${B_ASSIMP_PREFIX:-}" ]] && ASSIMP_PREFIX="$B_ASSIMP_PREFIX"

require_linux_or_container
[[ "$(id -u)" -ne 0 ]] || die "拒绝以 root 身份编译"
for cmd in git curl tar python3 g++ gcc cmake ninja rpm rpmbuild rpm2cpio cpio ldd readelf objdump; do
  need_cmd "$cmd" "vsgXchange 原生构建"
done

[[ -f "${OSG2VSG_PREFIX}/lib64/cmake/vsg/vsgConfig.cmake" ]] \
  || die "缺少 ${OSG2VSG_PREFIX} 下的 VSG 1.1.13 CMake 配置"
[[ -f "${OSG2VSG_PREFIX}/lib64/cmake/osg2vsg/osg2vsgConfig.cmake" ]] \
  || die "缺少 osg2vsg CMake 配置（vsgXchange_OSG=ON）"
[[ -f "${OSG2VSG_PREFIX}/include/vulkan/vulkan.h" ]] \
  || die "缺少 ${OSG2VSG_PREFIX} 下的 Vulkan 1.2.131 头文件"

GLSLANG_CONFIG="$(find "$GLSLANG_PREFIX" -path '*/cmake/glslang/*' -name 'glslang*onfig.cmake' -print -quit 2>/dev/null || true)"
[[ -n "$GLSLANG_CONFIG" ]] || die "未找到 ${GLSLANG_PREFIX} 下的 glslang-config.cmake"

ASSIMP_CONFIG="$(find "$ASSIMP_PREFIX" -path '*/cmake/assimp/*' -name 'assimp*onfig.cmake' -print -quit 2>/dev/null || true)"
if [[ -n "$ASSIMP_CONFIG" ]]; then
  echo "assimp config: ${ASSIMP_CONFIG}"
else
  echo "assimp config not found; vsgXchange_assimp will be disabled"
fi

free="$(free_gb "$VSGXCHANGE_WORK")"
[[ "$free" -ge 10 ]] || die "可用空间 ${free}GB < 10GB"

python3 - "${VSGXCHANGE_REPORT_DIR}" "${VSGXCHANGE_VERSION}" "${VSGXCHANGE_COMMIT}" "${GLSLANG_CONFIG}" "${ASSIMP_CONFIG}" "${free}" <<'PY'
import datetime, json, os, platform, sys
rep, version, commit, glslang, assimp, free_gb = sys.argv[1:7]
os.makedirs(rep, exist_ok=True)
os_release = {}
if os.path.exists('/etc/os-release'):
    for line in open('/etc/os-release', encoding='utf-8', errors='replace'):
        if '=' in line:
            k, v = line.split('=', 1); os_release[k] = v.strip().strip('"')
data = {'stage':'VSGXCHANGE_STAGE_0_PREFLIGHT','version':version,'commit':commit,
        'glslang_config':glslang,'assimp_config':assimp,'os_release':os_release,
        'host':platform.node(),'arch':platform.machine(),
        'user':os.popen('id -un').read().strip(),'free_gb':int(free_gb),
        'isa_policy':('aarch64-armv8a-baseline' if platform.machine()=='aarch64' else 'x86-64-baseline'),'verdict':'PASS',
        'recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
with open(os.path.join(rep,'vsgxchange-environment.json'),'w',encoding='utf-8') as f:
    json.dump(data,f,ensure_ascii=False,indent=2); f.write('\n')
print(json.dumps(data,ensure_ascii=False,indent=2))
PY
stage_marker VSGXCHANGE_STAGE_0_PREFLIGHT_OK PASS "${VSGXCHANGE_REPORT_DIR}/vsgxchange-preflight.json"
info "VSGXCHANGE PREFLIGHT PASS"
