#!/usr/bin/env bash
# 阶段 3：用 $DEPS_PREFIX 里真实编译出的依赖配置 QGIS 3.34.12，全量编译，
# DESTDIR 安装，再把 QGIS 安装树 + 私有依赖树一起打成麒麟原生 RPM。
#
# 设计要点（避免改写 ELF RPATH、也避免把库装进 /usr）：
#   * CMAKE_INSTALL_PREFIX=/opt/qgis-3.34.12，QGIS 自身 RUNPATH 直接写成
#     安装后的绝对路径；WITH_BINDINGS 时 PyQGIS 落到 ${QGIS_DATA_DIR}/python，
#     也在私有前缀内（QGIS CMakeLists.txt 里 set(Python_SITEARCH ...)）。
#   * 私有依赖原样放到 /opt/qgis-3.34.12/deps/{lib,lib64,plugins,share}。
#   * /usr/bin/qgis、/usr/bin/qgis_process 是 wrapper，注入
#     LD_LIBRARY_PATH / QT_PLUGIN_PATH / PYTHONPATH / PROJ_LIB / GDAL_DATA，
#     让依赖之间互相加载不依赖构建机路径。
#   * spec 只是二进制打包（%build 为空、AutoReqProv: no），不重复编译，
#     因此 rpmbuild 里不会再跑一次 QGIS 构建。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env

need_cmd cmake "QGIS CMake 配置"
need_cmd ninja "QGIS 编译"
need_cmd rpmbuild "原生 RPM 打包"

JOBS="${QGIS_BUILD_JOBS:-6}"
QGIS_SRC="${WORK_DIR}/src/qgis-${QGIS_VERSION}"
SYSROOT="${DEPS_PREFIX}/sysroot"
QGIS_BUILD="${WORK_DIR}/qgis-build"
STAGE="${WORK_DIR}/qgis-stage"
TOP="${WORK_DIR}/rpmbuild"
PREFIX_IN_RPM="/opt/qgis-${QGIS_VERSION}"
DEPS_IN_RPM="${PREFIX_IN_RPM}/deps"
LOG="${REPORT_DIR}/logs"
mkdir -p "$LOG" "${TOP}/SPECS" "${OUT_DIR}/rpms" "${OUT_DIR}/srpms" "${REPORT_DIR}/stages"

info "== 阶段 3 / BUILD QGIS ${QGIS_VERSION} (native, jobs=$JOBS) =="
log "源码=$QGIS_SRC  依赖前缀=$DEPS_PREFIX  RPM 内前缀=$PREFIX_IN_RPM"

# --- 源码与依赖就绪门禁（拒绝拿空树伪造成功） ------------------------------
if [[ ! -f "${QGIS_SRC}/CMakeLists.txt" ]]; then
  warn "源码不在缓存中，调用 05-fetch-qgis-source.sh 下载"
  bash "${REPO_ROOT}/scripts/05-fetch-qgis-source.sh"
fi
[[ -f "${QGIS_SRC}/CMakeLists.txt" ]] || die "QGIS 源码缺失: ${QGIS_SRC}"
grep -q "CPACK_PACKAGE_VERSION_PATCH.*12" "${QGIS_SRC}/CMakeLists.txt" \
  || die "源码版本不是 3.34.12，拒绝构建"
[[ -x "${DEPS_PREFIX}/bin/qmake" ]] || die "依赖未就绪：缺 ${DEPS_PREFIX}/bin/qmake，请先跑 stage=deps"

GCC_LIBDIR="$(cat "${REPORT_DIR}/gcc-runtime.txt" 2>/dev/null || true)"
if [[ "${GCC_LIBDIR}" == "NOT_FOUND" || ! -d "${GCC_LIBDIR}" ]]; then
  GCC_LIBDIR=""
fi

