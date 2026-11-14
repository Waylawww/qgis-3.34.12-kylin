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

# QGIS 链接的库名是开发期链接名（libXXX.so），但麒麟的 *-devel 常常只提供
# 这个链接名、或连它都没有，磁盘上实际只有版本化文件 libXXX.so.N（运行时 RPM
# 提供）。ninja 链接时会报 "...libXXX.so, missing and no known rule to make it"。
# 这里为所有需要的库补齐 libXXX.so 链接名（指向已存在的版本化文件），CMake
# 变量即可对上。实测踩过：libprotobuf-lite.so、libprotoc.so、libexpat.so。
#
# !!! 这一段曾让整个作业"无声 exit 1"：日志停在上一行的
#     "FindPyQt5.cmake 补丁已存在" 之后再无输出、直接退出。
#     原写法
#       _ver="$(ls -v ...*.so.* | grep -E ... | tail -1)"
#       [[ -n "$_ver" ]] && ln -sf ...
#     sysroot 里没有对应文件时 _ver 为空，循环体最后那条 `[[ ... ]] && ...`
#     返回 1，在 `set -e` 下直接把脚本带走（且不打印任何东西）。
#     因此这里必须：① 命令替换末尾 `|| true`；② 用 if/else 而不是
#     `[[ ]] && cmd` 结尾；③ 每一步都打日志，出问题能从日志看出是哪个库。
_sysroot_files=0
if [[ -d "${SYSROOT}/usr/lib64" ]]; then
  _sysroot_files="$(find "${SYSROOT}/usr/lib64" -maxdepth 1 -type f | wc -l || true)"
else
  warn "sysroot 不存在: ${SYSROOT}/usr/lib64（依赖阶段没解压 DEVEL RPM？）"
fi
log "sysroot: ${SYSROOT}/usr/lib64 共 ${_sysroot_files} 个文件"
for _pb in libprotobuf libprotobuf-lite libprotoc libexpat; do
  _link="${SYSROOT}/usr/lib64/${_pb}.so"
  if [[ -e "$_link" || -L "$_link" ]]; then
    continue
  fi
  _ver="$(ls -v "${SYSROOT}/usr/lib64/${_pb}.so".* 2>/dev/null \
          | grep -E '\.so\.[0-9]+(\.[0-9]+)*$' | tail -1 || true)"
  if [[ -n "$_ver" ]]; then
    if ln -sf "$(basename "$_ver")" "$_link" 2>/dev/null; then
      log "补链接名: ${_pb}.so -> $(basename "$_ver")"
    else
      warn "补链接名失败: ${_link}（权限或目标目录缺失）"
    fi
  else
    # 麒麟/银河麒麟 V10 自带的 protobuf 运行时 RPM 只有 libprotobuf.so.25 与
    # libprotoc.so.25，没有 libprotobuf-lite。但 QGIS 的 qgis_core 无条件链接
    # Protobuf_LITE_LIBRARY，缺它 CMake 在 generate 阶段就报
    # "Protobuf_LITE_LIBRARY ... set to NOTFOUND"（实测 run 56）。
    # lite 运行时是完整库的子集（同一批源码，符号完全包含在 libprotobuf 里），
    # 所以退化为链接完整库：编译/链接/运行都成立，DT_NEEDED 记录
    # libprotobuf.so.25，正是 RPM 里已经打包的那一份。
    if [[ "$_pb" == libprotobuf-lite && -e "${SYSROOT}/usr/lib64/libprotobuf.so" ]]; then
      ln -sf libprotobuf.so "$_link"
      warn "sysroot 无 libprotobuf-lite.so*，改用 libprotobuf.so 顶替（lite 是 full 的子集）"
    else
      warn "sysroot 缺 ${_pb}.so 与 ${_pb}.so.N，跳过补链接名（若 QGIS 真的链接它，ninja 会明确报错）"
    fi
  fi
done

