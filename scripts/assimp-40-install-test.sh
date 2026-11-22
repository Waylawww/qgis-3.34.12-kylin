#!/usr/bin/env bash
# 阶段 3：把构建出的 RPM 安装到目标主机（优先系统安装，无 sudo 则解包到
# 独立目录模拟安装），随后执行 CLI / pkg-config / C++ 链接 / 模型导入 / ldd 自测。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/assimp.env"

RPM="$(find "${ASSIMP_OUT_DIR}/rpms" -maxdepth 1 -name 'assimp-*.rpm' ! -name '*.src.rpm' -type f | sort | head -n1)"
[[ -n "$RPM" ]] || die "未找到 assimp 二进制 RPM"
EVID="${ASSIMP_REPORT_DIR}/install-selftest"
mkdir -p "$EVID"

echo "runner: $(id -un) uid=$(id -u)"
echo "rpm: ${RPM}"

# ---------------- 安装 ------------------------------------------------------
# 优先走 root 预置的受限安装器（与 QGIS 同款思路）：runner 只能调用固定的
# /usr/local/sbin/assimp-ci-install，无法借安装 RPM 间接获得 root。
INSTALLER=/usr/local/sbin/assimp-ci-install
INSTALL_MODE="rpm-extract"
INSTALL_ROOT="$ASSIMP_RPM_ROOT"
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
  rm -rf "$INSTALL_ROOT"
  mkdir -p "$INSTALL_ROOT"
  ( cd "$INSTALL_ROOT" && rpm2cpio "$RPM" | cpio -idm --quiet --no-absolute-filenames ) \
    >"${EVID}/rpm-extract.log" 2>&1
fi

PFX="${INSTALL_ROOT}${ASSIMP_INSTALL_PREFIX}"
LIBDIR="${PFX}/lib64"
INCDIR="${PFX}/include"
BIN="${PFX}/bin/assimp"
MODEL="${PFX}/share/assimp-selftest/box.obj"
[[ -f "${LIBDIR}/libassimp.so.${ASSIMP_VERSION}" || -L "${LIBDIR}/libassimp.so.${ASSIMP_VERSION}" ]] \
  || die "RPM 安装树缺少 libassimp.so.${ASSIMP_VERSION}"
[[ -f "$BIN" ]] || die "RPM 安装树缺少 assimp 命令行工具"
[[ -f "$MODEL" ]] || die "RPM 安装树缺少自测模型 box.obj"
export LD_LIBRARY_PATH="${LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# ---------------- 检查项 ----------------------------------------------------
CHECKS=()
check() {
  local name="$1"; shift
  if "$@" >"${EVID}/${name}.log" 2>&1; then
    echo "  PASS  ${name}"
    CHECKS+=("${name}:PASS")
  else
    echo "  FAIL  ${name}"
    tail -n 20 "${EVID}/${name}.log" >&2 || true
    CHECKS+=("${name}:FAIL")
  fi
}

rpm_files() { rpm -qlp "$RPM" | grep -q 'libassimp.so' && rpm -qlp "$RPM" | grep -q '/bin/assimp'; }
rpm_query()  { rpm -q assimp; }
installed_files() { test -f "${PFX}/include/assimp/Importer.hpp" && test -d "$LIBDIR"; }

assimp_version() {
  local out
  out="$("$BIN" version 2>&1)"
  printf '%s\n' "$out"
  # CLI 只打印 "Version 6.0"，完整 6.0.5 由 pkg_config_version 校验
  grep -Eq "Version ${ASSIMP_VERSION%.*}([^0-9]|$)" <<<"$out"
}

assimp_info() {
  local out
  out="$("$BIN" info "$MODEL" 2>&1)"
  printf '%s\n' "$out"
  grep -qi 'mesh\|vertex' <<<"$out"
}

pkg_config_version() {
  local out
  out="$(PKG_CONFIG_SYSROOT_DIR="${INSTALL_ROOT}" PKG_CONFIG_PATH="${LIBDIR}/pkgconfig" \
          pkg-config --modversion assimp 2>&1)"
  printf '%s\n' "$out"
  [[ "$out" == "${ASSIMP_VERSION}" ]]
}

