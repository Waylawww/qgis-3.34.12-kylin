#!/usr/bin/env bash
# 阶段 3：RPM 安装（优先 root 受限安装器）+ 安装后 CMake API / 动态库自测。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/rocky.env"

RPM="$(find "${ROCKY_OUT_DIR}/rpms" -maxdepth 1 -name 'rocky-*.rpm' ! -name '*.src.rpm' -type f | sort | head -n1)"
[[ -n "$RPM" ]] || die "未找到 rocky 二进制 RPM"
EVID="${ROCKY_REPORT_DIR}/install-selftest"
mkdir -p "$EVID"
echo "runner=$(id -un) rpm=$RPM"

INSTALLER=/usr/local/sbin/rocky-ci-install
INSTALL_MODE="rpm-extract"
INSTALL_ROOT="$ROCKY_RPM_ROOT"
if [[ -x "$INSTALLER" ]] && sudo -n -l "$INSTALLER" >/dev/null 2>&1; then
  echo "检测到受限安装器 ${INSTALLER}"
  if sudo -n "$INSTALLER" >"${EVID}/rpm-install.log" 2>&1; then
    INSTALL_MODE="system-rpm"; INSTALL_ROOT=""
  else
    echo "受限安装器失败，降级为解包安装：${EVID}/rpm-install.log"
  fi
elif sudo -n true >/dev/null 2>&1; then
  if sudo -n rpm -Uvh --replacefiles --replacepkgs "$RPM" >"${EVID}/rpm-install.log" 2>&1; then
    INSTALL_MODE="system-rpm"; INSTALL_ROOT=""
  else
    echo "sudo rpm 安装失败，降级为解包安装：${EVID}/rpm-install.log"
  fi
else
  echo "未授权受限安装器，使用 RPM 解包安装"
fi
if [[ "$INSTALL_MODE" == "rpm-extract" ]]; then
  rm -rf "$INSTALL_ROOT"; mkdir -p "$INSTALL_ROOT"
  ( cd "$INSTALL_ROOT" && rpm2cpio "$RPM" | cpio -idm --quiet --no-absolute-filenames ) \
    >"${EVID}/rpm-extract.log" 2>&1
fi

PFX="${INSTALL_ROOT}${ROCKY_INSTALL_PREFIX}"
LIBDIR="${PFX}/lib64"
INCDIR="${PFX}/include"
export LD_LIBRARY_PATH="${LIBDIR}:${PFX}/lib:/opt/osg2vsg-0.4.0/lib64:/opt/glslang-16.1.0/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
[[ -f "${LIBDIR}/librocky.so.${ROCKY_VERSION_ABI}" || -L "${LIBDIR}/librocky.so.${ROCKY_VERSION_ABI}" ]] \
  || die "RPM 安装树缺少 librocky.so.${ROCKY_VERSION_ABI}"

CHECKS=()
check() { local n="$1"; shift; if "$@" >"${EVID}/${n}.log" 2>&1; then echo "  PASS  $n"; CHECKS+=("$n:PASS"); else echo "  FAIL  $n"; tail -n 20 "${EVID}/${n}.log" >&2 || true; CHECKS+=("$n:FAIL"); fi; }

rpm_files() {
  rpm -qlp "$RPM" | grep -q 'librocky.so' &&
  rpm -qlp "$RPM" | grep -q 'rocky-config.cmake'
}
rpm_query() { rpm -q rocky; }
installed_files() {
  test -f "${INCDIR}/rocky/Version.h" &&
  test -f "${INCDIR}/entt/entt.hpp" &&
  test -f "${LIBDIR}/cmake/rocky/rocky-config.cmake"
}