# EXPAT：sysroot 里确有完整 expat（expat.h + libexpat.so -> libexpat.so.1 ->
# libexpat.so.1.6.11），但 FindEXPAT 经 CMAKE_PREFIX_PATH 自动探测在部分
# runner 上不稳定（实测某些 runner 报 Could NOT find EXPAT）。这里把 sysroot
# 里确凿存在的 expat 复制到 deps 前缀的 include/lib，再显式指向它；deps 前缀
# 的 lib/include 一定会被 find_library/find_path 搜索，最稳。
if [[ -f "$SYSROOT/usr/include/expat.h" && -e "$SYSROOT/usr/lib64/libexpat.so" ]]; then
  mkdir -p "$DEPS_PREFIX/include" "$DEPS_PREFIX/lib"
  cp -a "$SYSROOT/usr/include/expat.h" "$DEPS_PREFIX/include/" 2>/dev/null || true
  cp -a "$SYSROOT/usr/include/expat_external.h" "$DEPS_PREFIX/include/" 2>/dev/null || true
  cp -a "$SYSROOT/usr/include/expat_config.h" "$DEPS_PREFIX/include/" 2>/dev/null || true
  cp -a "$SYSROOT/usr/lib64/libexpat.so"* "$DEPS_PREFIX/lib/" 2>/dev/null || true
fi
_expat_inc="$DEPS_PREFIX/include"
_expat_lib="$DEPS_PREFIX/lib/libexpat.so"
if [[ ! -f "$_expat_inc/expat.h" || ! -e "$_expat_lib" ]]; then
  _expat_inc="$SYSROOT/usr/include"; _expat_lib="$SYSROOT/usr/lib64/libexpat.so"
fi
log "EXPAT hints: inc=$_expat_inc lib=$_expat_lib"

# 显式路径只喂给真实存在的文件：给 CMake 一个不存在的 FILEPATH，它不会报错，
# 而是"找到"了这个不存在的库，问题被拖到 ninja 链接期（`missing and no known
# rule to make it`，比配置期的 Could NOT find 难读得多）。缺少时干脆不传，
# 让 find_package 自己探测并明确报错。
PROTOBUF_HINTS=(); _proto_ok=1
[[ -f "${SYSROOT}/usr/include/google/protobuf/message.h" ]] || _proto_ok=0
for _l in libprotobuf libprotobuf-lite libprotoc; do
  [[ -e "${SYSROOT}/usr/lib64/${_l}.so" ]] || _proto_ok=0
done
[[ -x "${SYSROOT}/usr/bin/protoc" ]] || _proto_ok=0
if (( _proto_ok )); then
  PROTOBUF_HINTS=(
    -DProtobuf_INCLUDE_DIR:PATH="${SYSROOT}/usr/include"
    -DProtobuf_LIBRARY:FILEPATH="${SYSROOT}/usr/lib64/libprotobuf.so"
    -DProtobuf_LITE_LIBRARY:FILEPATH="${SYSROOT}/usr/lib64/libprotobuf-lite.so"
    -DProtobuf_PROTOC_LIBRARY:FILEPATH="${SYSROOT}/usr/lib64/libprotoc.so"
    -DProtobuf_PROTOC_EXECUTABLE:FILEPATH="${SYSROOT}/usr/bin/protoc"
  )
  log "Protobuf hints: ${SYSROOT}/usr（头文件 + libprotobuf/lite/protoc + protoc）"
else
  warn "sysroot 的 protobuf 头文件/库/protoc 不全（${SYSROOT}），不传 Protobuf_* 提示，交给 CMake 探测"
fi

# 不再显式传 -DEXPAT_*（实测显式指向 sysroot 的链接名反而让 FPHSA 判缺失）；
# 改为把 expat 复制进 DEPS_PREFIX（其 lib 一定会被 find_library 搜索），
# 让 FindEXPAT 经 CMAKE_PREFIX_PATH 自动探测，最稳。
EXPAT_HINTS=()
log "前置修正完成，开始 CMake 配置（完整日志: ${LOG}/qgis-cmake.log）"

