#!/usr/bin/env bash
# 阶段 2：渲染 SPEC + 准备标准 rpmbuild 目录树（不引入 mock/Fedora chroot）
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
need_cmd python3 "渲染 SPEC"
need_cmd rpmbuild "原生 RPM 打包"

TOP="${WORK_DIR}/rpmbuild"
mkdir -p "${TOP}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

[[ -f "${WORK_DIR}/rpmbuild/SOURCES/${QGIS_SOURCE_TARBALL}" ]] || \
  die "缺少源码 tarball，请先运行 scripts/10-fetch-source.sh"

info "== 阶段 2 / RENDER SPEC =="
python3 "${REPO_ROOT}/scripts/render-spec.py"

cp -f "${REPO_ROOT}/packaging/qgis-kylin.spec" "${TOP}/SPECS/qgis-kylin.spec"
cp -f "${WORK_DIR}/source-manifest.json" "${REPORT_DIR}/source-manifest.json" 2>/dev/null || true

# 宏可用性再确认（不同 rpm 版本差异很大）
log "rpm 宏: _libdir=$(rpm --eval '%{_libdir}')  python3_sitearch=$(rpm --eval '%{python3_sitearch}')"
log "SPEC 摘要:"
grep -E '^(Name|Version|Release|BuildArch|Source0):' "${TOP}/SPECS/qgis-kylin.spec" | sed 's/^/    /'

info "RENDER SPEC PASS"