PY_SITE="${DEPS_PREFIX}/lib/python3.7/site-packages"
export PATH="${DEPS_PREFIX}/bin:${PY_SITE}/bin:$PATH"
export PYTHONPATH="${PY_SITE}${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="${GCC_LIBDIR:+${GCC_LIBDIR}:}${DEPS_PREFIX}/lib:${DEPS_PREFIX}/lib64:${SYSROOT}/usr/lib64:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig:${DEPS_PREFIX}/lib64/pkgconfig:${SYSROOT}/usr/lib64/pkgconfig:${SYSROOT}/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="${DEPS_PREFIX};${SYSROOT}/usr"
export CPPFLAGS="-I${DEPS_PREFIX}/include -I${SYSROOT}/usr/include ${CPPFLAGS:-}"
export LDFLAGS="-L${DEPS_PREFIX}/lib -L${DEPS_PREFIX}/lib64 -L${SYSROOT}/usr/lib64 ${LDFLAGS:-}"

# QGIS 3.34 的 cmake/FindPyQt5.cmake 在 SIP>=5 分支把 METADATA / PyQt5 /
# PyQt5/bindings 都拼在 ${Python_SITEARCH} 上；find_package(Python) 给的是
# /usr/lib64/python3.7/site-packages，runner 无写权限、也不会有我们的 PyQt5。
# 改用环境变量把探测路径指到私有 site-packages（补丁幂等）。
export QGIS_PY_SITE="$PY_SITE"
FIND_PYQT5="${QGIS_SRC}/cmake/FindPyQt5.cmake"
[[ -f "$FIND_PYQT5" ]] || die "缺 QGIS CMake 模块: $FIND_PYQT5"
# 用纯字符串替换而不是 sed：${Python_SITEARCH} / $ENV{...} 里的 $ 和 { }
# 在 sed 正则/替换串里语义容易出错，Python 直替最稳。补丁幂等。
python3 - "$FIND_PYQT5" <<'PY'
import sys
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    src = f.read()
needle = '${Python_SITEARCH}'
replacement = '$ENV{QGIS_PY_SITE}'
if 'QGIS_PY_SITE' in src:
    print('FindPyQt5.cmake 补丁已存在')
elif needle not in src:
    print('WARN: FindPyQt5.cmake 里没有 ${Python_SITEARCH}')
else:
    with open(path, 'w', encoding='utf-8') as f:
        f.write(src.replace(needle, replacement))
    print('已替换 %d 处探测路径' % src.count(needle))
PY
grep -q 'QGIS_PY_SITE' "$FIND_PYQT5" \
  || die "FindPyQt5.cmake 补丁失败: $FIND_PYQT5"

# --- CMake 配置 -------------------------------------------------------------
# 显式关掉麒麟主机上没有的可选依赖：GRASS / spatialite / PDAL / EPT / COPC /
# Draco / QtWebKit / QtSerialPort。3D、Desktop、PyQGIS、qgis_process 保持开启。

# QGIS 链接的 Protobuf 库名是开发期链接名（libprotobuf.so / libprotobuf-lite.so
# / libprotoc.so）。麒麟的 protobuf-devel 只提供了 libprotobuf.so，lite 与 protoc
# 的链接名往往缺失，磁盘上只有版本化文件 libXXX.so.N；ninja 链接时会报
# "...libprotobuf-lite.so, missing and no known rule to make it"。这里补齐这些
# 链接名（指向已存在的版本化文件），CMake 变量即可对上。
for _pb in libprotobuf libprotobuf-lite libprotoc; do
  _link="${SYSROOT}/usr/lib64/${_pb}.so"
  if [[ ! -e "$_link" ]]; then
    _ver="$(ls -v "${SYSROOT}/usr/lib64/${_pb}.so".* 2>/dev/null \
            | grep -E '\.so\.[0-9]+$' | tail -1)"
    [[ -n "$_ver" ]] && ln -sf "$(basename "$_ver")" "$_link"
  fi
done