# --- EXPAT 诊断（打到 stdout，便于在 job 日志里直接看）---
echo "== EXPAT DIAG =="
echo "DEPS_PREFIX=$DEPS_PREFIX"
echo "_expat_inc=$_expat_inc"
echo "_expat_lib=$_expat_lib"
echo "hints=${#EXPAT_HINTS[@]}"
ls -l "$_expat_inc/expat.h" 2>&1 || echo "  (expat.h 缺失: $_expat_inc)"
ls -l "$_expat_lib" 2>&1 || echo "  (libexpat.so 缺失: $_expat_lib)"
ls -l "$DEPS_PREFIX/lib/libexpat.so"* 2>&1 || echo "  (DEPS_PREFIX/lib 无 libexpat.so*)"
echo "CMAKE_PREFIX_PATH=$CMAKE_PREFIX_PATH"

CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE:STRING=Release
  -DCMAKE_INSTALL_PREFIX:PATH="$PREFIX_IN_RPM"
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
)
CMAKE_ARGS+=( ${PROTOBUF_HINTS[@]+"${PROTOBUF_HINTS[@]}"} ${EXPAT_HINTS[@]+"${EXPAT_HINTS[@]}"} )

# --- QGIS 3.34 已知缺陷：WITH_3D=ON + WITH_COPC=OFF 无法编译 ----------------
# src/3d/CMakeLists.txt 无条件编译 qgsvirtualpointcloudentity_p.cpp，而它
# #include "qgsvirtualpointcloudprovider.h"（在 src/core/providers/vpc/ 下），
# 该目录只有 WITH_COPC=ON 时才进 qgis_core 的 PUBLIC include 路径
# （src/core/CMakeLists.txt: if (WITH_COPC) include_directories(providers/vpc)），
# 于是 run 63 在 [1297/3307] 报：
#   src/3d/qgsvirtualpointcloudentity_p.cpp:17:10: fatal error:
#     qgsvirtualpointcloudprovider.h: No such file or directory
# 这个实体只有 VPC provider（需要 COPC/EPT）才会用到，我们两个都关，属于死代码，
# 因此打源码补丁把它裁掉：CMake 侧从源文件列表里移除并定义 QGIS_NO_VPC_PROVIDER，
# renderer 里对应的 include 和 else-if 分支用 #ifndef 包住。
# 注意：只改源码、不改 CMAKE_ARGS，所以 .cfg-sig 不变，已有编译成果继续复用。
if ! printf '%s\n' "${CMAKE_ARGS[@]}" | grep -q 'WITH_COPC:BOOL=ON'; then
  python3 - "$QGIS_SRC" <<'PY'
import os
import sys

root = sys.argv[1]
cmake = os.path.join(root, 'src/3d/CMakeLists.txt')
renderer = os.path.join(root, 'src/3d/qgspointcloudlayer3drenderer.cpp')

# 1) src/3d/CMakeLists.txt：从源码列表移除 VPC 实体并定义 QGIS_NO_VPC_PROVIDER
src = open(cmake, encoding='utf-8').read()
if 'QGIS_KYLIN_NO_VPC' in src:
    print('3d/CMakeLists.txt 补丁已存在')
else:
    anchor = 'add_library(qgis_3d SHARED'
    if anchor not in src:
        sys.exit('ERROR: 3d/CMakeLists.txt 里找不到 %s' % anchor)
    block = (
        '# QGIS_KYLIN_NO_VPC: 没有 VPC provider（WITH_COPC=OFF）时，3D 里的\n'
        '# qgsvirtualpointcloudentity_p.cpp 无法编译（provider 头文件不在 include 路径里）。\n'
        'if (NOT WITH_COPC)\n'
        '  list(REMOVE_ITEM QGIS_3D_SRCS qgsvirtualpointcloudentity_p.cpp)\n'
        '  list(REMOVE_ITEM QGIS_3D_PRIVATE_HDRS qgsvirtualpointcloudentity_p.h)\n'
        '  add_definitions(-DQGIS_NO_VPC_PROVIDER)\n'
        'endif()\n\n'
    )
    open(cmake, 'w', encoding='utf-8').write(src.replace(anchor, block + anchor, 1))
    print('已给 3d/CMakeLists.txt 打补丁')

