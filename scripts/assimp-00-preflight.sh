#!/usr/bin/env bash
# 阶段 0：Assimp 原生构建门禁。只读检查，不安装、不下载。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/assimp.env"

require_linux_or_container
[[ "$(id -u)" -ne 0 ]] || die "拒绝以 root 身份编译；runner 必须使用 actionsrunner 账户"

for cmd in git curl tar python3 g++ gcc rpm rpmbuild rpm2cpio cpio ldd readelf; do
  need_cmd "$cmd" "Assimp 原生构建"
done

PATCH="${REPO_ROOT}/${ASSIMP_PATCH_REL}"
[[ -f "$PATCH" ]] || die "缺少补丁 ${ASSIMP_PATCH_REL}"
actual="$(sha256sum "$PATCH" | awk '{print $1}')"
[[ "$actual" == "${ASSIMP_PATCH_SHA256}" ]] \
  || die "补丁指纹不符：期望 ${ASSIMP_PATCH_SHA256}，实际 ${actual}"

free="$(free_gb "$ASSIMP_WORK")"
[[ "$free" -ge 12 ]] || die "可用空间 ${free}GB < 12GB，无法安全编译 Assimp（含测试模型与 RPM）"

python3 - "${ASSIMP_REPORT_DIR}" "${REPO_ROOT}" "${ASSIMP_VERSION}" "${ASSIMP_TAG}" \
          "${ASSIMP_GIT_COMMIT}" "${actual}" "${free}" \
          "${TARGET_ARCH:-x86_64}" "${ISA_POLICY:-x86-64-baseline}" <<'PY'
import json, os, shutil, subprocess, sys
rep, root, version, tag, commit, patch_sha, free_gb, arch, isa = sys.argv[1:10]
os.makedirs(rep, exist_ok=True)

def run(cmd):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=20)
        return (p.stdout + p.stderr).strip().splitlines()[:1]
    except Exception as exc:
        return ['%s: %s' % (type(exc).__name__, exc)]

tools = {}
for name in ('cmake', 'ninja', 'make', 'ccache', 'pkg-config'):
    p = shutil.which(name)
    tools[name] = {'path': p,
                   'version': (run('%s --version' % name) or [''])[0][:160] if p else ''}
os_release = {}
if os.path.exists('/etc/os-release'):
    for line in open('/etc/os-release', encoding='utf-8', errors='replace'):
        if '=' in line:
            k, v = line.split('=', 1)
            os_release[k] = v.strip().strip('"')

data = {
    'stage': 'ASSIMP_STAGE_0_PREFLIGHT',
    'version': version, 'tag': tag, 'expected_commit': commit,
    'patch': {'path': tag and 'patches/assimp-6.0.5-kylin.patch', 'sha256': patch_sha},
    'os_release': os_release,
    'host': os.uname().nodename, 'arch': os.uname().machine,
    'kernel': os.uname().release, 'user': os.popen('id -un').read().strip(),
    'glibc': (run('ldd --version') or [''])[0],
    'compiler': (run('g++ --version') or [''])[0],
    'tools': tools,
    'free_gb': int(free_gb),
    'target_arch': arch, 'isa_policy': isa,
    'require_gcc11': os.environ.get('REQUIRE_GCC11', 'true'),
    'verdict': 'PASS',
}
path = os.path.join(rep, 'assimp-environment.json')
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
print(json.dumps(data, ensure_ascii=False, indent=2))
PY

stage_marker ASSIMP_STAGE_0_PREFLIGHT_OK PASS "${ASSIMP_REPORT_DIR}/assimp-preflight.json"
info "ASSIMP PREFLIGHT PASS"
