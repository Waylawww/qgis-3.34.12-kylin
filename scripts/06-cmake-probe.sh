#!/usr/bin/env bash
# 阶段 1b：用「当前主机上真实存在的依赖」对 QGIS 3.34.12 跑一次 CMake 配置，
# 目的不是编译，而是拿到 CMake 实际报告的缺失/过旧依赖清单，作为依赖源码
# 构建顺序的权威依据。配置失败是预期结果，不阻断流水线。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env

SRC_DIR="${WORK_DIR}/src/qgis-${QGIS_VERSION}"
PROBE_BUILD="${WORK_DIR}/cmake-probe"
LOG="${REPORT_DIR}/logs/cmake-probe.log"
mkdir -p "${REPORT_DIR}/logs"

[[ -f "${SRC_DIR}/CMakeLists.txt" ]] || die "缺少源码 ${SRC_DIR}，请先运行 05-fetch-qgis-source.sh"

info "== 阶段 1b / CMAKE PROBE（收集真实缺失依赖）=="
rm -rf "$PROBE_BUILD"
mkdir -p "$PROBE_BUILD"

DEPS_PREFIX="${DEPS_PREFIX:-${REPO_ROOT}/.cache/qgis-334-deps}"
CACHE_LIST="${DEPS_PREFIX}/lib/cmake;${DEPS_PREFIX}/lib64/cmake;${DEPS_PREFIX}"

set +e
timeout 420 cmake -S "$SRC_DIR" -B "$PROBE_BUILD" -G Ninja \
  -D CMAKE_BUILD_TYPE:STRING=Release \
  -D CMAKE_INSTALL_PREFIX:PATH=/usr \
  -D CMAKE_PREFIX_PATH:PATH="${CACHE_LIST}" \
  -D BUILD_WITH_QT6:BOOL=FALSE \
  -D WITH_CORE:BOOL=TRUE \
  -D WITH_GUI:BOOL=TRUE \
  -D WITH_ANALYSIS:BOOL=TRUE \
  -D WITH_DESKTOP:BOOL=TRUE \
  -D WITH_3D:BOOL=TRUE \
  -D WITH_BINDINGS:BOOL=TRUE \
  -D BINDINGS_GLOBAL_INSTALL:BOOL=TRUE \
  -D WITH_QGIS_PROCESS:BOOL=TRUE \
  -D WITH_AUTH:BOOL=TRUE \
  -D WITH_SERVER:BOOL=FALSE \
  -D WITH_GRASS7:BOOL=FALSE -D WITH_GRASS8:BOOL=FALSE \
  -D WITH_PDAL:BOOL=FALSE -D WITH_EPT:BOOL=FALSE -D WITH_COPC:BOOL=FALSE \
  -D WITH_DRACO:BOOL=FALSE -D WITH_QTWEBKIT:BOOL=FALSE \
  -D WITH_QTSERIALPORT:BOOL=FALSE -D WITH_QTGAMEPAD:BOOL=FALSE \
  -D WITH_QUICK:BOOL=FALSE -D WITH_ORACLE:BOOL=FALSE -D WITH_HANA:BOOL=FALSE \
  -D WITH_QSPATIALITE:BOOL=FALSE -D WITH_SPATIALITE:BOOL=FALSE \
  -D WITH_POSTGRESQL:BOOL=TRUE -D WITH_GSL:BOOL=TRUE \
  -D WITH_INTERNAL_MDAL:BOOL=TRUE -D WITH_INTERNAL_POLY2TRI:BOOL=TRUE \
  -D WITH_INTERNAL_LAZPERF:BOOL=TRUE -D WITH_CUSTOM_WIDGETS:BOOL=FALSE \
  -D WITH_CRASH_HANDLER:BOOL=FALSE -D WITH_ASTYLE:BOOL=FALSE \
  -D USE_OPENCL:BOOL=FALSE -D USE_CCACHE:BOOL=FALSE \
  -D QGIS_INSTALL_SYS_LIBS:BOOL=FALSE -D ENABLE_TESTS:BOOL=FALSE \
  -D PEDANTIC:BOOL=FALSE -D WERROR:BOOL=FALSE \
  > "$LOG" 2>&1
rc=$?
set -e
log "cmake probe exit=${rc}（非 0 属于预期，仅用于采集缺失依赖）"

cp -f "$PROBE_BUILD/CMakeCache.txt" "$REPORT_DIR/CMakeCache.probe.txt" 2>/dev/null || true
{
  echo "# QGIS ${QGIS_VERSION} CMake 配置报告（真实主机）"
  echo "# cmake exit=${rc}"
  echo
  echo "## 缺失 / 版本不符 / 报错"
  grep -E 'Could NOT find|Could not find|Could not find a package|Found unsuitable version|CMake Error|Required is at least|is required|not found' "$LOG" \
    | sed 's/^/  /' | sort -u || true
  echo
  echo "## 已找到的关键依赖"
  grep -E '^-- Found (Qt5|PROJ|GEOS|GDAL|QCA|Qwt|QScintilla|QtKeychain|SIP|PyQt5|Spatialindex|SpatiaLite|PostgreSQL|GSL|LibZip|Protobuf|SQLite3|Expat|LibXml2|ZSTD)' "$LOG" \
    | sed 's/^/  /' | sort -u || true
} > "$REPORT_DIR/cmake-probe-summary.txt"

cp -f "$REPORT_DIR/cmake-probe-summary.txt" "${REPO_ROOT}/reports/cmake-probe-summary.txt" 2>/dev/null || true
cat "$REPORT_DIR/cmake-probe-summary.txt"
info "CMAKE PROBE DONE —— 完整日志: ${LOG}"
