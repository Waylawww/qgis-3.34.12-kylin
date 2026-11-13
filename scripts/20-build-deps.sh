#!/usr/bin/env bash
# 阶段 2：在目标银河麒麟 V10 主机上，把 QGIS 3.34.12 缺失/过旧的依赖
# 全部构建到独立前缀 $DEPS_PREFIX（actionsrunner 用户，无 sudo、不写 /usr）。
# 每个依赖独立日志 + stamp 缓存；单项失败不中断，最后统一汇总并失败退出，
# 保证一次运行即可拿到全部真实错误用于下一轮修复。
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
mkdir -p "$SRC" "$BUILD" "$STAMPS" "$SYSROOT" "$LOG" "$CACHE_DIR/rpms"
: > "$STATUS_FILE"
declare -A STATUS
FAILURES=()

info "== 阶段 2 / BUILD NATIVE DEPENDENCIES =="
log "prefix=$DEPS_PREFIX jobs=$JOBS sysroot=$SYSROOT"
log "缓存命中时跳过；FORCE_REBUILD_DEPS=${FORCE_REBUILD_DEPS:-false}"
if [[ "${FORCE_REBUILD_DEPS:-false}" == "true" ]]; then
  rm -f "$STAMPS"/*.ok
fi

# --- 通用函数 --------------------------------------------------------------
setup_flags() {
  export PATH="$DEPS_PREFIX/bin:$PATH"
  export LD_LIBRARY_PATH="$DEPS_PREFIX/lib:$DEPS_PREFIX/lib64:${SYSROOT}/usr/lib64:${LD_LIBRARY_PATH:-}"
  export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig:$DEPS_PREFIX/lib64/pkgconfig:${SYSROOT}/usr/lib64/pkgconfig:${SYSROOT}/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CMAKE_PREFIX_PATH="$DEPS_PREFIX;${SYSROOT}/usr"
  export CPPFLAGS="-I$DEPS_PREFIX/include -I${SYSROOT}/usr/include ${CPPFLAGS:-}"
  export LDFLAGS="-L$DEPS_PREFIX/lib -L${SYSROOT}/usr/lib64 -Wl,-rpath,$DEPS_PREFIX/lib -Wl,-rpath,${SYSROOT}/usr/lib64 ${LDFLAGS:-}"
  export CMAKE_INSTALL_RPATH="$DEPS_PREFIX/lib;$DEPS_PREFIX/lib64;${SYSROOT}/usr/lib64"
}

fetch() {
  local dest="$1"; shift
  if [[ -s "$dest" ]]; then log "  已缓存 $(basename "$dest")"; return 0; fi
  local url
  for url in "$@"; do
    log "  下载 $url"
    if curl -fsSL --retry 2 --connect-timeout 20 --max-time 2400 "$url" -o "${dest}.part" \
       && [[ -s "${dest}.part" ]] && [[ $(stat -c %s "${dest}.part") -gt 100000 ]]; then
      mv -f "${dest}.part" "$dest"
      sha256sum "$dest" >> "$REPORT_DIR/deps-sources.sha256" 2>/dev/null || true
      return 0
    fi
    warn "  下载失败: $url"
    rm -f "${dest}.part"
  done
  return 1
}

fetch_named() {
  local name="$1" tarball="$2"
  eval "local urls=(\"\${${name}_URLS[@]}\")"
  fetch "$SRC/$tarball" "${urls[@]}"
}

unpack() {
  local tarball="$1" dir="$2"
  if [[ -d "$dir" ]] && [[ -n "$(ls -A "$dir" 2>/dev/null || true)" ]]; then
    log "  已解压 $dir"; return 0
  fi
  mkdir -p "$dir"
  tar -xf "$tarball" -C "$dir" --strip-components=1 || return 1
}

cmake_install() {
  local name="$1" srcdir="$2"; shift 2
  local b="$BUILD/$name"
  rm -rf "$b"; mkdir -p "$b"
  cmake -S "$srcdir" -B "$b" -G Ninja \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_INSTALL_PREFIX:PATH="$DEPS_PREFIX" \
    -DCMAKE_PREFIX_PATH:PATH="$DEPS_PREFIX;${SYSROOT}/usr" \
    -DCMAKE_INSTALL_RPATH:STRING="$DEPS_PREFIX/lib;$DEPS_PREFIX/lib64;${SYSROOT}/usr/lib64" \
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH:BOOL=ON \
    -DBUILD_TESTING:BOOL=OFF -DBUILD_SHARED_LIBS:BOOL=ON "$@" || return 1
  ninja -C "$b" -j"$JOBS" || return 1
  ninja -C "$b" install || return 1
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
setup_flags

# --- D1..Dn: 各依赖 -------------------------------------------------------
dep_geos() {
  fetch_named GEOS "$GEOS_TARBALL" || return 1
  unpack "$SRC/$GEOS_TARBALL" "$SRC/geos" || return 1
  cmake_install geos "$SRC/geos" -DBUILD_GEOSOP:BOOL=OFF || return 1
  [[ -x "$DEPS_PREFIX/bin/geos-config" ]] || [[ -f "$DEPS_PREFIX/lib/libgeos_c.so" ]]
}
dep_proj() {
  fetch_named PROJ "$PROJ_TARBALL" || return 1
  unpack "$SRC/$PROJ_TARBALL" "$SRC/proj" || return 1
  cmake_install proj "$SRC/proj" \
    -DENABLE_TIFF:BOOL=OFF -DENABLE_CURL:BOOL=OFF \
    -DBUILD_PROJINFO:BOOL=ON -DBUILD_CCT:BOOL=ON -DBUILD_CS2CS:BOOL=ON \
    -DBUILD_PROJSYNC:BOOL=OFF || return 1
  [[ -f "$DEPS_PREFIX/include/proj.h" ]] && [[ -f "$DEPS_PREFIX/lib/libproj.so" ]]
}
dep_gdal() {
  fetch_named GDAL "$GDAL_TARBALL" || return 1
  unpack "$SRC/$GDAL_TARBALL" "$SRC/gdal" || return 1
  cmake_install gdal "$SRC/gdal" \
    -DBUILD_PYTHON_BINDINGS:BOOL=OFF -DBUILD_JAVA_BINDINGS:BOOL=OFF \
    -DBUILD_CSHARP_BINDINGS:BOOL=OFF \
    -DGDAL_USE_TIFF:BOOL=ON -DGDAL_USE_JPEG:BOOL=ON -DGDAL_USE_PNG:BOOL=ON \
    -DGDAL_USE_CURL:BOOL=OFF -DGDAL_USE_POSTGRESQL:BOOL=OFF \
    -DGDAL_USE_ZSTD:BOOL=OFF -DGDAL_USE_GEOTIFF:BOOL=OFF \
    -DOGR_BUILD_OPTIONAL_DRIVERS:BOOL=OFF || return 1
  [[ -x "$DEPS_PREFIX/bin/gdalinfo" ]]
}
dep_spatialindex() {
  fetch_named SPATIALINDEX "spatialindex-src-${SPATIALINDEX_VERSION}.tar.gz" || return 1
  unpack "$SRC/spatialindex-src-${SPATIALINDEX_VERSION}.tar.gz" "$SRC/spatialindex" || return 1
  cmake_install spatialindex "$SRC/spatialindex" || return 1
  [[ -f "$DEPS_PREFIX/include/spatialindex/SpatialIndex.h" ]] || \
    [[ -f "$DEPS_PREFIX/lib/libspatialindex_c.so" ]]
}
dep_libzip() {
  fetch_named LIBZIP "libzip-${LIBZIP_VERSION}.tar.gz" || return 1
  unpack "$SRC/libzip-${LIBZIP_VERSION}.tar.gz" "$SRC/libzip" || return 1
  cmake_install libzip "$SRC/libzip" -DENABLE_GNUTLS:BOOL=OFF \
    -DENABLE_OPENSSL:BOOL=OFF -DBUILD_DOC:BOOL=OFF -DBUILD_EXAMPLES:BOOL=OFF || return 1
  [[ -f "$DEPS_PREFIX/include/zip.h" ]]
}
dep_exiv2() {
  fetch_named EXIV2 "exiv2-${EXIV2_VERSION}.tar.gz" || return 1
  unpack "$SRC/exiv2-${EXIV2_VERSION}.tar.gz" "$SRC/exiv2" || return 1
  cmake_install exiv2 "$SRC/exiv2" \
    -DEXIV2_ENABLE_VIDEO:BOOL=OFF -DEXIV2_ENABLE_WEBREADY:BOOL=OFF \
    -DEXIV2_BUILD_SAMPLES:BOOL=OFF -DEXIV2_BUILD_EXIV2_COMMAND:BOOL=OFF || return 1
  [[ -f "$DEPS_PREFIX/include/exiv2/exiv2.hpp" ]] || \
    [[ -f "$DEPS_PREFIX/lib/libexiv2.so" ]]
}

dep_qt() {
  fetch_named QT "$QT_TARBALL" || return 1
  unpack "$SRC/$QT_TARBALL" "$SRC/qt" || return 1
  # Qt 5.15.2 在 GCC 11 下需要 <limits>（std::numeric_limits）
  local qglobal="$SRC/qt/qtbase/src/corelib/global/qglobal.h"
  if [[ -f "$qglobal" ]] && ! grep -q '#include <limits>' "$qglobal"; then
    sed -i '1i #include <limits>' "$qglobal"
  fi
  local b="$BUILD/qt"
  rm -rf "$b"; mkdir -p "$b"; cd "$b"
  "$SRC/qt/configure" -opensource -confirm-license -release -shared \
    -prefix "$DEPS_PREFIX" \
    -nomake examples -nomake tests \
    -skip qtwebengine -skip qtdoc -skip qtwayland -skip qtconnectivity \
    -skip qtsensors -skip qtserialport -skip qtgamepad \
    -skip qtandroidextras -skip qtmacextras -skip qtwinextras \
    -skip qtpurchasing -skip qtcharts -skip qtdatavis3d \
    -skip qtnetworkauth -skip qtremoteobjects -skip qtscxml \
    -skip qtspeech -skip qtvirtualkeyboard \
    -qt-xcb -qt-pcre -qt-doubleconversion -qt-harfbuzz \
    -qt-libpng -qt-libjpeg -qt-zlib \
    -system-freetype -fontconfig -openssl \
    -no-cups -no-dbus -no-glib -no-pulseaudio -no-alsa -no-gtk \
    -no-eglfs -no-directfb -no-linuxfb -no-kms \
    -no-compile-examples || return 1
  make -j"$JOBS" || return 1
  make install || return 1
  [[ -x "$DEPS_PREFIX/bin/qmake" ]] && [[ -d "$DEPS_PREFIX/lib/cmake/Qt53DCore" ]]
}

dep_qwt() {
  fetch_named QWT "qwt-${QWT_VERSION}.tar.bz2" || return 1
  unpack "$SRC/qwt-${QWT_VERSION}.tar.bz2" "$SRC/qwt" || return 1
  local cfg="$SRC/qwt/qwtconfig.pri"
  sed -i "s|^#\?QWT_INSTALL_PREFIX.*|QWT_INSTALL_PREFIX = $DEPS_PREFIX|" "$cfg"
  cd "$SRC/qwt"
  "$DEPS_PREFIX/bin/qmake" qwt.pro -r CONFIG+=release || return 1
  make -j"$JOBS" || return 1
  make install || return 1
  [[ -f "$DEPS_PREFIX/include/qwt/qwt.h" ]] || [[ -f "$DEPS_PREFIX/lib/libqwt-qt5.so" ]]
}

dep_qscintilla() {
  fetch_named QSCINTILLA "QScintilla_src-${QSCINTILLA_VERSION}.tar.gz" || return 1
  unpack "$SRC/QScintilla_src-${QSCINTILLA_VERSION}.tar.gz" "$SRC/qscintilla" || return 1
  cd "$SRC/qscintilla/Qt4Qt5"
  "$DEPS_PREFIX/bin/qmake" qscintilla.pro CONFIG+=release || return 1
  make -j"$JOBS" || return 1
  mkdir -p "$DEPS_PREFIX/include/Qsci" "$DEPS_PREFIX/lib"
  cp -f Qsci/*.h "$DEPS_PREFIX/include/Qsci/" || return 1
  cp -a libqscintilla2_qt5.so* "$DEPS_PREFIX/lib/" || return 1
  [[ -f "$DEPS_PREFIX/include/Qsci/qsciscintilla.h" ]]
}

dep_qca() {
  fetch_named QCA "qca-${QCA_VERSION}.tar.gz" || return 1
  unpack "$SRC/qca-${QCA_VERSION}.tar.gz" "$SRC/qca" || return 1
  cmake_install qca "$SRC/qca" \
    -DQT4_BUILD:BOOL=OFF -DBUILD_TESTS:BOOL=OFF -DBUILD_TOOLS:BOOL=OFF \
    -DBUILD_PLUGINS:STRING=auto || return 1
  [[ -f "$DEPS_PREFIX/include/QtCrypto/QtCrypto" ]] || \
    [[ -f "$DEPS_PREFIX/lib/libqca-qt5.so" ]]
}

dep_qtkeychain() {
  fetch_named QTKEYCHAIN "qtkeychain-${QTKEYCHAIN_VERSION}.tar.gz" || return 1
  unpack "$SRC/qtkeychain-${QTKEYCHAIN_VERSION}.tar.gz" "$SRC/qtkeychain" || return 1
  cmake_install qtkeychain "$SRC/qtkeychain" \
    -DBUILD_WITH_QT6:BOOL=OFF -DBUILD_TESTING:BOOL=OFF \
    -DLIBSECRET_SUPPORT:BOOL=OFF -DBUILD_TRANSLATIONS:BOOL=OFF || return 1
  [[ -f "$DEPS_PREFIX/include/qt5keychain/keychain.h" ]] || \
    [[ -f "$DEPS_PREFIX/lib/libqt5keychain.so" ]]
}

dep_sip() {
  local t="sip-${SIP_VERSION}.tar.gz"
  if ! fetch "$SRC/$t" "${SIP_URLS[@]}"; then
    python3 -m pip download "$SIP_PIP_SPEC" --no-binary :all: --no-deps \
      -d "$CACHE_DIR/pypi" >> "$LOG/dep-sip.log" 2>&1 || return 1
    cp -f "$CACHE_DIR/pypi"/sip-*.tar.gz "$SRC/$t" || return 1
  fi
  unpack "$SRC/$t" "$SRC/sip" || return 1
  local py_site="$DEPS_PREFIX/lib/python3.7/site-packages"
  mkdir -p "$py_site" "$DEPS_PREFIX/share/sip"
  cd "$SRC/sip"
  python3 configure.py --bindir="$DEPS_PREFIX/bin" --incdir="$DEPS_PREFIX/include" \
    --sipdir="$DEPS_PREFIX/share/sip" --destdir="$py_site" || return 1
  make -j"$JOBS" || return 1
  make install || return 1
  PYTHONPATH="$py_site${PYTHONPATH:+:$PYTHONPATH}" python3 -c 'import sip;print(sip.SIP_VERSION_STR)'
}

dep_pyqt5() {
  local t="PyQt5-${PYQT5_VERSION}.tar.gz"
  if ! fetch "$SRC/$t" "${PYQT5_URLS[@]}"; then
    python3 -m pip download "$PYQT5_PIP_SPEC" --no-binary :all: --no-deps \
      -d "$CACHE_DIR/pypi" >> "$LOG/dep-pyqt5.log" 2>&1 || return 1
    cp -f "$CACHE_DIR/pypi"/PyQt5-*.tar.gz "$SRC/$t" || return 1
  fi
  unpack "$SRC/$t" "$SRC/pyqt5" || return 1
  local py_site="$DEPS_PREFIX/lib/python3.7/site-packages"
  mkdir -p "$py_site/PyQt5" "$DEPS_PREFIX/share/sip/PyQt5"
  cd "$SRC/pyqt5"
  PYTHONPATH="$py_site${PYTHONPATH:+:$PYTHONPATH}" python3 configure.py \
    --confirm-license --qmake="$DEPS_PREFIX/bin/qmake" \
    --sip="$DEPS_PREFIX/bin/sip" --sip-incdir="$DEPS_PREFIX/include" \
    --bindir="$DEPS_PREFIX/bin" --destdir="$py_site/PyQt5" \
    --sipdir="$DEPS_PREFIX/share/sip/PyQt5" \
    --no-designer-plugin --no-qml-plugin --no-tools || return 1
  make -j"$JOBS" || return 1
  make install || return 1
  PYTHONPATH="$py_site${PYTHONPATH:+:$PYTHONPATH}" python3 -c \
    'from PyQt5 import QtCore;print(QtCore.PYQT_VERSION_STR)'
}

for pair in "geos:dep_geos" "proj:dep_proj" "spatialindex:dep_spatialindex" \
            "libzip:dep_libzip" "exiv2:dep_exiv2" "gdal:dep_gdal" \
            "qt:dep_qt" "qwt:dep_qwt" "qscintilla:dep_qscintilla" \
            "qca:dep_qca" "qtkeychain:dep_qtkeychain" \
            "sip:dep_sip" "pyqt5:dep_pyqt5"; do
  run_dep "${pair%%:*}" "${pair##*:}"
done

# --- 汇总 ------------------------------------------------------------------
python3 - "$REPORT_DIR" "$DEPS_PREFIX" "$STATUS_FILE" "${FAILURES[@]+"${FAILURES[@]}"}" <<'PY'
import datetime, json, os, sys
rep, prefix, status_file = sys.argv[1:4]
fails = sys.argv[4:]
status = {}
for line in open(status_file, encoding='utf-8'):
    parts = line.strip().split('\t')
    if len(parts) == 2:
        status[parts[0]] = parts[1]
data = {
    'generated_at': datetime.datetime.utcnow().isoformat() + 'Z',
    'deps_prefix': prefix,
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