# 2) renderer：把 include 和 else-if 分支用 #ifndef QGIS_NO_VPC_PROVIDER 包住
src = open(renderer, encoding='utf-8').read()
inc = '#include "qgsvirtualpointcloudentity_p.h"\n'
inc_new = '#ifndef QGIS_NO_VPC_PROVIDER\n#include "qgsvirtualpointcloudentity_p.h"\n#endif\n'
branch_old = (
    '  else if ( !pcl->dataProvider()->subIndexes().isEmpty() )\n'
    '  {\n'
    '    entity = new QgsVirtualPointCloudEntity( pcl, map, coordinateTransform, dynamic_cast<QgsPointCloud3DSymbol *>( mSymbol->clone() ), maximumScreenError(), showBoundingBoxes(),\n'
    '        static_cast< const QgsPointCloudLayerElevationProperties * >( pcl->elevationProperties() )->zScale(),\n'
    '        static_cast< const QgsPointCloudLayerElevationProperties * >( pcl->elevationProperties() )->zOffset(), mPointBudget );\n'
    '  }\n'
)
branch_new = '#ifndef QGIS_NO_VPC_PROVIDER\n' + branch_old + '#endif\n'
changed = 0
if inc_new in src:
    pass
elif inc in src:
    src = src.replace(inc, inc_new, 1)
    changed += 1
if branch_new in src:
    pass
elif branch_old in src:
    src = src.replace(branch_old, branch_new, 1)
    changed += 1
if changed:
    open(renderer, 'w', encoding='utf-8').write(src)
    print('qgspointcloudlayer3drenderer.cpp 补丁 %d 处' % changed)
else:
    print('qgspointcloudlayer3drenderer.cpp 补丁已存在')
PY
  grep -q 'QGIS_KYLIN_NO_VPC' "$QGIS_SRC/src/3d/CMakeLists.txt" \
    || die "3D VPC 已知缺陷补丁失败（CMakeLists.txt）"
  grep -q 'QGIS_NO_VPC_PROVIDER' "$QGIS_SRC/src/3d/qgspointcloudlayer3drenderer.cpp" \
    || die "3D VPC 已知缺陷补丁失败（renderer）"
  log "3D VPC 已知缺陷补丁完成（WITH_COPC=OFF，裁掉 qgsvirtualpointcloudentity）"
fi

# --- QGIS 3.34 测试缺陷：WITH_SPATIALITE=OFF 时 virtiallayer 测试链接失败 ----
# src/providers/CMakeLists.txt 里 virtual 提供者是 if (WITH_SPATIALITE) 才
# add_subdirectory 的，但 tests/src/providers/CMakeLists.txt 无条件链接
# provider_virtuallayer_a，于是 run 65 在链接测试时报：
#   /usr/bin/ld: 找不到 -lprovider_virtuallayer_a
# 我们本来就不需要测试，但既然 ENABLE_TESTS 默认开、其它测试都已编译，
# 这里只按上游语义把这个用不到的测试一起放进 WITH_SPATIALITE 条件里，
# 避免因为一个死测试把整条流水线卡住。
if ! printf '%s\n' "${CMAKE_ARGS[@]}" | grep -q 'WITH_SPATIALITE:BOOL=ON'; then
  python3 - "$QGIS_SRC" <<'PY'
import os
import sys

path = os.path.join(sys.argv[1], 'tests/src/providers/CMakeLists.txt')
src = open(path, encoding='utf-8').read()
if 'QGIS_KYLIN_NO_SPATIALITE' in src:
    print('tests/src/providers/CMakeLists.txt 补丁已存在')
else:
    needle = ('add_qgis_test(testqgsvirtuallayerprovider.cpp MODULE provider '
              'LINKEDLIBRARIES provider_virtuallayer_a qgis_core)\n')
    if needle not in src:
        sys.exit('ERROR: tests/src/providers/CMakeLists.txt 里找不到 virtuallayer 测试')
    guarded = (
        '# QGIS_KYLIN_NO_SPATIALITE: src/providers/virtual 只在 WITH_SPATIALITE=ON 时\n'
        '# 才加入构建，这里却无条件链接 provider_virtuallayer_a。\n'
        'if (WITH_SPATIALITE)\n'
        '  ' + needle +
        'endif()\n'
    )
    open(path, 'w', encoding='utf-8').write(src.replace(needle, guarded, 1))
    print('已给 tests/src/providers/CMakeLists.txt 打补丁')