rm -rf "$QGIS_BUILD"
set -o pipefail
cmake -S "$QGIS_SRC" -B "$QGIS_BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE:STRING=Release \
  -DCMAKE_INSTALL_PREFIX:PATH="$PREFIX_IN_RPM" \
  -DCMAKE_INSTALL_LIBDIR:STRING=lib \
  -DCMAKE_PREFIX_PATH:PATH="${DEPS_PREFIX};${SYSROOT}/usr" \
  -DCMAKE_INSTALL_RPATH:STRING="${PREFIX_IN_RPM}/lib;${DEPS_IN_RPM}/lib;${DEPS_IN_RPM}/lib64" \
  -DCMAKE_INSTALL_RPATH_USE_LINK_PATH:BOOL=OFF \
  -DCMAKE_C_FLAGS:STRING="$ISA_CFLAGS" \
  -DCMAKE_CXX_FLAGS:STRING="$ISA_CXXFLAGS" \
  -DWITH_CORE:BOOL=ON -DWITH_GUI:BOOL=ON -DWITH_ANALYSIS:BOOL=ON \
  -DWITH_3D:BOOL=ON -DWITH_BINDINGS:BOOL=ON \
  -DWITH_DESKTOP:BOOL=ON -DWITH_QGIS_PROCESS:BOOL=ON \
  -DWITH_SERVER:BOOL=OFF -DWITH_SERVER_PLUGINS:BOOL=OFF \
  -DWITH_AUTH:BOOL=ON -DWITH_OAUTH2_PLUGIN:BOOL=ON \
  -DWITH_GRASS7:BOOL=OFF -DWITH_GRASS8:BOOL=OFF \
  -DWITH_SPATIALITE:BOOL=OFF -DWITH_QSPATIALITE:BOOL=OFF \
  -DWITH_POSTGRESQL:BOOL=OFF -DWITH_ORACLE:BOOL=OFF -DWITH_HANA:BOOL=OFF \
  -DWITH_PDAL:BOOL=OFF -DWITH_EPT:BOOL=OFF -DWITH_COPC:BOOL=OFF \
  -DWITH_DRACO:BOOL=OFF -DWITH_QTWEBKIT:BOOL=OFF \
  -DWITH_QTSERIALPORT:BOOL=OFF -DWITH_QTGAMEPAD:BOOL=OFF \
  -DWITH_QSCIAPI:BOOL=OFF -DWITH_CUSTOM_WIDGETS:BOOL=OFF \
  -DWITH_STAGED_PLUGINS:BOOL=OFF -DWITH_CRASH_HANDLER:BOOL=OFF \
  -DWITH_INTERNAL_MDAL:BOOL=ON -DWITH_INTERNAL_POLY2TRI:BOOL=ON \
  -DPython_SITEARCH:PATH="$PY_SITE" \
  -DSIP_BUILD_EXECUTABLE:FILEPATH="${DEPS_PREFIX}/bin/sip-build" \
  -DQMAKE_EXECUTABLE:FILEPATH="${DEPS_PREFIX}/bin/qmake" \
  -DPYQT5_MOD_DIR:PATH="$PY_SITE/PyQt5" \
  -DPYQT5_SIP_DIR:PATH="$PY_SITE/PyQt5/bindings" \
  -DProtobuf_INCLUDE_DIR:PATH="${SYSROOT}/usr/include" \
  -DProtobuf_LIBRARY:FILEPATH="${SYSROOT}/usr/lib64/libprotobuf.so" \
  -DProtobuf_LITE_LIBRARY:FILEPATH="${SYSROOT}/usr/lib64/libprotobuf-lite.so" \
  -DProtobuf_PROTOC_LIBRARY:FILEPATH="${SYSROOT}/usr/lib64/libprotoc.so" \
  -DProtobuf_PROTOC_EXECUTABLE:FILEPATH="${SYSROOT}/usr/bin/protoc" \
  2>&1 | tee "${LOG}/qgis-cmake.log"

