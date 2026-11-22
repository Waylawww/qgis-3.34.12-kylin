#!/usr/bin/env bash
# 阶段 3：RPM 安装（优先 root 受限安装器）+ 安装后 CLI / CMake API / 动态库自测。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/vsgxchange.env"
# B 设备前缀恢复（config/vsgxchange.env 会把依赖前缀覆盖为 A 设备 /opt 路径）
[[ -n "${B_OSG2VSG_PREFIX:-}" ]] && OSG2VSG_PREFIX="$B_OSG2VSG_PREFIX"
[[ -n "${B_GLSLANG_PREFIX:-}" ]] && GLSLANG_PREFIX="$B_GLSLANG_PREFIX"
[[ -n "${B_ASSIMP_PREFIX:-}" ]] && ASSIMP_PREFIX="$B_ASSIMP_PREFIX"

RPM="$(find "${VSGXCHANGE_OUT_DIR}/rpms" -maxdepth 1 -name 'vsgXchange-*.rpm' ! -name '*.src.rpm' -type f | sort | head -n1)"
[[ -n "$RPM" ]] || die "未找到 vsgXchange 二进制 RPM"
EVID="${VSGXCHANGE_REPORT_DIR}/install-selftest"
mkdir -p "$EVID"
echo "runner=$(id -un) rpm=$RPM"

# api_smoke 优先用注入的新版 cmake（B 设备系统 cmake 3.16 可能过低）。
SMOKE_CMAKE="${VSGXCHANGE_CMAKE:-}"
if [[ -z "$SMOKE_CMAKE" ]] || ! "$SMOKE_CMAKE" --version 2>/dev/null | grep -Eq '3\.(2[1-9]|[3-9][0-9])'; then
  SMOKE_CMAKE="$(command -v cmake)"
  for bc in "${DEPS_PREFIX:-}/bin/cmake" "${B_GLSLANG_PREFIX%/opt/*}/tools"/cmake-*/bin/cmake; do
    [[ -x "$bc" ]] || continue
    if "$bc" --version 2>/dev/null | head -n1 | grep -Eq '3\.(2[1-9]|[3-9][0-9])'; then
      SMOKE_CMAKE="$bc"; break
    fi
  done
fi
log "api_smoke cmake: ${SMOKE_CMAKE} ($(${SMOKE_CMAKE} --version | head -n1))"

INSTALLER=/usr/local/sbin/vsgxchange-ci-install
INSTALL_MODE="rpm-extract"
INSTALL_ROOT="$VSGXCHANGE_RPM_ROOT"
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

PFX="${INSTALL_ROOT}${VSGXCHANGE_INSTALL_PREFIX}"
LIBDIR="${PFX}/lib64"
INCDIR="${PFX}/include"
export LD_LIBRARY_PATH="${LIBDIR}:${OSG2VSG_PREFIX}/lib64:${ASSIMP_PREFIX}/lib64:${GLSLANG_PREFIX}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
[[ -f "${LIBDIR}/libvsgXchange.so.${VSGXCHANGE_SOVERSION}" || -L "${LIBDIR}/libvsgXchange.so.${VSGXCHANGE_SOVERSION}" ]] \
  || die "RPM 安装树缺少 libvsgXchange.so.${VSGXCHANGE_SOVERSION}"

CHECKS=()
check() { local n="$1"; shift; if "$@" >"${EVID}/${n}.log" 2>&1; then echo "  PASS  $n"; CHECKS+=("$n:PASS"); else echo "  FAIL  $n"; tail -n 20 "${EVID}/${n}.log" >&2 || true; CHECKS+=("$n:FAIL"); fi; }

rpm_files() {
  rpm -qlp "$RPM" | grep -q 'libvsgXchange.so' &&
  rpm -qlp "$RPM" | grep -q 'vsgXchangeConfig.cmake' &&
  rpm -qlp "$RPM" | grep -q '/bin/vsgconv'
}
rpm_query() { rpm -q vsgXchange; }
installed_files() {
  test -f "${INCDIR}/vsgXchange/Version.h" &&
  test -f "${LIBDIR}/cmake/vsgXchange/vsgXchangeConfig.cmake" &&
  test -x "${PFX}/bin/vsgconv"
}

