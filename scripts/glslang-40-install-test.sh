#!/usr/bin/env bash
# 阶段 3：RPM 安装（优先 root 受限安装器）并做 CLI / 着色器编译 / C++ API 自测。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/glslang.env"

RPM="$(find "${GLSLANG_OUT_DIR}/rpms" -maxdepth 1 -name 'glslang-*.rpm' ! -name '*.src.rpm' -type f | sort | head -n1)"
[[ -n "$RPM" ]] || die "未找到 glslang 二进制 RPM"
EVID="${GLSLANG_REPORT_DIR}/install-selftest"
mkdir -p "$EVID"
echo "runner: $(id -un) uid=$(id -u)"
echo "rpm: ${RPM}"

INSTALLER=/usr/local/sbin/glslang-ci-install
INSTALL_MODE="rpm-extract"
INSTALL_ROOT="$GLSLANG_RPM_ROOT"
if [[ -x "$INSTALLER" ]] && sudo -n -l "$INSTALLER" >/dev/null 2>&1; then
  echo "检测到受限安装器 ${INSTALLER}"
  if sudo -n "$INSTALLER" >"${EVID}/rpm-install.log" 2>&1; then
    INSTALL_MODE="system-rpm"
    INSTALL_ROOT=""
  else
    echo "受限安装器执行失败，降级为 RPM 解包安装；详见 ${EVID}/rpm-install.log"
  fi
elif sudo -n true >/dev/null 2>&1; then
  if sudo -n rpm -Uvh --replacefiles --replacepkgs "$RPM" >"${EVID}/rpm-install.log" 2>&1; then
    INSTALL_MODE="system-rpm"
    INSTALL_ROOT=""
  else
    echo "sudo 可用但 rpm 安装失败，降级为 RPM 解包安装；详见 ${EVID}/rpm-install.log"
  fi
else
  echo "未授权受限安装器，使用 RPM 解包安装到独立前缀"
fi
if [[ "$INSTALL_MODE" == "rpm-extract" ]]; then
  rm -rf "$INSTALL_ROOT"; mkdir -p "$INSTALL_ROOT"
  ( cd "$INSTALL_ROOT" && rpm2cpio "$RPM" | cpio -idm --quiet --no-absolute-filenames ) \
    >"${EVID}/rpm-extract.log" 2>&1
fi

PFX="${INSTALL_ROOT}${GLSLANG_INSTALL_PREFIX}"
LIBDIR="${PFX}/lib64"
INCDIR="${PFX}/include"
BIN="${PFX}/bin/glslangValidator"
SHADER="${PFX}/share/glslang-selftest/triangle.vert"
export LD_LIBRARY_PATH="${LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
[[ -f "$BIN" ]] || die "RPM 安装树缺少 glslangValidator"
[[ -f "$SHADER" ]] || die "RPM 安装树缺少自测着色器"
[[ -f "${INCDIR}/glslang/Public/ShaderLang.h" ]] || die "RPM 安装树缺少 glslang 头文件"

CHECKS=()
check() {
  local name="$1"; shift
  if "$@" >"${EVID}/${name}.log" 2>&1; then
    echo "  PASS  ${name}"; CHECKS+=("${name}:PASS")
  else
    echo "  FAIL  ${name}"; tail -n 20 "${EVID}/${name}.log" >&2 || true; CHECKS+=("${name}:FAIL")
  fi
}

rpm_files() { rpm -qlp "$RPM" | grep -q 'libglslang.so' && rpm -qlp "$RPM" | grep -q '/bin/glslangValidator'; }
rpm_query() { rpm -q glslang; }
installed_files() { test -d "$LIBDIR" && test -d "$INCDIR/glslang"; }

glslang_version() {
  local out
  out="$("$BIN" --version 2>&1 || "$BIN" -v 2>&1)"
  printf '%s\n' "$out"
  grep -q "${GLSLANG_VERSION}" <<<"$out"
}

shader_compile() {
  local out="${EVID}/triangle.spv"
  rm -f "$out"
  "$BIN" -V "$SHADER" -o "$out"
  test -s "$out"
  printf 'spirv_bytes=%s\n' "$(stat -c%s "$out")"
}

cmake_api_smoke() {
  local d="${EVID}/cmake-smoke"
  rm -rf "$d"; mkdir -p "$d"
  cat > "$d/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.22)
project(glslang_smoke CXX)
find_package(glslang REQUIRED CONFIG)
add_executable(smoke main.cpp)
target_link_libraries(smoke PRIVATE glslang::glslang)
EOF
  cat > "$d/main.cpp" <<'EOF'
#include <glslang/Public/ShaderLang.h>
#include <iostream>
int main() {
    if (!glslang::InitializeProcess()) return 1;
    glslang::FinalizeProcess();
    std::cout << "glslang api ok\n";
    return 0;
}
EOF
  cmake -S "$d" -B "$d/build" -DCMAKE_PREFIX_PATH="$PFX" -DCMAKE_BUILD_TYPE=Release
  cmake --build "$d/build" --parallel 2
  LD_LIBRARY_PATH="$LIBDIR${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" "$d/build/smoke"
}

ldd_clean() {
  local out lib
  lib="$(find "$LIBDIR" -maxdepth 1 -name 'libglslang.so*' -print -quit)"
  out="$(ldd "$lib" 2>&1)"
  printf '%s\n' "$out" > "${EVID}/ldd-installed.txt"
  ! grep -q 'not found' <<<"$out"
}

echo "== 安装模式: ${INSTALL_MODE} =="
check package_contents rpm_files
if [[ "$INSTALL_MODE" == "system-rpm" ]]; then check rpm_installed rpm_query; fi
check installed_files installed_files
check glslang_version glslang_version
check shader_compile shader_compile
check cmake_api_smoke cmake_api_smoke
check ldd_clean ldd_clean

if ! python3 - "${EVID}" "${GLSLANG_VERSION}" "${INSTALL_MODE}" "${CHECKS[@]}" <<'PY'
import json, os, sys
evid, version, mode, *items = sys.argv[1:]
checks = {}
for item in items:
    k, _, v = item.partition(':'); checks[k] = v
mandatory = ('package_contents', 'installed_files', 'glslang_version',
             'shader_compile', 'cmake_api_smoke', 'ldd_clean')
if mode == 'system-rpm': mandatory += ('rpm_installed',)
failed = [k for k in mandatory if checks.get(k) != 'PASS']
report = {'stage': 'GLSLANG_STAGE_3_INSTALL_AND_SELFTEST',
          'environment': 'self-hosted Kylin V10 (Halberd) / x86_64 / Hygon C86',
          'host': os.uname().nodename, 'run_as': os.popen('id -un').read().strip(),
          'glslang_version': version, 'install_mode': mode,
          'checks': checks, 'failed_checks': failed,
          'verdict': 'PASS' if not failed else 'FAIL'}
text = json.dumps(report, ensure_ascii=False, indent=2)
with open(os.path.join(evid, 'install-selftest.json'), 'w', encoding='utf-8') as f:
    f.write(text + '\n')
print(text)
sys.exit(0 if not failed else 1)
PY
then
  echo "GLSLANG INSTALL + SELFTEST FAIL" >&2; exit 1
fi
stage_marker GLSLANG_STAGE_3_INSTALL_OK PASS "${GLSLANG_REPORT_DIR}/glslang-install-ok.json"
info "GLSLANG INSTALL + SELFTEST PASS"
