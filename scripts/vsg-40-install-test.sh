#!/usr/bin/env bash
# 阶段 3：RPM 安装（优先 root 受限安装器）+ 安装后 CMake API / 动态库自测。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/vsg.env"
# B 设备前缀恢复（config/vsg.env 会把 GLSLANG_PREFIX 覆盖为 A 设备 /opt 路径）
[[ -n "${B_GLSLANG_PREFIX:-}" ]] && GLSLANG_PREFIX="$B_GLSLANG_PREFIX"

RPM="$(find "${VSG_OUT_DIR}/rpms" -maxdepth 1 -name 'vsg-*.rpm' ! -name '*.src.rpm' -type f | sort | head -n1)"
[[ -n "$RPM" ]] || die "未找到 vsg 二进制 RPM"
EVID="${VSG_REPORT_DIR}/install-selftest"
mkdir -p "$EVID"
echo "runner=$(id -un) rpm=$RPM"

# api_smoke 优先用注入的新版 cmake（B 设备系统 cmake 3.16 可能过低）。
SMOKE_CMAKE="${VSG_CMAKE:-}"
if [[ -z "$SMOKE_CMAKE" ]] || ! "$SMOKE_CMAKE" --version 2>/dev/null | grep -Eq '3\.(2[1-9]|[3-9][0-9])'; then
  SMOKE_CMAKE="$(command -v cmake)"
  for bc in "${DEPS_PREFIX:-}/bin/cmake" "${GLSLANG_PREFIX%/opt/*}/tools"/cmake-*/bin/cmake; do
    [[ -x "$bc" ]] || continue
    if "$bc" --version 2>/dev/null | head -n1 | grep -Eq '3\.(2[1-9]|[3-9][0-9])'; then
      SMOKE_CMAKE="$bc"; break
    fi
  done
fi
log "api_smoke cmake: ${SMOKE_CMAKE} ($(${SMOKE_CMAKE} --version | head -n1))"

INSTALLER=/usr/local/sbin/vsg-ci-install
INSTALL_MODE="rpm-extract"
INSTALL_ROOT="$VSG_RPM_ROOT"
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

PFX="${INSTALL_ROOT}${VSG_INSTALL_PREFIX}"
LIBDIR="${PFX}/lib64"
INCDIR="${PFX}/include"
export LD_LIBRARY_PATH="${LIBDIR}:${GLSLANG_PREFIX}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
[[ -f "${LIBDIR}/libvsg.so.${VSG_SOVERSION}" || -L "${LIBDIR}/libvsg.so.${VSG_SOVERSION}" ]] \
  || die "RPM 安装树缺少 libvsg.so.${VSG_SOVERSION}"

CHECKS=()
check() { local n="$1"; shift; if "$@" >"${EVID}/${n}.log" 2>&1; then echo "  PASS  $n"; CHECKS+=("$n:PASS"); else echo "  FAIL  $n"; tail -n 20 "${EVID}/${n}.log" >&2 || true; CHECKS+=("$n:FAIL"); fi; }

rpm_files() {
  rpm -qlp "$RPM" | grep -q 'libvsg.so' &&
  rpm -qlp "$RPM" | grep -q 'vsgConfig.cmake'
}
rpm_query() { rpm -q vsg; }
installed_files() {
  test -f "${INCDIR}/vsg/core/Version.h" &&
  test -f "${LIBDIR}/cmake/vsg/vsgConfig.cmake"
}

api_smoke() {
  local d="${EVID}/cmake-smoke"
  rm -rf "$d"; mkdir -p "$d"
  cat > "$d/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(vsg_smoke CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(vsg REQUIRED CONFIG)
add_executable(smoke main.cpp)
target_link_libraries(smoke PRIVATE vsg::vsg)
EOF
  cat > "$d/main.cpp" <<'EOF'
#include <vsg/core/Version.h>
#include <iostream>
#include <string>
int main() {
    const std::string v = vsgGetVersionString();
    if (v != "1.1.13") return 1;
    if (!vsgBuiltAsSharedLibrary()) return 2;
    std::cout << "vsg api ok version=" << v << " so=" << vsgGetSOVersionString() << "\n";
    return 0;
}
EOF
  "$SMOKE_CMAKE" -S "$d" -B "$d/build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="${PFX};${GLSLANG_PREFIX};${VULKAN_SDK_PREFIX}" \
    -Dvsg_DIR="${LIBDIR}/cmake/vsg" \
    -DVulkan_INCLUDE_DIR="${VULKAN_SDK_PREFIX}/include" \
    -DVulkan_LIBRARY=/usr/lib64/libvulkan.so
  "$SMOKE_CMAKE" --build "$d/build" --parallel 2
  LD_LIBRARY_PATH="${LIBDIR}:${GLSLANG_PREFIX}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "$d/build/smoke"
}

ldd_clean() {
  local out lib
  lib="$(find "$LIBDIR" -maxdepth 1 -name 'libvsg.so*' -print -quit)"
  out="$(ldd "$lib" 2>&1)"
  printf '%s\n' "$out" > "${EVID}/ldd-installed.txt"
  ! grep -q 'not found' <<<"$out"
}

echo "== 安装模式: ${INSTALL_MODE} =="
check package_contents rpm_files
if [[ "$INSTALL_MODE" == "system-rpm" ]]; then check rpm_installed rpm_query; fi
check installed_files installed_files
check api_smoke api_smoke
check ldd_clean ldd_clean

if ! python3 - "${EVID}" "${VSG_VERSION}" "${INSTALL_MODE}" "${CHECKS[@]}" <<'PY'
import json, os, sys
evid, version, mode, *items = sys.argv[1:]
checks = {}
for item in items:
    k, _, v = item.partition(':'); checks[k] = v
mandatory = ('package_contents', 'installed_files', 'api_smoke', 'ldd_clean')
if mode == 'system-rpm': mandatory += ('rpm_installed',)
failed = [k for k in mandatory if checks.get(k) != 'PASS']
report = {'stage': 'VSG_STAGE_3_INSTALL_AND_SELFTEST',
          'environment': 'self-hosted runner host, Kylin V10 / %s' % os.uname().machine,
          'vsg_version': version, 'install_mode': mode,
          'checks': checks, 'failed_checks': failed,
          'verdict': 'PASS' if not failed else 'FAIL'}
text = json.dumps(report, ensure_ascii=False, indent=2)
with open(os.path.join(evid, 'install-selftest.json'), 'w', encoding='utf-8') as f:
    f.write(text + '\n')
print(text); sys.exit(0 if not failed else 1)
PY
then echo "VSG SELFTEST FAIL" >&2; exit 1; fi
stage_marker VSG_STAGE_3_INSTALL_OK PASS "${VSG_REPORT_DIR}/vsg-install-ok.json"
info "VSG INSTALL + SELFTEST PASS"
