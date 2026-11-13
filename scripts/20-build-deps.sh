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
#   7. SIP/PyQt5 改走 SIP4 + configure.py 传统路线（PyQt5 PyPI sdist）。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/scripts/deps/versions.env"

JOBS="${QGIS_BUILD_JOBS:-6}"
SRC="${CACHE_DIR}/src"
BUILD="${WORK_DIR}/deps-build"
STAMPS="${DEPS_PREFIX}/.stamps"
SYSROOT="${DEPS_PREFIX}/sysroot"
LOG="${REPORT_DIR}/logs"
STATUS_FILE="${REPORT_DIR}/deps-status.tsv"
PY_SITE="$DEPS_PREFIX/lib/python3.7/site-packages"
mkdir -p "$SRC" "$BUILD" "$STAMPS" "$SYSROOT" "$LOG" "$CACHE_DIR/rpms" "$PY_SITE"
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
  local libdir="$SYSROOT/usr/lib64" a so target real fixed=0 deleted=0 h
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
    if [[ "$target" == /* ]]; then continue; fi
    for real in "/usr/lib64/$(basename "$target")" "/lib64/$(basename "$target")"; do
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
  export PATH="$DEPS_PREFIX/bin:$PATH"
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
  # Qt 5.15.2 在 GCC 11 下需要 <limits>（std::numeric_limits）
  local qglobal="$SRC/qt/qtbase/src/corelib/global/qglobal.h"
  if [[ -f "$qglobal" ]] && ! grep -q '#include <limits>' "$qglobal"; then
    sed -i '1i #include <limits>' "$qglobal"
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
  local cfg="$SRC/qwt/qwtconfig.pri"
  sed -i "s|^#\?QWT_INSTALL_PREFIX.*|QWT_INSTALL_PREFIX = $DEPS_PREFIX|" "$cfg"
  cd "$SRC/qwt"
  "$DEPS_PREFIX/bin/qmake" qwt.pro -r CONFIG+=release || return 1
  make -j"$JOBS" || return 1
  make install || return 1
  [[ -f "$DEPS_PREFIX/include/qwt/qwt.h" ]] || installed_lib libqwt-qt5.so
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
  fetch_source SIP "sip-${SIP_VERSION}.tar.gz" "$SRC/sip" configure.py || return 1
  mkdir -p "$PY_SITE" "$DEPS_PREFIX/share/sip"
  cd "$SRC/sip"
  python3 configure.py --bindir="$DEPS_PREFIX/bin" --incdir="$DEPS_PREFIX/include" \
    --sipdir="$DEPS_PREFIX/share/sip" --destdir="$PY_SITE" || return 1
  make -j"$JOBS" || return 1
  make install || return 1
  PYTHONPATH="$PY_SITE${PYTHONPATH:+:$PYTHONPATH}" python3 -c \
    'import sip; print(sip.SIP_VERSION_STR)'
}

dep_pyqt5() {
  fetch_source PYQT5 "PyQt5-${PYQT5_VERSION}.tar.gz" "$SRC/pyqt5" \
    configure.py sip/QtCore/QtCoremod.sip || return 1
  qmake_ready || return 1
  if [[ ! -x "$DEPS_PREFIX/bin/sip" ]]; then
    warn "SIP 未就绪：缺 $DEPS_PREFIX/bin/sip"
    return 1
  fi
  mkdir -p "$PY_SITE/PyQt5" "$DEPS_PREFIX/share/sip/PyQt5"
  cd "$SRC/pyqt5"
  PYTHONPATH="$PY_SITE${PYTHONPATH:+:$PYTHONPATH}" python3 configure.py \
    --confirm-license --qmake="$DEPS_PREFIX/bin/qmake" \
    --sip="$DEPS_PREFIX/bin/sip" --sip-incdir="$DEPS_PREFIX/include" \
    --bindir="$DEPS_PREFIX/bin" --destdir="$PY_SITE/PyQt5" \
    --sipdir="$DEPS_PREFIX/share/sip/PyQt5" \
    --no-designer-plugin --no-qml-plugin --no-tools || return 1
  make -j"$JOBS" || return 1
  make install || return 1
  PYTHONPATH="$PY_SITE${PYTHONPATH:+:$PYTHONPATH}" python3 -c \
    'from PyQt5 import QtCore; print(QtCore.PYQT_VERSION_STR)'
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