grep -E '^(WITH_3D|WITH_BINDINGS|WITH_DESKTOP|WITH_QGIS_PROCESS|CMAKE_INSTALL_PREFIX|CMAKE_INSTALL_RPATH):' \
  "${QGIS_BUILD}/CMakeCache.txt" | tee "${REPORT_DIR}/cmake-options.txt" || true

# --- 编译 / DESTDIR 安装 ----------------------------------------------------
ninja -C "$QGIS_BUILD" -j"$JOBS" 2>&1 | tee "${LOG}/qgis-build.log"
rm -rf "$STAGE"; mkdir -p "$STAGE"
DESTDIR="$STAGE" ninja -C "$QGIS_BUILD" install 2>&1 | tee "${LOG}/qgis-install.log"

[[ -d "${STAGE}${PREFIX_IN_RPM}" ]] || die "DESTDIR 安装未产生 ${PREFIX_IN_RPM}"
log "QGIS 安装树文件数: $(find "${STAGE}${PREFIX_IN_RPM}" -type f | wc -l)"

# --- 私有依赖随 RPM 一起安装 ------------------------------------------------
DEPS_STAGE="${STAGE}${DEPS_IN_RPM}"
mkdir -p "${DEPS_STAGE}/lib" "${DEPS_STAGE}/lib64" "${DEPS_STAGE}/share"
for src_lib in lib lib64; do
  if [[ -d "${DEPS_PREFIX}/${src_lib}" ]]; then
    find "${DEPS_PREFIX}/${src_lib}" -maxdepth 1 \( -name '*.so' -o -name '*.so.*' \) \
      -exec cp -a {} "${DEPS_STAGE}/${src_lib}/" \;
  fi
done
# QGIS core 链接了 sysroot 里的 libprotobuf.so.25 / libprotobuf-lite.so.25
# （vector tiles）与 libgsl.so.25 / libgslcblas.so.0（analysis），这些库不在
# $DEPS_PREFIX 下；必须随 RPM 安装，否则包装后 ldd -r 会报 not found。
if [[ -d "${SYSROOT}/usr/lib64" ]]; then
  find "${SYSROOT}/usr/lib64" -maxdepth 1 \
    \( -name 'libprotobuf.so.*' -o -name 'libprotobuf-lite.so.*' \
       -o -name 'libprotoc.so.*' \
       -o -name 'libgsl.so.*' -o -name 'libgslcblas.so.*' \) \
    -exec cp -a {} "${DEPS_STAGE}/lib/" \;
fi
# SIP/PyQt5 的 Python 包
if [[ -d "${DEPS_PREFIX}/lib/python3.7" ]]; then
  cp -a "${DEPS_PREFIX}/lib/python3.7" "${DEPS_STAGE}/lib/"
fi
# Qt 插件与 QML，以及 PROJ/GDAL/QSCI 数据
for d in plugins qml translations mkspecs; do
  if [[ -d "${DEPS_PREFIX}/${d}" ]]; then
    cp -a "${DEPS_PREFIX}/${d}" "${DEPS_STAGE}/"
  fi
done
for d in proj gdal sip PyQt5 Qsci; do
  if [[ -d "${DEPS_PREFIX}/share/${d}" ]]; then
    cp -a "${DEPS_PREFIX}/share/${d}" "${DEPS_STAGE}/share/"
  fi
done
log "私有依赖库文件数: $(find "${DEPS_STAGE}" -type f -name '*.so*' | wc -l)"

# --- /usr/bin wrapper -------------------------------------------------------
mkdir -p "${STAGE}/usr/bin"
for app in qgis qgis_process; do
  cat > "${STAGE}/usr/bin/${app}" <<EOF