PY
  grep -q 'QGIS_KYLIN_NO_SPATIALITE' "$QGIS_SRC/tests/src/providers/CMakeLists.txt" \
    || die "virtuallayer 测试补丁失败"
  log "virtuallayer 测试已随 WITH_SPATIALITE=OFF 一起跳过"
fi

# 配置签名：参数不变就复用已有构建目录，保留增量编译结果。
# QGIS 全量编译即使 -j8 也要 2~3 小时；安装 / rpmbuild 阶段失败时不该从头再编。
_cfg_sig="$(printf '%s\n' "${CMAKE_ARGS[@]}" | sha256sum | awk '{print $1}')"
if [[ -f "${QGIS_BUILD}/CMakeCache.txt" && -f "${QGIS_BUILD}/.cfg-sig" \
      && "$(cat "${QGIS_BUILD}/.cfg-sig" 2>/dev/null)" == "$_cfg_sig" ]]; then
  log "复用构建目录 ${QGIS_BUILD}（cmake 参数签名一致），保留增量编译"
else
  log "全新配置 ${QGIS_BUILD}（首次配置或 cmake 参数发生变化）"
  rm -rf "$QGIS_BUILD"
fi

set -o pipefail
cmake -S "$QGIS_SRC" -B "$QGIS_BUILD" -G Ninja \
  "${CMAKE_ARGS[@]}" \
  2>&1 | tee "${LOG}/qgis-cmake.log"
printf '%s\n' "$_cfg_sig" > "${QGIS_BUILD}/.cfg-sig"

grep -E '^(WITH_3D|WITH_BINDINGS|WITH_DESKTOP|WITH_QGIS_PROCESS|CMAKE_INSTALL_PREFIX|CMAKE_INSTALL_RPATH):' \
  "${QGIS_BUILD}/CMakeCache.txt" | tee "${REPORT_DIR}/cmake-options.txt" || true

# --- 编译 / DESTDIR 安装 ----------------------------------------------------
ninja -C "$QGIS_BUILD" -j"$JOBS" 2>&1 | tee "${LOG}/qgis-build.log"

# QGIS 的 Python 插件资源（resources_rc.py、ui_*.py）由 PLUGIN_INSTALL 里的
# zzz-<plugin>-<n>-depend 目标生成，而这些目标只挂在 staged-plugins 下；
# staged-plugins 又只有 WITH_STAGED_PLUGINS=ON 时才通过 staged-plugins-on-build
# 挂到 ALL（python/CMakeLists.txt）。我们的 CMAKE_ARGS 关掉了 WITH_STAGED_PLUGINS，
# 于是 ninja 全量编译不会生成这些文件，ninja install 直接报：
#   file INSTALL cannot find ".../qgis-build/python/plugins/db_manager/resources_rc.py"
# 这里不改 CMAKE_ARGS（否则 .cfg-sig 变化要重编全量），安装前显式补构建一次。
ninja -C "$QGIS_BUILD" -j"$JOBS" staged-plugins 2>&1 | tee "${LOG}/qgis-staged-plugins.log"

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
       -o -name 'libgsl.so.*' -o -name 'libgslcblas.so.*' \
       -o -name 'libexpat.so.*' \) \
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
# Kylin V10 的 %__os_install_post 中 brp-python-bytecompile 写死调用
# /usr/bin/python（Python 2）去预编译全部 Python 3 代码（QGIS 插件、PyQt5、
# sipbuild、packaging 等），导致全面 SyntaxError 令 rpmbuild 失败。二进制打包
# 阶段无需预编译 .pyc（运行时由 python3 按需编译），直接移除该 brp 调用。
%global __os_install_post %(echo '%{__os_install_post}' | sed -e 's#/usr/lib/rpm/brp-python-bytecompile /usr/bin/python [0-9 ]*##g')
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
