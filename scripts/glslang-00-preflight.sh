#!/usr/bin/env bash
# 阶段 0：glslang 原生构建门禁（只读）。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/glslang.env"

require_linux_or_container
[[ "$(id -u)" -ne 0 ]] || die "拒绝以 root 身份编译；runner 必须使用 actionsrunner 账户"
for cmd in git curl tar python3 g++ gcc ctest rpm rpmbuild rpm2cpio cpio ldd readelf objdump; do
  need_cmd "$cmd" "glslang 原生构建"
done
free="$(free_gb "$GLSLANG_WORK")"
[[ "$free" -ge 12 ]] || die "可用空间 ${free}GB < 12GB，无法安全编译 glslang"

python3 - "${GLSLANG_REPORT_DIR}" "${GLSLANG_VERSION}" "${GLSLANG_TAG}" \
          "${GLSLANG_COMMIT}" "${free}" <<'PY'
import datetime, json, os, platform, shutil, subprocess, sys
rep, version, tag, commit, free_gb = sys.argv[1:6]
os.makedirs(rep, exist_ok=True)
os_release = {}
if os.path.exists('/etc/os-release'):
    for line in open('/etc/os-release', encoding='utf-8', errors='replace'):
        if '=' in line:
            k, v = line.split('=', 1)
            os_release[k] = v.strip().strip('"')
tools = {}
for name in ('cmake', 'ninja', 'make', 'python3'):
    p = shutil.which(name)
    tools[name] = {'path': p}
data = {
    'stage': 'GLSLANG_STAGE_0_PREFLIGHT',
    'version': version, 'tag': tag, 'expected_commit': commit,
    'os_release': os_release, 'host': platform.node(),
    'arch': platform.machine(), 'kernel': platform.release(),
    'user': os.popen('id -un').read().strip(),
    'compiler': os.popen('g++ --version').readline().strip(),
    'tools': tools, 'free_gb': int(free_gb),
    'isa_policy': 'x86-64-baseline', 'verdict': 'PASS',
    'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
with open(os.path.join(rep, 'glslang-environment.json'), 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
print(json.dumps(data, ensure_ascii=False, indent=2))
PY
stage_marker GLSLANG_STAGE_0_PREFLIGHT_OK PASS "${GLSLANG_REPORT_DIR}/glslang-preflight.json"
info "GLSLANG PREFLIGHT PASS"
