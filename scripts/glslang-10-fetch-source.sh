#!/usr/bin/env bash
# 阶段 1：下载 glslang main-tot 源码及 known_good.json 锁定的 External 依赖。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/glslang.env"

need_cmd curl "源码下载"
need_cmd tar  "源码解压"
log "== 阶段 1 / FETCH GLSLANG ${GLSLANG_VERSION} (${GLSLANG_TAG}) =="

SIG="${GLSLANG_VERSION}|${GLSLANG_COMMIT}|${SPIRV_TOOLS_COMMIT}|${SPIRV_HEADERS_COMMIT}|${GOOGLETEST_COMMIT}"
STAMP="${GLSLANG_WORK}/.source-ready"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$SIG" \
   && -f "${GLSLANG_SRC_DIR}/CMakeLists.txt" \
   && -f "${GLSLANG_SRC_DIR}/External/googletest/CMakeLists.txt" \
   && -d "${GLSLANG_SRC_DIR}/External/spirv-tools" ]]; then
  log "复用已校验源码与 External 依赖（signature=${SIG}）"
  stage_marker GLSLANG_STAGE_1_SOURCE_OK PASS "${GLSLANG_REPORT_DIR}/glslang-source-ok.json"
  info "GLSLANG SOURCE PASS (cached)"
  exit 0
fi

fetch_tar() {
  local name="$1" dest="$2"; shift 2
  local url tarball="${GLSLANG_WORK}/${name}.tar.gz" ok=0
  rm -f "$tarball"
  for url in "$@"; do
    log "${name}: 尝试下载 ${url}"
    if curl -fL --retry 4 --retry-delay 3 --connect-timeout 20 --max-time 1800 \
         -o "$tarball" "$url" && tar -tzf "$tarball" >/dev/null 2>&1; then
      ok=1; break
    fi
    rm -f "$tarball"
  done
  [[ "$ok" -eq 1 ]] || die "${name} 所有下载地址均失败"
  rm -rf "$dest"; mkdir -p "$dest"
  tar -xzf "$tarball" --strip-components=1 -C "$dest"
  [[ -n "$(ls -A "$dest")" ]] || die "${name} 解压结果为空"
  sha256sum "$tarball" | awk '{print $1}'
}

main_sha="$(fetch_tar glslang "$GLSLANG_SRC_DIR" \
  "https://ghproxy.net/https://github.com/${GLSLANG_REPO#https://github.com/}/archive/refs/tags/${GLSLANG_TAG}.tar.gz" \
  "https://codeload.github.com/${GLSLANG_REPO#https://github.com/}/tar.gz/refs/tags/${GLSLANG_TAG}" \
  "https://github.com/${GLSLANG_REPO#https://github.com/}/archive/refs/tags/${GLSLANG_TAG}.tar.gz")"

grep -q 'cmake_minimum_required(VERSION 3.22.1)' "${GLSLANG_SRC_DIR}/CMakeLists.txt" \
  || die "源码 CMake 最低版本与锁定值不符"
grep -q '## 16.1.0' "${GLSLANG_SRC_DIR}/CHANGES.md" || die "源码变更日志不含 16.1.0"

st_sha="$(fetch_tar spirv-tools "${GLSLANG_SRC_DIR}/External/spirv-tools" \
  "https://ghproxy.net/https://github.com/KhronosGroup/SPIRV-Tools/archive/${SPIRV_TOOLS_COMMIT}.tar.gz" \
  "https://codeload.github.com/KhronosGroup/SPIRV-Tools/tar.gz/${SPIRV_TOOLS_COMMIT}")"
sh_sha="$(fetch_tar spirv-headers "${GLSLANG_SRC_DIR}/External/spirv-tools/external/spirv-headers" \
  "https://ghproxy.net/https://github.com/KhronosGroup/SPIRV-Headers/archive/${SPIRV_HEADERS_COMMIT}.tar.gz" \
  "https://codeload.github.com/KhronosGroup/SPIRV-Headers/tar.gz/${SPIRV_HEADERS_COMMIT}")"
gt_sha="$(fetch_tar googletest "${GLSLANG_SRC_DIR}/External/googletest" \
  "https://ghproxy.net/https://github.com/google/googletest/archive/${GOOGLETEST_COMMIT}.tar.gz" \
  "https://codeload.github.com/google/googletest/tar.gz/${GOOGLETEST_COMMIT}")"

[[ -f "${GLSLANG_SRC_DIR}/External/spirv-tools/CMakeLists.txt" ]] || die "SPIRV-Tools 缺少 CMakeLists.txt"
[[ -d "${GLSLANG_SRC_DIR}/External/spirv-tools/external/spirv-headers/include" ]] || die "SPIRV-Headers 目录不完整"
[[ -f "${GLSLANG_SRC_DIR}/External/googletest/CMakeLists.txt" ]] || die "googletest 缺少 CMakeLists.txt"

python3 - "${GLSLANG_REPORT_DIR}" "${GLSLANG_VERSION}" "${GLSLANG_TAG}" "${GLSLANG_COMMIT}" \
          "${main_sha}" "${st_sha}" "${sh_sha}" "${gt_sha}" <<'PY'
import datetime, json, os, sys
rep, version, tag, commit, m, st, sh, gt = sys.argv[1:9]
data = {'stage': 'GLSLANG_STAGE_1_SOURCE', 'version': version, 'tag': tag,
        'commit': commit, 'sha256': {'glslang': m, 'spirv-tools': st,
        'spirv-headers': sh, 'googletest': gt},
        'verdict': 'PASS',
        'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
with open(os.path.join(rep, 'glslang-source.json'), 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2); f.write('\n')
print(json.dumps(data, ensure_ascii=False, indent=2))
PY
printf '%s\n' "$SIG" > "$STAMP"
stage_marker GLSLANG_STAGE_1_SOURCE_OK PASS "${GLSLANG_REPORT_DIR}/glslang-source-ok.json"
info "GLSLANG SOURCE PASS"
