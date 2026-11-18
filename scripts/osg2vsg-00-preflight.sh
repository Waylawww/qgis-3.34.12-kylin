#!/usr/bin/env bash
# 阶段 0：osg2vsg 依赖门禁（只读诊断，不因为缺 VSG/OSG 而中断）。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/osg2vsg.env"

require_linux_or_container
[[ "$(id -u)" -ne 0 ]] || die "拒绝以 root 身份编译"
for cmd in git curl tar python3 g++ gcc cmake rpm rpmbuild rpm2cpio cpio ldd readelf; do
  need_cmd "$cmd" "osg2vsg 构建"
done
free="$(free_gb "$OSG2VSG_WORK")"
[[ "$free" -ge 12 ]] || die "可用空间 ${free}GB < 12GB"

DEPS="${DEPS_PREFIX:-/opt/actions-runner/_work/qgis-3.34.12-kylin/_qgis-334-deps}"
python3 - "${OSG2VSG_REPORT_DIR}" "${DEPS}" "${OSG2VSG_VERSION}" "${free}" <<'PY'
import glob, json, os, platform, shutil, subprocess, sys
rep, deps, version, free_gb = sys.argv[1:5]
os.makedirs(rep, exist_ok=True)

def sh(cmd):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        return (p.stdout + p.stderr).strip()
    except Exception as e:
        return '%s: %s' % (type(e).__name__, e)

rpm_all = sh("rpm -qa | grep -iE 'openscenegraph|vsg|vulkan' | sort")
configs = []
for root in ('/usr', '/usr/local', deps):
    for pat in ('**/vsgConfig.cmake', '**/OpenSceneGraphConfig.cmake', '**/osgDBConfig.cmake'):
        configs += glob.glob(os.path.join(root, pat), recursive=True)
configs = sorted(set(configs))[:40]
headers = {
    'vulkan': os.path.exists('/usr/include/vulkan/vulkan.h'),
    'osg': os.path.exists('/usr/include/osg/Node'),
}
libs = sh("ldconfig -p 2>/dev/null | grep -E 'libosg|libvsg|libvulkan' | head -40")
os_release = {}
if os.path.exists('/etc/os-release'):
    for line in open('/etc/os-release', encoding='utf-8', errors='replace'):
        if '=' in line:
            k, v = line.split('=', 1); os_release[k] = v.strip().strip('"')
data = {
    'stage': 'OSG2VSG_STAGE_0_PREFLIGHT', 'version': version,
    'host': platform.node(), 'arch': platform.machine(), 'user': os.popen('id -un').read().strip(),
    'os_release': os_release, 'free_gb': int(free_gb),
    'cmake': sh('cmake --version')[0:120],
    'rpm_packages': rpm_all,
    'cmake_configs': configs,
    'headers': headers,
    'ldconfig': libs,
    'verdict': 'PASS',
}
with open(os.path.join(rep, 'osg2vsg-environment.json'), 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2); f.write('\n')
print(json.dumps(data, ensure_ascii=False, indent=2))
PY
stage_marker OSG2VSG_STAGE_0_PREFLIGHT_OK PASS "${OSG2VSG_REPORT_DIR}/osg2vsg-preflight.json"
info "OSG2VSG PREFLIGHT PASS"
