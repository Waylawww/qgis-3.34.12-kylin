#!/usr/bin/env bash
# 阶段 0：Rocky 原生构建门禁。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/rocky.env"

require_linux_or_container
[[ "$(id -u)" -ne 0 ]] || die "拒绝以 root 身份编译"
for cmd in git curl tar python3 g++ gcc cmake ninja rpm rpmbuild rpm2cpio cpio ldd readelf objdump; do
  need_cmd "$cmd" "Rocky 原生构建"
done
free="$(free_gb "$ROCKY_WORK")"
[[ "$free" -ge 12 ]] || die "可用空间 ${free}GB < 12GB"
python3 - "${ROCKY_REPORT_DIR}" "${ROCKY_VERSION}" "${ROCKY_COMMIT}" "${free}" \
        "${TARGET_ARCH:-x86_64}" "${ISA_POLICY:-x86-64-baseline}" <<'PY'
import datetime, json, os, platform, sys
rep, version, commit, free_gb, arch, isa = sys.argv[1:7]
os.makedirs(rep, exist_ok=True)
os_release = {}
if os.path.exists('/etc/os-release'):
    for line in open('/etc/os-release', encoding='utf-8', errors='replace'):
        if '=' in line:
            k, v = line.split('=', 1); os_release[k] = v.strip().strip('"')
data = {'stage':'ROCKY_STAGE_0_PREFLIGHT','version':version,'commit':commit,
        'os_release':os_release,'host':platform.node(),'arch':platform.machine(),
        'user':os.popen('id -un').read().strip(),'free_gb':int(free_gb),
        'target_arch':arch,'isa_policy':isa,'verdict':'PASS',
        'recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
with open(os.path.join(rep,'rocky-environment.json'),'w',encoding='utf-8') as f:
    json.dump(data,f,ensure_ascii=False,indent=2); f.write('\n')
print(json.dumps(data,ensure_ascii=False,indent=2))
PY
stage_marker ROCKY_STAGE_0_PREFLIGHT_OK PASS "${ROCKY_REPORT_DIR}/rocky-preflight.json"
info "ROCKY PREFLIGHT PASS"
