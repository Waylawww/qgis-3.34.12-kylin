#!/usr/bin/env bash
# 阶段 3：在麒麟 V10 容器内执行原生 rpmbuild（真正的全量源码编译发生在这里）。
# 不在 mock/Fedora chroot 里跑：QGIS 官方 rpm/buildrpms.sh 用 mock，但目标系统是
# 麒麟，直接用同一个 Kylin 容器做 native RPM build 才能保证 ABI/依赖一致。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
need_cmd rpmbuild "原生 RPM 构建"
need_cmd tee "保存构建日志"

TOP="${WORK_DIR}/rpmbuild"
SPEC="${TOP}/SPECS/qgis-kylin.spec"
LOG="${LOG_DIR}/rpmbuild.log"
STAGES="${REPORT_DIR}/stages"
mkdir -p "${STAGES}" "${OUT_DIR}/rpms" "${OUT_DIR}/srpms"
[[ -f "${SPEC}" ]] || die "缺少 ${SPEC}，请先运行 scripts/20-render-spec.sh"

stage_marker STAGE_A_SOURCE_BUILD_OK FAIL "${STAGES}/stage-a.json"
stage_marker STAGE_B_RPM_BUILD_OK   FAIL "${STAGES}/stage-b.json"

info "== 阶段 3 / RPMBUILD (native Kylin V10, jobs=${QGIS_BUILD_JOBS:-4}) =="
log "日志: ${LOG}"

set -o pipefail
if ! rpmbuild -ba \
      --define "_topdir ${TOP}" \
      --define "_smp_mflags -j${QGIS_BUILD_JOBS:-4}" \
      "${SPEC}" 2>&1 | tee "${LOG}"; then
  die "rpmbuild 失败，请查看 ${LOG} 末尾 200 行；常见原因见 docs/STAGES.md 阶段 3"
fi

# --- 阶段 A / B 证据 ---------------------------------------------------------
grep -q 'QGIS_STAGE_A_SOURCE_BUILD_OK' "${LOG}" || die "未捕获到 STAGE_A 标记：源码编译未完成"
grep -q 'QGIS_STAGE_B_INSTALL_OK'      "${LOG}" || die "未捕获到 STAGE_B 标记：安装/打包未完成"
stage_marker STAGE_A_SOURCE_BUILD_OK PASS "${STAGES}/stage-a.json"
stage_marker STAGE_B_RPM_BUILD_OK   PASS "${STAGES}/stage-b.json"

# CMakeCache 是 3D/PyQGIS/Desktop 开关的权威证据
CACHE="$(find "${TOP}/BUILD" -name CMakeCache.txt -path '*/build/*' -print -quit || true)"
if [[ -n "${CACHE}" ]]; then
  cp -f "${CACHE}" "${REPORT_DIR}/CMakeCache.txt"
  grep -E '^(WITH_3D|WITH_BINDINGS|WITH_DESKTOP|WITH_SERVER|BUILD_WITH_QT6|CMAKE_INSTALL_PREFIX|QGIS_LIB_SUBDIR):' \
    "${REPORT_DIR}/CMakeCache.txt" | tee "${REPORT_DIR}/cmake-options.txt"
fi

# --- 收集 RPM ---------------------------------------------------------------
RPMS="$(find "${TOP}/RPMS" -name '*.rpm' -type f | sort)"
[[ -n "${RPMS}" ]] || die "rpmbuild 未产生任何二进制 RPM"
while IFS= read -r f; do cp -f "$f" "${OUT_DIR}/rpms/"; done <<< "${RPMS}"
find "${TOP}/SRPMS" -name '*.src.rpm' -exec cp -f {} "${OUT_DIR}/srpms/" \; || true

for pkg in qgis python3-qgis qgis-devel; do
  ls "${OUT_DIR}/rpms/${pkg}-"*.rpm >/dev/null 2>&1 || die "缺少分包 ${pkg} 的 RPM"
done

log "产物:"
find "${OUT_DIR}/rpms" -name '*.rpm' -printf '    %f  %s bytes\n' | sort

info "RPMBUILD PASS —— STAGE_A(源码编译) + STAGE_B(RPM 打包) 均已通过"