api_smoke() {
  local d="${EVID}/cmake-smoke"
  rm -rf "$d"; mkdir -p "$d"
  cat > "$d/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.21)
project(rocky_smoke CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(rocky REQUIRED CONFIG)
add_executable(smoke main.cpp)
target_link_libraries(smoke PRIVATE rocky::rocky)
EOF
  cat > "$d/main.cpp" <<'EOF'
#include <rocky/Version.h>
#include <iostream>
#include <string>
int main() {
    const std::string v = ROCKY_VERSION_STRING;
    if (v != "1.0.2") return 1;
    std::cout << "rocky api ok version=" << v << " abi=" << ROCKY_VERSION_ABI << "\n";
    return 0;
}
EOF
  cmake -S "$d" -B "$d/build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="${PFX};${ROCKY_DEPS_PREFIX};/opt/osg2vsg-0.4.0;/opt/glslang-16.1.0;${VULKAN_SDK_PREFIX}" \
    -Drocky_DIR="${LIBDIR}/cmake/rocky" \
    -Dglm_DIR="${PFX}/lib/cmake/glm" \
    -Dspdlog_DIR="${PFX}/lib/cmake/spdlog" \
    -DEnTT_DIR="${PFX}/lib/cmake/EnTT" \
    -Dnlohmann_json_DIR="${PFX}/lib/cmake/nlohmann_json" \
    -DVulkan_INCLUDE_DIR="${VULKAN_SDK_PREFIX}/include" \
    -DVulkan_LIBRARY=/usr/lib64/libvulkan.so
  cmake --build "$d/build" --parallel 2
  LD_LIBRARY_PATH="${LIBDIR}:${PFX}/lib:/opt/osg2vsg-0.4.0/lib64:/opt/glslang-16.1.0/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "$d/build/smoke"
}

ldd_clean() {
  local out lib
  lib="$(find "$LIBDIR" -maxdepth 1 -name 'librocky.so*' -print -quit)"
  out="$(ldd "$lib" 2>&1)"
  printf '%s\n' "$out" > "${EVID}/ldd-installed.txt"
  ! grep -q 'not found' <<<"$out"
}

upstream_tests() {
  local exe="${LIBDIR}/../bin/rocky_tests" cwd="${PFX}/share/rocky"
  [[ -x "$exe" ]] || return 0
  mkdir -p "$cwd"
  ( cd "$cwd" && LD_LIBRARY_PATH="$LIBDIR:${PFX}/lib:/opt/osg2vsg-0.4.0/lib64:/opt/glslang-16.1.0/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" "$exe" --list-tests )
}

echo "== 安装模式: ${INSTALL_MODE} =="
check package_contents rpm_files
if [[ "$INSTALL_MODE" == "system-rpm" ]]; then check rpm_installed rpm_query; fi
check installed_files installed_files
check api_smoke api_smoke
check ldd_clean ldd_clean
check upstream_tests upstream_tests

if ! python3 - "${EVID}" "${ROCKY_VERSION}" "${INSTALL_MODE}" "${CHECKS[@]}" <<'PY'
import json, os, sys
evid, version, mode, *items = sys.argv[1:]
checks = {}
for item in items:
    k, _, v = item.partition(':'); checks[k] = v
mandatory = ('package_contents', 'installed_files', 'api_smoke', 'ldd_clean')
if mode == 'system-rpm': mandatory += ('rpm_installed',)
failed = [k for k in mandatory if checks.get(k) != 'PASS']
report = {'stage': 'ROCKY_STAGE_3_INSTALL_AND_SELFTEST',
          'environment': 'self-hosted Kylin V10 / x86_64 / Hygon C86',
          'rocky_version': version, 'install_mode': mode,
          'checks': checks, 'failed_checks': failed,
          'verdict': 'PASS' if not failed else 'FAIL'}
text = json.dumps(report, ensure_ascii=False, indent=2)
with open(os.path.join(evid, 'install-selftest.json'), 'w', encoding='utf-8') as f:
    f.write(text + '\n')
print(text); sys.exit(0 if not failed else 1)
PY
then echo "ROCKY SELFTEST FAIL" >&2; exit 1; fi
stage_marker ROCKY_STAGE_3_INSTALL_OK PASS "${ROCKY_REPORT_DIR}/rocky-install-ok.json"
info "ROCKY INSTALL + SELFTEST PASS"