cpp_import_smoke() {
  local cpp="${EVID}/assimp_smoke.cpp" exe="${EVID}/assimp_smoke"
  cat > "$cpp" <<'CPP'
#include <assimp/Importer.hpp>
#include <assimp/scene.h>
#include <assimp/postprocess.h>
#include <iostream>
int main(int argc, char **argv) {
    if (argc != 2) return 1;
    Assimp::Importer importer;
    const aiScene *scene = importer.ReadFile(argv[1], aiProcess_Triangulate);
    if (!scene) { std::cerr << importer.GetErrorString() << std::endl; return 2; }
    std::cout << "meshes=" << scene->mNumMeshes << std::endl;
    return scene->mNumMeshes > 0 ? 0 : 3;
}
CPP
  g++ -std=c++17 -O2 "-I${INCDIR}" "$cpp" -o "$exe" \
      "-L${LIBDIR}" -lassimp "-Wl,-rpath,${LIBDIR}"
  "$exe" "$MODEL"
}

ldd_clean() {
  local out
  out="$( { ldd "$LIBDIR/libassimp.so.${ASSIMP_VERSION}"; ldd "$BIN"; } 2>&1 )"
  printf '%s\n' "$out" > "${EVID}/ldd-installed.txt"
  ! grep -q 'not found' <<<"$out"
}

gtest_filter() {
  local unit
  unit="$(find "${ASSIMP_BUILD_DIR}" -type f -name unit -perm -u+x | head -n1)"
  [[ -n "$unit" ]] || return 1
  "$unit" --gtest_filter='utObjImportExport.*' 2>&1
}

echo "== 安装模式: ${INSTALL_MODE} =="
check package_contents rpm_files
if [[ "$INSTALL_MODE" == "system-rpm" ]]; then
  check rpm_installed rpm_query
fi
check installed_files installed_files
check assimp_version assimp_version
check assimp_info assimp_info
check pkg_config_version pkg_config_version
check cpp_import_smoke cpp_import_smoke
check ldd_clean ldd_clean
check gtest_obj gtest_filter

# ---------------- JSON 报告 -------------------------------------------------
if ! python3 - "${EVID}" "${ASSIMP_VERSION}" "${INSTALL_MODE}" "${CHECKS[@]}" <<'PY'
import json, os, sys
evid, version, mode, *items = sys.argv[1:]
checks = {}
for item in items:
    k, _, v = item.partition(':')
    checks[k] = v
mandatory = ('package_contents', 'installed_files', 'assimp_version', 'assimp_info',
             'pkg_config_version', 'cpp_import_smoke', 'ldd_clean', 'gtest_obj')
if mode == 'system-rpm':
    mandatory += ('rpm_installed',)
failed = [k for k in mandatory if checks.get(k) != 'PASS']
report = {
    'stage': 'ASSIMP_STAGE_3_INSTALL_AND_SELFTEST',
    'environment': 'self-hosted runner host, Kylin V10 / %s' % os.uname().machine,
    'host': os.uname().nodename,
    'run_as': os.popen('id -un').read().strip(),
    'assimp_version': version,
    'install_mode': mode,
    'install_root': os.environ.get('ASSIMP_RPM_ROOT', ''),
    'checks': checks,
    'failed_checks': failed,
    'verdict': 'PASS' if not failed else 'FAIL',
}
path = os.path.join(evid, 'install-selftest.json')
text = json.dumps(report, ensure_ascii=False, indent=2)
with open(path, 'w', encoding='utf-8') as f:
    f.write(text + '\n')
print(text)
sys.exit(0 if not failed else 1)
PY
then
  echo "ASSIMP INSTALL + SELFTEST FAIL" >&2
  exit 1
fi

stage_marker ASSIMP_STAGE_3_INSTALL_OK PASS "${ASSIMP_REPORT_DIR}/assimp-install-ok.json"
info "ASSIMP INSTALL + SELFTEST PASS"
