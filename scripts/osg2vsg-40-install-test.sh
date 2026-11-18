#!/usr/bin/env bash
# 阶段 3：RPM 安装（优先 root 受限安装器）+ 安装后 C++ API / 动态库自测。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/osg2vsg.env"

RPM="$(find "${OSG2VSG_OUT_DIR}/rpms" -maxdepth 1 -name 'osg2vsg-*.rpm' ! -name '*.src.rpm' -type f | sort | head -n1)"
[[ -n "$RPM" ]] || die "未找到 osg2vsg 二进制 RPM"
EVID="${OSG2VSG_REPORT_DIR}/install-selftest"; mkdir -p "$EVID"
echo "runner=$(id -un) rpm=$RPM"

INSTALLER=/usr/local/sbin/osg2vsg-ci-install
INSTALL_MODE="rpm-extract"; INSTALL_ROOT="$OSG2VSG_RPM_ROOT"
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

PFX="${INSTALL_ROOT}${OSG2VSG_INSTALL_PREFIX}"
LIBDIR="${PFX}/lib64"; INCDIR="${PFX}/include"
export LD_LIBRARY_PATH="${LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export OSG_LIBRARY_PATH="${LIBDIR}/osgPlugins-3.6.5"
[[ -f "${LIBDIR}/libosg2vsg.so.0.4.0" || -L "${LIBDIR}/libosg2vsg.so.0.4.0" ]] \
  || die "RPM 安装树缺少 libosg2vsg.so.0.4.0"

CHECKS=()
check() { local n="$1"; shift; if "$@" >"${EVID}/${n}.log" 2>&1; then echo "  PASS  $n"; CHECKS+=("$n:PASS"); else echo "  FAIL  $n"; tail -n 20 "${EVID}/${n}.log" >&2 || true; CHECKS+=("$n:FAIL"); fi; }
rpm_files() { rpm -qlp "$RPM" | grep -q 'libosg2vsg.so' && rpm -qlp "$RPM" | grep -q 'libvsg.so' && rpm -qlp "$RPM" | grep -q 'libosg.so'; }
rpm_query() { rpm -q osg2vsg; }
installed_files() { test -f "${INCDIR}/osg2vsg/OSG.h" && test -d "$LIBDIR" && test -d "$LIBDIR/cmake"; }

api_smoke() {
  local d="${EVID}/cmake-smoke"; rm -rf "$d"; mkdir -p "$d"
  cat > "$d/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(osg2vsg_smoke CXX)
find_package(osg2vsg REQUIRED CONFIG)
add_executable(smoke main.cpp)
target_link_libraries(smoke PRIVATE osg2vsg::osg2vsg)
EOF
  cat > "$d/main.cpp" <<'EOF'
#include <osg2vsg/OSG.h>
#include <iostream>
int main() {
    auto rw = osg2vsg::OSG::create();
    if (!rw) return 1;
    std::cout << "osg2vsg api ok\n";
    return 0;
}
EOF
  cmake -S "$d" -B "$d/build" \
    -DCMAKE_PREFIX_PATH="$PFX;/opt/glslang-16.1.0" -DCMAKE_BUILD_TYPE=Release
  cmake --build "$d/build" --parallel 2
  LD_LIBRARY_PATH="$LIBDIR${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    OSG_LIBRARY_PATH="$LIBDIR/osgPlugins-3.6.5" "$d/build/smoke"
}

ldd_clean() {
  local out lib; lib="$(find "$LIBDIR" -maxdepth 1 -name 'libosg2vsg.so*' -print -quit)"
  out="$(ldd "$lib" 2>&1)"; printf '%s\n' "$out" > "${EVID}/ldd-installed.txt"
  ! grep -q 'not found' <<<"$out"
}

echo "== 安装模式: ${INSTALL_MODE} =="
check package_contents rpm_files
if [[ "$INSTALL_MODE" == "system-rpm" ]]; then check rpm_installed rpm_query; fi
check installed_files installed_files
check api_smoke api_smoke
check ldd_clean ldd_clean

if ! python3 - "${EVID}" "${INSTALL_MODE}" "${CHECKS[@]}" <<'PY'
import json, os, sys
evid, mode, *items = sys.argv[1:]
checks={}
for x in items:
    k,_,v=x.partition(':'); checks[k]=v
mandatory=('package_contents','installed_files','api_smoke','ldd_clean')
if mode=='system-rpm': mandatory+=('rpm_installed',)
failed=[k for k in mandatory if checks.get(k)!='PASS']
report={'stage':'OSG2VSG_STAGE_3_INSTALL_AND_SELFTEST',
        'environment':'self-hosted Kylin V10 / x86_64 / Hygon C86',
        'install_mode':mode,'checks':checks,'failed_checks':failed,
        'verdict':'PASS' if not failed else 'FAIL'}
text=json.dumps(report,ensure_ascii=False,indent=2)
with open(os.path.join(evid,'install-selftest.json'),'w',encoding='utf-8') as f: f.write(text+'\n')
print(text); sys.exit(0 if not failed else 1)
PY
then echo "OSG2VSG SELFTEST FAIL" >&2; exit 1; fi
stage_marker OSG2VSG_STAGE_3_INSTALL_OK PASS "${OSG2VSG_REPORT_DIR}/osg2vsg-install-ok.json"
info "OSG2VSG INSTALL + SELFTEST PASS"