cli_version() {
  local out
  out="$("${PFX}/bin/vsgconv" --version 2>&1)"
  printf '%s\n' "$out"
  grep -q "${VSGXCHANGE_VERSION}" <<<"$out"
}

api_smoke() {
  local d="${EVID}/cmake-smoke"
  rm -rf "$d"; mkdir -p "$d"
  cat > "$d/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(vsgXchange_smoke CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(vsgXchange REQUIRED CONFIG)
add_executable(smoke main.cpp)
target_link_libraries(smoke PRIVATE vsgXchange::vsgXchange)
EOF
  cat > "$d/main.cpp" <<'EOF'
#include <vsgXchange/Version.h>
#include <iostream>
#include <string>
int main() {
    const std::string v = vsgXchangeGetVersionString();
    if (v != "1.1.9") return 1;
    if (!vsgXchangeBuiltAsSharedLibrary()) return 2;
    std::cout << "vsgXchange api ok version=" << v << " so=" << vsgXchangeGetSOVersionString() << "\n";
    return 0;
}
EOF
  "$SMOKE_CMAKE" -S "$d" -B "$d/build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="${PFX};${OSG2VSG_PREFIX};${ASSIMP_PREFIX};${GLSLANG_PREFIX}" \
    -DvsgXchange_DIR="${LIBDIR}/cmake/vsgXchange" \
    -Dvsg_DIR="${OSG2VSG_PREFIX}/lib64/cmake/vsg" \
    -DVulkan_INCLUDE_DIR="${OSG2VSG_PREFIX}/include" \
    -DVulkan_LIBRARY=/usr/lib64/libvulkan.so
  "$SMOKE_CMAKE" --build "$d/build" --parallel 2
  LD_LIBRARY_PATH="${LIBDIR}:${OSG2VSG_PREFIX}/lib64:${ASSIMP_PREFIX}/lib64:${GLSLANG_PREFIX}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "$d/build/smoke"
}

ldd_clean() {
  local out lib
  lib="$(find "$LIBDIR" -maxdepth 1 -name 'libvsgXchange.so*' -print -quit)"
  out="$(ldd "$lib" 2>&1)"
  printf '%s\n' "$out" > "${EVID}/ldd-installed.txt"
  ! grep -q 'not found' <<<"$out"
}

echo "== 安装模式: ${INSTALL_MODE} =="
check package_contents rpm_files
if [[ "$INSTALL_MODE" == "system-rpm" ]]; then check rpm_installed rpm_query; fi
check installed_files installed_files
check cli_version cli_version
check api_smoke api_smoke
check ldd_clean ldd_clean

if ! python3 - "${EVID}" "${VSGXCHANGE_VERSION}" "${INSTALL_MODE}" "${CHECKS[@]}" <<'PY'
import json, os, sys
evid, version, mode, *items = sys.argv[1:]
checks = {}
for item in items:
    k, _, v = item.partition(':'); checks[k] = v
mandatory = ('package_contents', 'installed_files', 'cli_version', 'api_smoke', 'ldd_clean')
if mode == 'system-rpm': mandatory += ('rpm_installed',)
failed = [k for k in mandatory if checks.get(k) != 'PASS']
report = {'stage': 'VSGXCHANGE_STAGE_3_INSTALL_AND_SELFTEST',
          'environment': 'self-hosted runner host, Kylin V10 / %s' % os.uname().machine,
          'vsgXchange_version': version, 'install_mode': mode,
          'checks': checks, 'failed_checks': failed,
          'verdict': 'PASS' if not failed else 'FAIL'}
text = json.dumps(report, ensure_ascii=False, indent=2)
with open(os.path.join(evid, 'install-selftest.json'), 'w', encoding='utf-8') as f:
    f.write(text + '\n')
print(text); sys.exit(0 if not failed else 1)
PY
then echo "VSGXCHANGE SELFTEST FAIL" >&2; exit 1; fi
stage_marker VSGXCHANGE_STAGE_3_INSTALL_OK PASS "${VSGXCHANGE_REPORT_DIR}/vsgxchange-install-ok.json"
info "VSGXCHANGE INSTALL + SELFTEST PASS"
