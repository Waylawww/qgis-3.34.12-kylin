#!/usr/bin/env bash
# 阶段 2：在目标银河麒麟 V10 主机上，把 QGIS 3.34.12 缺失/过旧的依赖
# 全部构建到独立前缀 $DEPS_PREFIX（actionsrunner 用户，无 sudo、不写 /usr）。
# 每个依赖独立日志 + stamp 缓存；单项失败不中断，最后统一汇总并失败退出，
# 保证一次运行即可拿到全部真实错误用于下一轮修复。
#
# 2026-11-13 修订（依据真实 run 43358840843 的 dep-*.log）：
#   1. GCC11 的 libstdc++ 加入 LD_LIBRARY_PATH / rpath，修 qmake 的
#      `GLIBCXX_3.4.29 not found`（系统 /usr/lib64 那份来自 gcc-7.3.0）。
#   2. sysroot 中非 PIC 的 libz.a 删除、断链 .so 修好，修 libzip/exiv2
#      链接 .so 时的 R_X86_64_PC32 报错。
#   3. 下载后校验压缩流完整性，解压后校验归档必需文件；
#      GDAL 3.4.3 根本没有 CMakeLists.txt，已换 3.5.3。
#   4. 解压不再假定 `--strip-components=1`，改为自动展开单一顶层目录。
#   5. 所有产物校验同时看 lib/ 与 lib64/。
#   6. QScintilla 2.13.3 的库在 src/（不是 Qt4Qt5/）。
#   7. SIP/PyQt5 走 SIP6 + PyQt-builder + sip-install（SIP4 解析不了
#      PyQt5 5.15.6 的 .sip 语法）；qwt 的 make install 会写 /usr/local，
#      改为直接复制编译产物到私有前缀。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/scripts/deps/versions.env"

JOBS="${QGIS_BUILD_JOBS:-6}"
SRC="${CACHE_DIR}/src"
BUILD="${WORK_DIR}/deps-build"
STAMPS="${DEPS_PREFIX}/.stamps"
SYSROOT="${DEPS_PREFIX}/sysroot"
WHL_DIR="${CACHE_DIR}/wheels"
LOG="${REPORT_DIR}/logs"
STATUS_FILE="${REPORT_DIR}/deps-status.tsv"
PY_SITE="$DEPS_PREFIX/lib/python3.7/site-packages"
mkdir -p "$SRC" "$BUILD" "$STAMPS" "$SYSROOT" "$LOG" "$CACHE_DIR/rpms" "$WHL_DIR" "$PY_SITE"
: > "$STATUS_FILE"
declare -A STATUS
FAILURES=()
GCC_LIBDIR=""

