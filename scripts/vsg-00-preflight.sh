#!/usr/bin/env bash
# 阶段 0：VSG 原生构建门禁。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/vsg.env"

require_linux_or_container
[[ "$(id -u)" -ne 0 ]] || die "拒绝以 root 身份编译"
for cmd in git curl tar python3 g++ gcc cmake ninja rpm rpmbuild rpm2cpio cpio ldd readelf objdump pkg-config; do
  need_cmd "$cmd" "VSG 原生构建"
done
pkg-config --exists xcb || die "缺少 xcb 开发包（VSG_SUPPORTS_Windowing=ON）"

GLSLANG_CONFIG="$(find "$GLSLANG_PREFIX" -path '*/cmake/glslang/glslangConfig.cmake' -print -quit 2>/dev/null || true)"
[[ -n "$GLSLANG_CONFIG" ]] || die "未找到 ${GLSLANG_PREFIX} 下的 glslangConfig.cmake"

free="$(free_gb "$VSG_WORK")"
[[ "$free" -ge 10 ]] || die "可用空间 ${free}GB < 10GB"

python3 - "${VSG_REPORT_DIR}" "${VSG_VERSION}" "${VSG_COMMIT}" "${GLSLANG_CONFIG}" "${free}" <<'PY'
import datetime, json, os, platform, sys
rep, version, commit, glslang_config, free_gb = sys.argv[1:6]
os.makedirs(rep, exist_ok=True)
os_release = {}
if os.path.exists('/etc/os-release'):
    for line in open('/etc/os-release', encoding='utf-8', errors='replace'):
        if '=' in line:
            k, v = line.split('=', 1); os_release[k] = v.strip().strip('"')
data = {'stage':'VSG_STAGE_0_PREFLIGHT','version':version,'commit':commit,
        'glslang_config':glslang_config,'os_release':os_release,
        'host':platform.node(),'arch':platform.machine(),
        'user':os.popen('id -un').read().strip(),'free_gb':int(free_gb),
        'isa_policy':'x86-64-baseline','verdict':'PASS',
        'recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
with open(os.path.join(rep,'vsg-environment.json'),'w',encoding='utf-8') as f:
    json.dump(data,f,ensure_ascii=False,indent=2); f.write('\n')
print(json.dumps(data,ensure_ascii=False,indent=2))
PY
stage_marker VSG_STAGE_0_PREFLIGHT_OK PASS "${VSG_REPORT_DIR}/vsg-preflight.json"
info "VSG PREFLIGHT PASS"
