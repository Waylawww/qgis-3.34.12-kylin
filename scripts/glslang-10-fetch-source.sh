#!/usr/bin/env bash
# 阶段 1：下载 glslang main-tot 源码及 known_good.json 锁定的 External 依赖。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/glslang.env"

need_cmd curl "源码下载"
need_cmd tar  "源码解压"
log "== 阶段 1 / FETCH GLSLANG ${GLSLANG_VERSION} (${GLSLANG_TAG}) =="

# 可选源码补丁（B 设备 GCC7 兼容用；A 设备未配置则跳过）
PATCH_SHA_CONFIG=''
if [[ -n "${GLSLANG_PATCH_REL:-}" ]]; then
  PATCH="${REPO_ROOT}/${GLSLANG_PATCH_REL}"
  [[ -f "$PATCH" ]] || die "缺少补丁 ${GLSLANG_PATCH_REL}"
  PATCH_SHA_CONFIG="$(sha256sum "$PATCH" | awk '{print $1}')"
  [[ "$PATCH_SHA_CONFIG" == "${GLSLANG_PATCH_SHA256:-}" ]] \
    || die "补丁指纹不符：期望 ${GLSLANG_PATCH_SHA256}，实际 ${PATCH_SHA_CONFIG}"
fi

# main-tot 是移动 tag，必须按固定 commit 归档下载；SIG 含补丁 SHA，补丁变更会触发重取。
SIG="v3-by-commit|${GLSLANG_VERSION}|${GLSLANG_COMMIT}|${SPIRV_TOOLS_COMMIT}|${SPIRV_HEADERS_COMMIT}|${GOOGLETEST_COMMIT}|${PATCH_SHA_CONFIG}"
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
  "https://ghproxy.net/https://github.com/${GLSLANG_REPO#https://github.com/}/archive/${GLSLANG_COMMIT}.tar.gz" \
  "https://codeload.github.com/${GLSLANG_REPO#https://github.com/}/tar.gz/${GLSLANG_COMMIT}" \
  "https://github.com/${GLSLANG_REPO#https://github.com/}/archive/${GLSLANG_COMMIT}.tar.gz")"

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

# 应用可选补丁（B 设备 GCC7 兼容）；用 git apply 的 3-way/普通模式，幂等处理。
if [[ -n "${GLSLANG_PATCH_REL:-}" ]]; then
  if grep -q 'glslangAbsolutePath' "${GLSLANG_SRC_DIR}/glslang/Include/InfoSink.h"; then
    log "补丁已应用，跳过"
  else
    ( cd "$GLSLANG_SRC_DIR" && git apply --check "$PATCH" ) \
      || ( cd "$GLSLANG_SRC_DIR" && patch -p1 --dry-run --forward < "$PATCH" ) \
      || die "补丁 ${GLSLANG_PATCH_REL} 无法应用"
    ( cd "$GLSLANG_SRC_DIR" && git apply "$PATCH" ) \
      || ( cd "$GLSLANG_SRC_DIR" && patch -p1 --forward < "$PATCH" ) \
      || die "补丁应用失败"
  fi
  grep -q 'glslangAbsolutePath' "${GLSLANG_SRC_DIR}/glslang/Include/InfoSink.h" \
    || die "补丁应用后仍缺少 glslangAbsolutePath 兼容层"
  log "已应用补丁 ${GLSLANG_PATCH_REL} (sha256=${PATCH_SHA_CONFIG})"
fi

python3 - "${GLSLANG_REPORT_DIR}" "${GLSLANG_VERSION}" "${GLSLANG_TAG}" "${GLSLANG_COMMIT}" \
          "${main_sha}" "${st_sha}" "${sh_sha}" "${gt_sha}" "${PATCH_SHA_CONFIG}" <<'PY'
import datetime, json, os, sys
rep, version, tag, commit, m, st, sh, gt, patch_sha = sys.argv[1:10]
data = {'stage': 'GLSLANG_STAGE_1_SOURCE', 'version': version, 'tag': tag,
        'commit': commit, 'sha256': {'glslang': m, 'spirv-tools': st,
        'spirv-headers': sh, 'googletest': gt, 'patch': patch_sha},
        'verdict': 'PASS',
        'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
with open(os.path.join(rep, 'glslang-source.json'), 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2); f.write('\n')
print(json.dumps(data, ensure_ascii=False, indent=2))
PY
printf '%s\n' "$SIG" > "$STAMP"
stage_marker GLSLANG_STAGE_1_SOURCE_OK PASS "${GLSLANG_REPORT_DIR}/glslang-source-ok.json"
info "GLSLANG SOURCE PASS"