#!/bin/sh
# QGIS ${QGIS_VERSION} Kylin V10 自包含启动器
P="${PREFIX_IN_RPM}"
D="${DEPS_IN_RPM}"
export LD_LIBRARY_PATH="\${D}/lib:\${D}/lib64:\${P}/lib:\${LD_LIBRARY_PATH:-}"
export QT_PLUGIN_PATH="\${D}/plugins"
export QML2_IMPORT_PATH="\${D}/qml"
export PYTHONPATH="\${D}/lib/python3.7/site-packages:\${P}/share/qgis/python:\${PYTHONPATH:-}"
export QGIS_PREFIX_PATH="\${P}"
export PROJ_LIB="\${D}/share/proj"
export GDAL_DATA="\${D}/share/gdal"
exec "\${P}/bin/${app}" "\$@"
EOF
  chmod 755 "${STAGE}/usr/bin/${app}"
done

# --- 二进制打包 spec --------------------------------------------------------
SPEC="${TOP}/SPECS/qgis-kylin.spec"
cat > "$SPEC" <<EOF
Name:           qgis
Version:        ${QGIS_VERSION}
Release:        1.ky10
Summary:        QGIS ${QGIS_VERSION} native build for Kylin V10 x86_64
License:        GPLv2+
BuildArch:      x86_64
AutoReqProv:    no
%description
QGIS ${QGIS_VERSION} compiled natively on Kylin V10 / Hygon C86 with a private
Qt 5.15 / PROJ / GEOS / GDAL / SIP runtime under ${PREFIX_IN_RPM}.
%prep
%build
%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a ${STAGE}/. %{buildroot}/
%files
%defattr(-,root,root,-)
/*
%changelog
* Fri Nov 13 2026 QGIS Kylin Builder - ${QGIS_VERSION}-1.ky10
- Native build from upstream tag final-3_34_12
EOF
cp -f "$SPEC" "${REPORT_DIR}/qgis-kylin.spec"
cp -f "$SPEC" "${REPO_ROOT}/packaging/qgis-kylin.spec"

# --- rpmbuild ---------------------------------------------------------------
info "== rpmbuild（仅二进制打包，不重复编译）=="
rpmbuild -ba --define "_topdir ${TOP}" \
  --define "_smp_mflags -j1" \
  "$SPEC" 2>&1 | tee "${LOG}/rpmbuild.log"

RPMS="$(find "${TOP}/RPMS" -name '*.rpm' -type f | sort)"
[[ -n "$RPMS" ]] || die "rpmbuild 未产生任何二进制 RPM"
while IFS= read -r f; do cp -f "$f" "${OUT_DIR}/rpms/"; done <<< "$RPMS"
find "${TOP}/SRPMS" -name '*.src.rpm' -exec cp -f {} "${OUT_DIR}/srpms/" \; || true

python3 - "${REPORT_DIR}" "${OUT_DIR}" "${QGIS_VERSION}" "${PREFIX_IN_RPM}" <<'PY'
import glob, hashlib, json, os, sys
rep, out, version, prefix = sys.argv[1:5]
rpms = [{'name': os.path.basename(p), 'bytes': os.path.getsize(p),
         'sha256': hashlib.sha256(open(p, 'rb').read()).hexdigest()}
        for p in sorted(glob.glob(os.path.join(out, 'rpms', '*.rpm')))]
data = {'qgis_version': version, 'rpm_prefix': prefix, 'rpms': rpms,
        'rpm_count': len(rpms), 'verdict': 'PASS' if rpms else 'FAIL'}
with open(os.path.join(rep, 'qgis-build-report.json'), 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print(json.dumps(data, ensure_ascii=False, indent=2))
PY

stage_marker STAGE_A_SOURCE_BUILD_OK PASS "${REPORT_DIR}/stages/stage-a.json"
stage_marker STAGE_B_RPM_BUILD_OK   PASS "${REPORT_DIR}/stages/stage-b.json"
info "BUILD QGIS PASS —— RPM 已生成到 ${OUT_DIR}/rpms"