info "== 阶段 2 / BUILD NATIVE DEPENDENCIES =="
log "prefix=$DEPS_PREFIX jobs=$JOBS sysroot=$SYSROOT"
log "缓存命中时跳过；FORCE_REBUILD_DEPS=${FORCE_REBUILD_DEPS:-false}"
if [[ "${FORCE_REBUILD_DEPS:-false}" == "true" ]]; then
  rm -f "$STAMPS"/*.ok
fi

# --- 通用函数 --------------------------------------------------------------
# GCC 11 (/usr/bin/g++ 11.5.0) 编出的程序需要带 GLIBCXX_3.4.29 的
# libstdc++.so.6；系统 gcc-7.3.0 RPM 提供的 /usr/lib64/libstdc++.so.6 没有，
# 动态加载器默认只会找到后者，导致 Qt bootstrap 出的 qmake 直接起不来。
detect_gcc_runtime() {
  local cand search root d
  cand="$(g++ -print-file-name=libstdc++.so.6 2>/dev/null || true)"
  if [[ "$cand" == /* && -e "$cand" ]] \
     && grep -aq 'GLIBCXX_3\.4\.29' "$cand" 2>/dev/null; then
    dirname "$(readlink -f "$cand")"
    return 0
  fi
  search="$(g++ -print-search-dirs 2>/dev/null \
            | sed -n 's/^install: //p' | tr -d ' ' | cut -d: -f1 || true)"
  if [[ -n "$search" ]]; then
    root="$(cd "$(dirname "$search")/../../.." 2>/dev/null && pwd || true)"
    for d in "$root/lib64" "$root/lib"; do
      if [[ -e "$d/libstdc++.so.6" ]] \
         && grep -aq 'GLIBCXX_3\.4\.29' "$d/libstdc++.so.6" 2>/dev/null; then
        echo "$d"; return 0
      fi
    done
  fi
  for d in /usr/local/gcc11/lib64 /usr/local/gcc11/lib /usr/local/lib64 /usr/local/lib; do
    if [[ -e "$d/libstdc++.so.6" ]] \
       && grep -aq 'GLIBCXX_3\.4\.29' "$d/libstdc++.so.6" 2>/dev/null; then
      echo "$d"; return 0
    fi
  done
  return 1
}

# devel RPM 里的静态库多为非 PIC（libz.a 就是），被 CMake 选中去链接
# shared library 时会报 "relocation R_X86_64_PC32 ... recompile with -fPIC"。
# 有同名 .so 时删掉 .a；再把解压后断链的 .so 指向系统真实运行时库。
fixup_sysroot_libs() {
  local libdir="$SYSROOT/usr/lib64" a so target base real fixed=0 deleted=0 h
  shopt -s nullglob
  for a in "$libdir"/lib*.a; do
    so="${a%.a}.so"
    if [[ -e "$so" || -L "$so" ]]; then
      rm -f "$a"
      deleted=$((deleted + 1))
    fi
  done
  for so in "$libdir"/lib*.so; do
    if [[ ! -L "$so" ]]; then continue; fi
    if [[ -e "$so" ]]; then continue; fi
    target="$(readlink "$so")"
    base="$(basename "$target")"
    # 链接目标可能是相对名（libprotobuf.so.25）或绝对路径
    # （/usr/lib64/libgsl.so.25），只取文件名；优先在 sysroot 里找运行时
    # RPM 解压出来的库，再退回系统目录。
    for real in "$libdir/$base" "/usr/lib64/$base" "/lib64/$base"; do
      if [[ -f "$real" ]]; then
        ln -sfn "$real" "$so"
        fixed=$((fixed + 1))
        break
      fi
    done
  done
  shopt -u nullglob
  log "D0: sysroot 删除有动态替代的 .a $deleted 个，修复断链 .so $fixed 个"
}

setup_flags() {
  # $PY_SITE/bin 是 pip --target 生成 sip-* console scripts 的位置；
  # pyqtbuild 的 distinfo 目标会按 PATH 查找 sip-distinfo，必须同时可见。
  export PATH="$DEPS_PREFIX/bin:$PY_SITE/bin:$PATH"
  export PYTHONPATH="$PY_SITE${PYTHONPATH:+:$PYTHONPATH}"
  export LD_LIBRARY_PATH="${GCC_LIBDIR:+${GCC_LIBDIR}:}$DEPS_PREFIX/lib:$DEPS_PREFIX/lib64:${SYSROOT}/usr/lib64:${LD_LIBRARY_PATH:-}"
  export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig:$DEPS_PREFIX/lib64/pkgconfig:${SYSROOT}/usr/lib64/pkgconfig:${SYSROOT}/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CMAKE_PREFIX_PATH="$DEPS_PREFIX;${SYSROOT}/usr"
  export CPPFLAGS="-I$DEPS_PREFIX/include -I${SYSROOT}/usr/include ${CPPFLAGS:-}"
  export LDFLAGS="${GCC_LIBDIR:+-L$GCC_LIBDIR -Wl,-rpath,$GCC_LIBDIR }-L$DEPS_PREFIX/lib -L$DEPS_PREFIX/lib64 -L${SYSROOT}/usr/lib64 -Wl,-rpath,$DEPS_PREFIX/lib -Wl,-rpath,$DEPS_PREFIX/lib64 -Wl,-rpath,${SYSROOT}/usr/lib64 ${LDFLAGS:-}"
  export CMAKE_INSTALL_RPATH="$DEPS_PREFIX/lib;$DEPS_PREFIX/lib64;${GCC_LIBDIR};${SYSROOT}/usr/lib64"
}

# 只靠 ">100000 bytes" 判断下载成功是不够的：连接提前关闭会留下半个归档，
# 解压出来没有 CMakeLists.txt。用压缩流自检，并留 .ok 标记避免每轮重检。
validate_archive() {
  local f="$1" ok=0
  if [[ ! -s "$f" ]]; then return 1; fi
  if [[ -f "$f.ok" && "$f.ok" -nt "$f" ]]; then return 0; fi
  case "$f" in
    *.tar.gz|*.tgz|*.gz)      gzip -t "$f" >/dev/null 2>&1 && ok=1 ;;
    *.tar.xz|*.txz|*.xz)      xz -t "$f" >/dev/null 2>&1 && ok=1 ;;
    *.tar.bz2|*.tbz2|*.bz2)   bzip2 -t "$f" >/dev/null 2>&1 && ok=1 ;;
    # Python wheel 是 zip，tar -tf 必然失败；用标准库 CRC 自检（兼容 3.7）。
    *.whl)                    python3 -c 'import sys, zipfile; sys.exit(0 if zipfile.ZipFile(sys.argv[1]).testzip() is None else 1)' "$f" >/dev/null 2>&1 && ok=1 ;;
    *)                        tar -tf "$f" >/dev/null 2>&1 && ok=1 ;;
  esac
  if (( ! ok )); then return 1; fi
  touch "$f.ok"
  return 0
}

fetch() {
  local dest="$1"; shift
  if [[ -s "$dest" ]]; then
    if validate_archive "$dest"; then
      log "  已缓存 $(basename "$dest")（归档自检通过）"
      return 0
    fi
    warn "  缓存归档损坏，删除: $dest"
    rm -f "$dest" "$dest.ok"
  fi
  local url
  for url in "$@"; do
    log "  下载 $url"
    if curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 20 \
         --speed-limit 10240 --speed-time 180 --max-time 3600 "$url" \
         -o "${dest}.part" \
       && [[ -s "${dest}.part" ]] \
       && [[ $(stat -c %s "${dest}.part") -gt 10000 ]]; then
      mv -f "${dest}.part" "$dest"
      if ! validate_archive "$dest"; then
        warn "  归档不完整，丢弃并尝试下一个源: $url"
        rm -f "$dest" "$dest.ok"
        continue
      fi
      sha256sum "$dest" >> "$REPORT_DIR/deps-sources.sha256" 2>/dev/null || true
      return 0
    fi
    warn "  下载失败: $url"
    rm -f "${dest}.part"
  done
  return 1
}

# 不再用 --strip-components=1：它对带 ./ 前缀的归档会剥错，对没有顶层
# 目录的归档会把文件全部丢掉。改为原样解压，然后只展开单一顶层目录。
unpack() {
  local tarball="$1" dir="$2"
  if [[ -f "$dir/.unpack-ok" ]]; then
    log "  已解压 $dir"
    return 0
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  if ! tar -xf "$tarball" -C "$dir"; then
    warn "  解压失败: $tarball"
    return 1
  fi
  shopt -s dotglob nullglob
  local entries=("$dir"/*) inner hidden h
  shopt -u dotglob nullglob
  if (( ${#entries[@]} == 1 )) && [[ -d "${entries[0]}" ]]; then
    inner="${entries[0]}"
    mv "$inner"/* "$dir"/ 2>/dev/null || true
    shopt -s dotglob nullglob
    hidden=("$inner"/.[!.]*)
    shopt -u dotglob nullglob
    for h in "${hidden[@]}"; do
      if [[ -e "$h" ]]; then mv "$h" "$dir"/ 2>/dev/null || true; fi
    done
    rmdir "$inner" 2>/dev/null || true
  fi
  touch "$dir/.unpack-ok"
  log "  解压完成 $dir 顶层: $(ls -A "$dir" | head -n 10 | tr '\n' ' ')"
}

# fetch_source NAME TARBALL DIR REQUIRED_FILE...
# 逐个尝试上游地址：下载 -> 归档自检 -> 解压 -> 内容门禁。
# GDAL 3.4.3 这类"能下载、能解压、但根本没有 CMakeLists.txt"的包
# 会在这里被拒绝并自动换下一个源，而不是拖到 cmake 才失败。
fetch_source() {
  local key="$1" tarball="$2" dir="$3"; shift 3
  local dest="$SRC/$tarball" url f missing
  eval "local urls=(\"\${${key}_URLS[@]}\")"
  for url in "${urls[@]}"; do
    if ! fetch "$dest" "$url"; then continue; fi
    if ! unpack "$dest" "$dir"; then
      rm -f "$dest" "$dest.ok" "$dir/.unpack-ok"
      continue
    fi
    missing=0
    for f in "$@"; do
      if [[ ! -e "$dir/$f" ]]; then
        warn "  归档内容不符（缺 $f）: $url"
        missing=1
      fi
    done
    if (( missing )); then
      rm -f "$dest" "$dest.ok" "$dir/.unpack-ok"
      continue
    fi
    return 0
  done
  return 1
}

cmake_install() {
  local name="$1" srcdir="$2"; shift 2
  local b="$BUILD/$name"
  rm -rf "$b"; mkdir -p "$b"
  cmake -S "$srcdir" -B "$b" -G Ninja \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_INSTALL_PREFIX:PATH="$DEPS_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR:STRING=lib \
    -DCMAKE_PREFIX_PATH:PATH="$DEPS_PREFIX;${SYSROOT}/usr" \
    -DCMAKE_INSTALL_RPATH:STRING="$DEPS_PREFIX/lib;$DEPS_PREFIX/lib64;${GCC_LIBDIR};${SYSROOT}/usr/lib64" \
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH:BOOL=ON \
    -DBUILD_TESTING:BOOL=OFF -DBUILD_SHARED_LIBS:BOOL=ON "$@" || return 1
  ninja -C "$b" -j"$JOBS" || return 1
  ninja -C "$b" install || return 1
}

installed_lib() {
  local n="$1" d
  for d in "$DEPS_PREFIX/lib" "$DEPS_PREFIX/lib64"; do
    if [[ -e "$d/$n" || -L "$d/$n" ]]; then return 0; fi
  done
  return 1
}

qmake_ready() {
  if [[ -x "$DEPS_PREFIX/bin/qmake" ]]; then return 0; fi
  warn "Qt 未就绪：缺 $DEPS_PREFIX/bin/qmake（本依赖在 Qt 之后构建）"
  return 1
}

run_dep() {
  local name="$1" fn="$2"
  if [[ -f "$STAMPS/$name.ok" ]]; then
    STATUS[$name]=CACHED; printf '%s\tCACHED\n' "$name" >> "$STATUS_FILE"
    log "[$name] CACHED"; return 0
  fi
  info "---------- 构建依赖: $name ----------"
  # 子 shell 执行：依赖函数内部的 cd 不会污染后续依赖的工作目录
  if ( "$fn" ) > "$LOG/dep-$name.log" 2>&1; then
    touch "$STAMPS/$name.ok"
    STATUS[$name]=OK; printf '%s\tOK\n' "$name" >> "$STATUS_FILE"
    log "[$name] OK"
  else
    STATUS[$name]=FAIL; FAILURES+=("$name")
    printf '%s\tFAIL\n' "$name" >> "$STATUS_FILE"
    warn "[$name] FAIL —— 日志尾部:"
    tail -n 25 "$LOG/dep-$name.log" >&2 || true
  fi
}

# --- D0: 系统 DEVEL RPM 只下载解压到 sysroot --------------------------------
info "== D0 / 准备系统 devel 头文件（不安装、不 sudo）=="
PM="$(command -v dnf || command -v yum || true)"
dnf_ok=0
if [[ -n "$PM" ]]; then
  for pkg in "${SYSROOT_DEVEL_RPMS[@]}"; do
    if (cd "$CACHE_DIR/rpms" && "$PM" -q download --destdir . \
        --setopt=cachedir="$CACHE_DIR/dnf" "$pkg") >> "$LOG/dep-sysroot.log" 2>&1; then
      dnf_ok=$((dnf_ok + 1))
    else
      echo "FAIL dnf download $pkg" >> "$LOG/dep-sysroot.log"
    fi
    # devel 的 libXXX.so 只是指向运行时库 libXXX.so.N 的链接；麒麟主机
    # 常没装运行时包，链接就断了，CMake 的 find_library 会失败
    # （Protobuf / GSL 均实测）。自动把同名运行时包也拉进 sysroot，
    # 下载失败只记录、不阻断（很多运行时包本来就在系统里）。
    if [[ "$pkg" == *-devel ]]; then
      rt="${pkg%-devel}"
      (cd "$CACHE_DIR/rpms" && "$PM" -q download --destdir . \
          --setopt=cachedir="$CACHE_DIR/dnf" "$rt") >> "$LOG/dep-sysroot.log" 2>&1 \
        || echo "FAIL dnf download $rt (runtime, optional)" >> "$LOG/dep-sysroot.log"
    fi
  done
fi
sysroot_rpms=0
shopt -s nullglob
for rpmfile in "$CACHE_DIR/rpms"/*.rpm; do
  (cd "$SYSROOT" && rpm2cpio "$rpmfile" | cpio -idm --quiet) >> "$LOG/dep-sysroot.log" 2>&1 \
    && sysroot_rpms=$((sysroot_rpms + 1)) || true
done
shopt -u nullglob
log "D0: dnf download 成功 $dnf_ok 个包，解压 $sysroot_rpms 个 RPM"
log "D0: sysroot 头文件 $(find "$SYSROOT/usr/include" -type f 2>/dev/null | wc -l) 个"
log "D0: 详见 $LOG/dep-sysroot.log"
fixup_sysroot_libs
GCC_LIBDIR="$(detect_gcc_runtime || true)"
if [[ -n "$GCC_LIBDIR" ]]; then
  log "D0: GCC11 运行时库目录 $GCC_LIBDIR（含 GLIBCXX_3.4.29）"
else
  warn "D0: 未定位到 GCC11 libstdc++；Qt qmake 可能仍报 GLIBCXX_3.4.29 not found"
fi
printf '%s\n' "${GCC_LIBDIR:-NOT_FOUND}" > "$REPORT_DIR/gcc-runtime.txt"
setup_flags

# --- SIP 版本门禁 -----------------------------------------------------------
# run_dep 只看 $STAMPS/sip.ok 就会 CACHED 跳过。SIP4 -> SIP6 的切换、
# 以及 sip 6.7.12 -> 6.7.5 的降级（Gentoo bug 904834 的 Q_PID 回归）
# 都必须让 dep_sip 真正重跑，所以按"能否 import 且版本等于 $SIP_VERSION"
# 判断真实状态，而不是只看 stamp 或只看 import 是否成功。
if [[ -f "$STAMPS/sip.ok" ]] && \
   ! SIP_EXPECTED="$SIP_VERSION" python3 -c \
     'import os, sipbuild, pyqtbuild; from sipbuild.version import SIP_VERSION_STR; assert SIP_VERSION_STR == os.environ["SIP_EXPECTED"]' >/dev/null 2>&1; then
  log "D0: SIP 版本不是 $SIP_VERSION，清理 stamp 与旧产物后重建"
  rm -f "$STAMPS/sip.ok" "$STAMPS/pyqt5.ok"
  rm -f "$DEPS_PREFIX/bin/sip" "$DEPS_PREFIX/bin/sip-build" \
        "$DEPS_PREFIX/include/sip.h" \
        "$PY_SITE/sip.so" "$PY_SITE/sipconfig.py" \
        "$PY_SITE/sipdistutils.py" "$PY_SITE/sip.pyi"
  rm -rf "$PY_SITE"/sip-*.dist-info "$PY_SITE/sipbuild" "$PY_SITE/pyqtbuild" \
         "$PY_SITE/PyQt5" "$DEPS_PREFIX/share/sip/PyQt5" "$SRC/pyqt5"
fi

# --- D1..Dn: 各依赖 -------------------------------------------------------
dep_geos() {
  fetch_source GEOS "$GEOS_TARBALL" "$SRC/geos" CMakeLists.txt || return 1
  cmake_install geos "$SRC/geos" -DBUILD_GEOSOP:BOOL=OFF || return 1
  installed_lib libgeos_c.so || [[ -x "$DEPS_PREFIX/bin/geos-config" ]]
}
dep_proj() {
  fetch_source PROJ "$PROJ_TARBALL" "$SRC/proj" CMakeLists.txt || return 1
  cmake_install proj "$SRC/proj" \
    -DENABLE_TIFF:BOOL=OFF -DENABLE_CURL:BOOL=OFF \
    -DBUILD_PROJINFO:BOOL=ON -DBUILD_CCT:BOOL=ON -DBUILD_CS2CS:BOOL=ON \
    -DBUILD_PROJSYNC:BOOL=OFF || return 1
  [[ -f "$DEPS_PREFIX/include/proj.h" ]] && installed_lib libproj.so
}
dep_gdal() {
  fetch_source GDAL "$GDAL_TARBALL" "$SRC/gdal" CMakeLists.txt || return 1
  cmake_install gdal "$SRC/gdal" \
    -DBUILD_PYTHON_BINDINGS:BOOL=OFF -DBUILD_JAVA_BINDINGS:BOOL=OFF \
    -DBUILD_CSHARP_BINDINGS:BOOL=OFF \
    -DGDAL_BUILD_OPTIONAL_DRIVERS:BOOL=OFF \
    -DOGR_BUILD_OPTIONAL_DRIVERS:BOOL=OFF \
    -DGDAL_USE_CURL:BOOL=OFF -DGDAL_USE_POSTGRESQL:BOOL=OFF \
    -DGDAL_USE_ZSTD:BOOL=OFF -DGDAL_USE_GEOTIFF:BOOL=OFF \
    -DPROJ_ROOT:PATH="$DEPS_PREFIX" || return 1
  [[ -x "$DEPS_PREFIX/bin/gdalinfo" ]] || installed_lib libgdal.so
}
dep_spatialindex() {
  fetch_source SPATIALINDEX "spatialindex-src-${SPATIALINDEX_VERSION}.tar.gz" \
    "$SRC/spatialindex" CMakeLists.txt || return 1
  cmake_install spatialindex "$SRC/spatialindex" || return 1
  [[ -f "$DEPS_PREFIX/include/spatialindex/SpatialIndex.h" ]] || \
    installed_lib libspatialindex_c.so
}
dep_libzip() {
  fetch_source LIBZIP "libzip-${LIBZIP_VERSION}.tar.gz" \
    "$SRC/libzip" CMakeLists.txt || return 1
  cmake_install libzip "$SRC/libzip" -DENABLE_GNUTLS:BOOL=OFF \
    -DENABLE_OPENSSL:BOOL=OFF -DBUILD_DOC:BOOL=OFF -DBUILD_EXAMPLES:BOOL=OFF || return 1
  [[ -f "$DEPS_PREFIX/include/zip.h" ]] && installed_lib libzip.so
}
dep_exiv2() {
  fetch_source EXIV2 "exiv2-${EXIV2_VERSION}.tar.gz" \
    "$SRC/exiv2" CMakeLists.txt || return 1
  cmake_install exiv2 "$SRC/exiv2" \
    -DEXIV2_ENABLE_VIDEO:BOOL=OFF -DEXIV2_ENABLE_WEBREADY:BOOL=OFF \
    -DEXIV2_BUILD_SAMPLES:BOOL=OFF -DEXIV2_BUILD_EXIV2_COMMAND:BOOL=OFF || return 1
  [[ -f "$DEPS_PREFIX/include/exiv2/exiv2.hpp" ]] || installed_lib libexiv2.so
}

dep_qt() {
  fetch_source QT "$QT_TARBALL" "$SRC/qt" configure || return 1
  # Qt 5.15.2 在 GCC 11 下需要 <limits>（std::numeric_limits）。
  # 但 Qt 自带 zlib 的 .c 文件也会包含 qglobal.h，无条件插入会让 C 编译器
  # 报 "limits: No such file or directory"（本轮真实失败点 adler32.c）。
  # 只在 C++ 编译单元引入，并清理上一轮遗留的无条件插入。
  local qglobal="$SRC/qt/qtbase/src/corelib/global/qglobal.h"
  if [[ -f "$qglobal" ]]; then
    if [[ "$(sed -n '1p' "$qglobal")" == '#include <limits>' ]]; then
      tail -n +2 "$qglobal" > "$qglobal.tmp" && mv -f "$qglobal.tmp" "$qglobal"
    fi
    if ! grep -qF 'qgis-kylin-gcc11-limits' "$qglobal"; then
      {
        printf '%s\n' '/* qgis-kylin-gcc11-limits */' \
          '#if defined(__cplusplus)' '#include <limits>' '#endif'
        cat "$qglobal"
      } > "$qglobal.tmp"
      mv -f "$qglobal.tmp" "$qglobal"
    fi
  fi
  local b="$BUILD/qt"
  rm -rf "$b"; mkdir -p "$b"; cd "$b"
  # Qt 5.15.2 configure.json 实测：xcb 是 boolean（只有 -xcb / -no-xcb），
  # 不存在 -qt-xcb（上一轮报 "Invalid value given for boolean command line
  # option 'xcb'"）。-no-gtk / -no-glib / -no-cups / -no-pulseaudio / -no-alsa
  # 也不在 5.15.2 的合法选项表里，缺库的模块 configure 会自动禁用。
  # 保留经 configure.json 确认合法的 enum(-qt-*/system-*) 与 boolean 开关。
  if ! "$SRC/qt/configure" -opensource -confirm-license -release -shared \
    -prefix "$DEPS_PREFIX" \
    -nomake examples -nomake tests \
    -skip qtwebengine -skip qtdoc -skip qtwayland -skip qtconnectivity \
    -skip qtsensors -skip qtserialport -skip qtgamepad \
    -skip qtandroidextras -skip qtmacextras -skip qtwinextras \
    -skip qtpurchasing -skip qtcharts -skip qtdatavis3d \
    -skip qtnetworkauth -skip qtremoteobjects -skip qtscxml \
    -skip qtspeech -skip qtvirtualkeyboard \
    -qt-pcre -qt-doubleconversion -qt-harfbuzz \
    -qt-libpng -qt-libjpeg -qt-zlib \
    -system-freetype -fontconfig -openssl -no-icu \
    -no-eglfs -no-directfb -no-linuxfb -no-kms \
    -no-compile-examples; then
    warn "  Qt configure 失败，config.log 尾部:"
    tail -n 80 "$b/config.log" 2>/dev/null || true
    return 1
  fi
  make -j"$JOBS" || return 1
  make install || return 1
  [[ -x "$DEPS_PREFIX/bin/qmake" ]] && [[ -d "$DEPS_PREFIX/lib/cmake/Qt53DCore" ]]
}

dep_qwt() {
  fetch_source QWT "qwt-${QWT_VERSION}.tar.bz2" "$SRC/qwt" qwt.pro qwtconfig.pri || return 1
  qmake_ready || return 1
  cd "$SRC/qwt"
  "$DEPS_PREFIX/bin/qmake" qwt.pro -r CONFIG+=release || return 1
  make -j"$JOBS" || return 1
  # 实测 dep-qwt.log：qwtconfig.pri 的前缀行带空格且被注释，旧的
  # sed 's|^#\?QWT_INSTALL_PREFIX.*|...|' 没匹配上，qmake 仍用默认
  # /usr/local/qwt-$$QWT_VERSION，make install 报 "mkdir: 权限不够"。
  # QGIS cmake/FindQwt.cmake 只用 find_library(libqwt*) + find_path(qwt.h)，
  # 因此直接把编译产物复制到私有前缀，完全不调用 make install。
  mkdir -p "$DEPS_PREFIX/include/qwt" "$DEPS_PREFIX/lib"
  cp -f src/*.h "$DEPS_PREFIX/include/qwt/" || return 1
  cp -a lib/libqwt.so* "$DEPS_PREFIX/lib/" || return 1
  [[ -f "$DEPS_PREFIX/include/qwt/qwt.h" ]] && installed_lib libqwt.so
}

dep_qscintilla() {
  # 2.13.3 实测：顶层无 Qt4Qt5/，库工程是 src/qscintilla.pro
  fetch_source QSCINTILLA "QScintilla_src-${QSCINTILLA_VERSION}.tar.gz" \
    "$SRC/qscintilla" src/qscintilla.pro src/Qsci/qsciscintilla.h || return 1
  qmake_ready || return 1
  cd "$SRC/qscintilla/src"
  "$DEPS_PREFIX/bin/qmake" qscintilla.pro CONFIG+=release || return 1
  make -j"$JOBS" || return 1
  mkdir -p "$DEPS_PREFIX/include/Qsci" "$DEPS_PREFIX/lib" "$DEPS_PREFIX/share/sip/Qsci"
  cp -f Qsci/*.h "$DEPS_PREFIX/include/Qsci/" || return 1
  local so count=0
  while IFS= read -r -d '' so; do
    cp -a "$so" "$DEPS_PREFIX/lib/" || return 1
    count=$((count + 1))
  done < <(find "$SRC/qscintilla" -name 'libqscintilla2_qt5.so*' -print0)
  log "  QScintilla 复制共享库 $count 个"
  (( count > 0 )) || return 1
  # QGIS python bindings 需要 Qsci 的 .sip 文件
  cp -f "$SRC/qscintilla/Python/sip/"*.sip "$DEPS_PREFIX/share/sip/Qsci/" 2>/dev/null || true
  [[ -f "$DEPS_PREFIX/include/Qsci/qsciscintilla.h" ]]
}

dep_qca() {
  fetch_source QCA "qca-${QCA_VERSION}.tar.gz" "$SRC/qca" CMakeLists.txt || return 1
  qmake_ready || return 1
  cmake_install qca "$SRC/qca" \
    -DQt5_DIR:PATH="$DEPS_PREFIX/lib/cmake/Qt5" \
    -DQT4_BUILD:BOOL=OFF -DBUILD_TESTS:BOOL=OFF -DBUILD_TOOLS:BOOL=OFF \
    -DBUILD_PLUGINS:STRING=auto || return 1
  [[ -f "$DEPS_PREFIX/include/QtCrypto/QtCrypto" ]] || installed_lib libqca-qt5.so
}

dep_qtkeychain() {
  fetch_source QTKEYCHAIN "qtkeychain-${QTKEYCHAIN_VERSION}.tar.gz" \
    "$SRC/qtkeychain" CMakeLists.txt || return 1
  qmake_ready || return 1
  cmake_install qtkeychain "$SRC/qtkeychain" \
    -DQt5_DIR:PATH="$DEPS_PREFIX/lib/cmake/Qt5" \
    -DBUILD_WITH_QT6:BOOL=OFF -DBUILD_TESTING:BOOL=OFF \
    -DLIBSECRET_SUPPORT:BOOL=OFF -DBUILD_TRANSLATIONS:BOOL=OFF || return 1
  [[ -f "$DEPS_PREFIX/include/qt5keychain/keychain.h" ]] || \
    installed_lib libqt5keychain.so
}

dep_sip() {
  mkdir -p "$WHL_DIR" "$PY_SITE" "$DEPS_PREFIX/bin"
  fetch "$WHL_DIR/$SIP_WHEEL" "${SIP_URLS[@]}" || return 1
  fetch "$WHL_DIR/$PYQT_BUILDER_WHEEL" "${PYQT_BUILDER_URLS[@]}" || return 1
  # sip 6.7.5 / PyQt-builder 1.14.0 的 Requires-Dist（packaging / ply /
  # toml / setuptools）必须一并装进私有 PY_SITE：麒麟自带 packaging 没有
  # packaging/markers.py，第四轮就是这里让 `import sipbuild` 失败的。
  fetch "$WHL_DIR/$PACKAGING_WHEEL" "${PACKAGING_URLS[@]}" || return 1
  fetch "$WHL_DIR/$PLY_WHEEL" "${PLY_URLS[@]}" || return 1
  fetch "$WHL_DIR/$TOML_WHEEL" "${TOML_URLS[@]}" || return 1
  fetch "$WHL_DIR/$SETUPTOOLS_WHEEL" "${SETUPTOOLS_URLS[@]}" || return 1
  # pip --target 把 sipbuild / pyqtbuild 与 dist-info 装进私有 PY_SITE，
  # 不写 /usr、不需要 sudo。刻意不走 PEP517：sipbuild/api.py 没有
  # prepare_metadata_for_build_wheel，pip 20.2.2 会直接报错。
  python3 -m pip install --no-cache-dir --no-deps --upgrade --target "$PY_SITE" \
    "$WHL_DIR/$SIP_WHEEL" "$WHL_DIR/$PYQT_BUILDER_WHEEL" \
    "$WHL_DIR/$PACKAGING_WHEEL" "$WHL_DIR/$PLY_WHEEL" \
    "$WHL_DIR/$TOML_WHEEL" "$WHL_DIR/$SETUPTOOLS_WHEEL" || return 1
  # QGIS cmake/FindSIP.cmake 的 SIP>=5 分支 FIND_PROGRAM(sip-build)，
  # cmake/SIPMacros.cmake 也直接调 sip-build，必须在 $DEPS_PREFIX/bin 里。
  # 更关键的是 pyqtbuild.builder.QmakeBuilder：make install 的 distinfo
  # 目标会调用 sip-distinfo，且它按 "当前 sip-* 前端所在目录" 定位该命令。
  # 第六轮只生成了 sip-build / sip-install，$DEPS_PREFIX/bin 里没有
  # sip-distinfo -> make install 返回 2（日志被 sipbuild 吞掉，只留一行）。
  # 因此在这里把全套 sip-* 前端都生成到同一目录。
  python3 - "$DEPS_PREFIX/bin" <<'PY'
import os
import sys

out = sys.argv[1]
tools = {
    'sip-build': 'sipbuild.tools.build',
    'sip-install': 'sipbuild.tools.install',
    'sip-distinfo': 'sipbuild.distinfo.main',
    'sip-module': 'sipbuild.module.main',
    'sip-sdist': 'sipbuild.tools.sdist',
    'sip-wheel': 'sipbuild.tools.wheel',
}
for name, mod in tools.items():
    path = os.path.join(out, name)
    with open(path, 'w', encoding='utf-8') as f:
        f.write('#!/usr/bin/env bash\n')
        f.write("exec python3 -c 'import sys; from %s import main; sys.exit(main())' \"$@\"\n" % mod)
    os.chmod(path, 0o755)
    print('wrapper', name)
PY
  # 必须严格短路：run_dep 在 if 子 shell 里调用，set -e 不会中止函数体，
  # 上一轮这里 import 失败却仍返回 0，把不可用的 SIP 记成了 OK。
  PYTHONPATH="$PY_SITE${PYTHONPATH:+:$PYTHONPATH}" SIP_EXPECTED="$SIP_VERSION" python3 -c \
    'import os, sipbuild, pyqtbuild, packaging, ply, toml, setuptools; from sipbuild.version import SIP_VERSION_STR; assert SIP_VERSION_STR == os.environ["SIP_EXPECTED"], SIP_VERSION_STR; print("SIP", SIP_VERSION_STR)' || return 1
  [[ -x "$DEPS_PREFIX/bin/sip-build" ]] || return 1
}

# PyQt5 5.15.6 sdist 只生成 bindings，不提供 PyQt5.sip 扩展模块
# （Requires-Dist: PyQt5-sip>=12.8,<13；PyQt-builder 1.14.0 设 abi=12.11）。
install_pyqt5_sip() {
  local whl="$WHL_DIR/$PYQT5_SIP_WHEEL"
  fetch "$whl" "${PYQT5_SIP_URLS[@]}" || return 1
  python3 - "$whl" "$PY_SITE" <<'PY' || return 1
import sys
import zipfile

whl, dest = sys.argv[1], sys.argv[2]
found = []
with zipfile.ZipFile(whl) as z:
    for name in z.namelist():
        if name.startswith('PyQt5/') and name.endswith('.so'):
            z.extract(name, dest)
            found.append(name)
print('PyQt5.sip:', ', '.join(found))
sys.exit(0 if found else 1)
PY
}

pyqt5_ready() {
  local m so
  for m in QtCore QtGui QtWidgets QtNetwork QtXml QtSql QtSvg QtPrintSupport QtTest; do
    so="$(find "$PY_SITE/PyQt5" -maxdepth 1 -name "${m}*.so" -print -quit)"
    [[ -n "$so" ]] || return 1
  done
  [[ -f "$PY_SITE/PyQt5/bindings/QtCore/QtCoremod.sip" ]] || return 1
  ls "$PY_SITE"/PyQt5-*.dist-info/METADATA >/dev/null 2>&1 || return 1
  PYTHONPATH="$PY_SITE${PYTHONPATH:+:$PYTHONPATH}" python3 -c \
    'from PyQt5 import QtCore; print("PyQt5", QtCore.PYQT_VERSION_STR)'
}

dep_pyqt5() {
  fetch_source PYQT5 "PyQt5-${PYQT5_VERSION}.tar.gz" "$SRC/pyqt5" \
    pyproject.toml project.py sip/QtCore/QtCoremod.sip || return 1
  qmake_ready || return 1
  if ! PYTHONPATH="$PY_SITE${PYTHONPATH:+:$PYTHONPATH}" python3 -c \
       'import sipbuild, pyqtbuild; from sipbuild.version import SIP_VERSION_STR' >/dev/null 2>&1; then
    warn "  SIP6/PyQt-builder 未就绪（dep_sip 必须先成功）"
    return 1
  fi
  mkdir -p "$PY_SITE/PyQt5" "$DEPS_PREFIX/bin" "$BUILD/pyqt5"
  # 先补齐 PyQt5.sip。若上一轮 sip-install 已把 35 个绑定装好，就不必再
  # 花约 40 分钟重新生成/编译一遍（缓存目录在 runner 上是持久化的）。
  install_pyqt5_sip || return 1
  if pyqt5_ready; then
    log "  PyQt5 产物已完整（含 PyQt5.sip），跳过重复编译"
    return 0
  fi
  cd "$SRC/pyqt5"
  # PyQt5 的复合模块 Qt 会 %Include 所有子模块 .sip，但 project.py 只给
  # QtCore 追加了 WS_X11 平台 tag。生成器在 Qt 模块里解析 qprocess.sip 的
  # %If (WS_X11 || WS_MACX) 时报 "'Q_PID' is undefined"（Gentoo bug 904834，
  # sip 6.7.7+ 尤其容易触发）。给所有 bindings 补上平台 tag，幂等且符合
  # Linux/X11 语义；上游结构变化时只告警、不阻断构建。
  python3 - "$SRC/pyqt5/project.py" <<'PY'
import sys
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    src = f.read()
needle = "        self.bindings['QtCore'].tags.append(plattag)\n"
marker = 'QGIS_KYLIN_PLATFORM_TAG'
if marker in src:
    print('平台 tag 补丁已存在')
elif needle not in src:
    print('WARN: project.py 注入点变化，跳过平台 tag 补丁')
else:
    extra = (
        "        # QGIS_KYLIN_PLATFORM_TAG: Qt 复合模块同样 %Include 了带\n"
        "        # WS_X11 条件的 .sip，需要平台 tag 才能定义 Q_PID 等类型。\n"
        "        for _b in self.bindings.values():\n"
        "            if plattag not in _b.tags:\n"
        "                _b.tags.append(plattag)\n")
    with open(path, 'w', encoding='utf-8') as f:
        f.write(src.replace(needle, needle + extra, 1))
    print('已给所有 bindings 注入平台 tag')
PY
  # PyQt5 5.15.6 的 .sip 是 SIP5/6 语法，configure.py 的 SIP4 分支会在
  # "Generating the C++ source for the QtCore module..." 静默中止。
  # 走 sdist 自带的 pyproject.toml（build-backend=sipbuild.api）对应的 CLI：
  #   --target-dir / --scripts-dir / --build-dir 来自 sipbuild/project.py
  #   --qmake / --jobs                          来自 pyqtbuild/builder.py
  #   --confirm-license / --qt-shared / --no-* 来自 sdist 的 project.py
  # 安装后 $PY_SITE 里会有 PyQt5/*.so、PyQt5/bindings/*.sip、
  # PyQt5-5.15.6.dist-info/METADATA —— 正是 QGIS FindPyQt5.cmake 需要的布局。
  PYTHONPATH="$PY_SITE${PYTHONPATH:+:$PYTHONPATH}" \
    "$DEPS_PREFIX/bin/sip-install" \
      --confirm-license --qt-shared \
      --qmake="$DEPS_PREFIX/bin/qmake" \
      --target-dir="$PY_SITE" \
      --scripts-dir="$DEPS_PREFIX/bin" \
      --build-dir="$BUILD/pyqt5" \
      --jobs="$JOBS" \
      --no-designer-plugin --no-qml-plugin \
      --no-dbus-python --no-tools || return 1
  # QGIS cmake/FindPyQt5.cmake 的 SIP>=5 分支 FIND_PROGRAM(pyuic5)；
  # --no-tools 不生成它，补上 uic 包与 wrapper 保证探测不落空。
  if [[ ! -d "$PY_SITE/PyQt5/uic" && -d "$SRC/pyqt5/pyuic/uic" ]]; then
    cp -a "$SRC/pyqt5/pyuic/uic" "$PY_SITE/PyQt5/" || return 1
  fi
  if [[ ! -x "$DEPS_PREFIX/bin/pyuic5" ]]; then
    cat > "$DEPS_PREFIX/bin/pyuic5" <<'EOF'
#!/usr/bin/env python3
from PyQt5.uic.pyuic import main
main()
EOF
    chmod 755 "$DEPS_PREFIX/bin/pyuic5"
  fi
  install_pyqt5_sip && pyqt5_ready
}

for pair in "geos:dep_geos" "proj:dep_proj" "spatialindex:dep_spatialindex" \
            "libzip:dep_libzip" "exiv2:dep_exiv2" "gdal:dep_gdal" \
            "qt:dep_qt" "qwt:dep_qwt" "qscintilla:dep_qscintilla" \
            "qca:dep_qca" "qtkeychain:dep_qtkeychain" \
            "sip:dep_sip" "pyqt5:dep_pyqt5"; do
  run_dep "${pair%%:*}" "${pair##*:}"
done

# --- 汇总 ------------------------------------------------------------------
python3 - "$REPORT_DIR" "$DEPS_PREFIX" "$STATUS_FILE" \
  "${GCC_LIBDIR:-NOT_FOUND}" "$PY_SITE" \
  "${FAILURES[@]+"${FAILURES[@]}"}" <<'PY'
import datetime, json, os, sys
rep, prefix, status_file, gcc_lib, py_site = sys.argv[1:6]
fails = sys.argv[6:]
status = {}
for line in open(status_file, encoding='utf-8'):
    parts = line.strip().split('\t')
    if len(parts) == 2:
        status[parts[0]] = parts[1]
data = {
    'generated_at': datetime.datetime.utcnow().isoformat() + 'Z',
    'deps_prefix': prefix,
    'gcc_runtime_libdir': gcc_lib,
    'python_site': py_site,
    'status': status,
    'failures': fails,
    'verdict': 'PASS' if not fails else 'FAIL',
}
with open(os.path.join(rep, 'deps-manifest.json'), 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print(json.dumps(data, ensure_ascii=False, indent=2))
PY

if (( ${#FAILURES[@]} > 0 )); then
  die "依赖构建失败: ${FAILURES[*]}（完整日志见 dep-*.log）"
fi
info "BUILD DEPS PASS —— 全部依赖已安装到 $DEPS_PREFIX"
