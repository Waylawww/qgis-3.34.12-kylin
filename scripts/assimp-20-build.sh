#!/usr/bin/env bash
# 阶段 2：在银河麒麟主机上原生编译 Assimp，跑 ctest，安装到私有前缀并打包 RPM。
# 不写 /usr（wrappers 只在 RPM 的 %files 里声明），不覆盖系统库。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/assimp.env"

need_cmd python3 "版本比较"
need_cmd objdump "ISA 校验"
need_cmd rpmbuild "RPM 打包"

JOBS="${ASSIMP_BUILD_JOBS:-4}"
SRC="$ASSIMP_SRC_DIR"
BUILD="$ASSIMP_BUILD_DIR"
STAGE="$ASSIMP_STAGE_DIR"
STAGE_PREFIX="${STAGE}${ASSIMP_INSTALL_PREFIX}"
LOCAL_PREFIX="${ASSIMP_LOCAL_ROOT}${ASSIMP_INSTALL_PREFIX}"
TOP="$ASSIMP_RPM_TOP"
LOG="${ASSIMP_REPORT_DIR}/logs"
mkdir -p "$LOG" "${TOP}/SPECS" "${TOP}/RPMS" "${ASSIMP_OUT_DIR}/rpms"

log "== 阶段 2 / BUILD ASSIMP ${ASSIMP_VERSION} (native, jobs=$JOBS) =="

# ---------------- CMake 选择（系统 cmake 过旧时源码自举到私有目录） ----------
cmake_version() { "$1" --version 2>/dev/null | head -n1 | awk '{print $NF}'; }
version_ge() {
  python3 -c 'import sys; a=tuple(map(int,sys.argv[1].split(".")+["0"]*3)); b=tuple(map(int,sys.argv[2].split(".")+["0"]*3)); sys.exit(0 if a[:3]>=b[:3] else 1)' "$1" "$2"
}
CMAKE=""
for cand in "${ASSIMP_CMAKE:-}" "${DEPS_PREFIX:-}/bin/cmake" "$(command -v cmake || true)"; do
  [[ -n "$cand" && -x "$cand" ]] || continue
  v="$(cmake_version "$cand")"
  if version_ge "$v" "${ASSIMP_MIN_CMAKE}"; then CMAKE="$cand"; break; fi
  log "cmake 过旧，跳过: $cand ($v)"
done
if [[ -z "$CMAKE" ]]; then
  info "系统 cmake 低于 ${ASSIMP_MIN_CMAKE}，源码自举 CMake ${ASSIMP_BOOTSTRAP_CMAKE_VERSION}"
  need_cmd make "自举 CMake"
  V="${ASSIMP_BOOTSTRAP_CMAKE_VERSION}"
  CMAKE_SRC="${ASSIMP_WORK}/cmake-src-${V}"
  CMAKE_INST="${ASSIMP_TOOLS_DIR}/cmake-${V}"
  TARBALL="${ASSIMP_WORK}/cmake-${V}.tar.gz"
  if [[ ! -x "${CMAKE_INST}/bin/cmake" ]]; then
    rm -rf "$CMAKE_SRC" "$TARBALL"
    for url in \
      "https://ghproxy.net/https://github.com/Kitware/CMake/archive/refs/tags/v${V}.tar.gz" \
      "https://codeload.github.com/Kitware/CMake/tar.gz/refs/tags/v${V}" \
      "https://cmake.org/files/v${V%.*}/cmake-${V}.tar.gz"; do
      if curl -fL --retry 3 --connect-timeout 20 --max-time 900 -o "$TARBALL" "$url" \
         && tar -tzf "$TARBALL" >/dev/null 2>&1; then break; fi
      rm -f "$TARBALL"
    done
    [[ -s "$TARBALL" ]] || die "CMake ${V} 下载失败"
    mkdir -p "$CMAKE_SRC"
    tar -xzf "$TARBALL" --strip-components=1 -C "$CMAKE_SRC"
    ( cd "$CMAKE_SRC" && ./bootstrap --prefix="$CMAKE_INST" --parallel="$JOBS" -- -DCMAKE_USE_OPENSSL=OFF ) \
      2>&1 | tee "${LOG}/cmake-bootstrap.log"
    make -C "$CMAKE_SRC" -j"$JOBS" 2>&1 | tee "${LOG}/cmake-make.log"
    make -C "$CMAKE_SRC" install 2>&1 | tee "${LOG}/cmake-install.log"
  fi
  CMAKE="${CMAKE_INST}/bin/cmake"
fi
CMAKE_VER="$(cmake_version "$CMAKE")"
log "使用 cmake: $CMAKE ($CMAKE_VER)"

# ---------------- 生成器 ----------------------------------------------------
NINJA="${ASSIMP_NINJA:-}"
if [[ -z "$NINJA" && -x "${DEPS_PREFIX:-}/bin/ninja" ]]; then NINJA="${DEPS_PREFIX}/bin/ninja"; fi
if [[ -z "$NINJA" ]]; then NINJA="$(command -v ninja || true)"; fi
if [[ -n "$NINJA" ]]; then
  GEN=( -G Ninja "-DCMAKE_MAKE_PROGRAM=$NINJA" )
else
  GEN=( -G "Unix Makefiles" )
fi
log "生成器: ${GEN[0]}"
rm -f "$BUILD/.cfg-sig"

# ---------------- 配置 ------------------------------------------------------
: "${ISA_CFLAGS:=-march=x86-64 -mtune=generic -O2 -pipe}"
: "${ISA_CXXFLAGS:=-march=x86-64 -mtune=generic -O2 -pipe}"
CMAKE_ARGS=(
  "${GEN[@]}"
  "-S" "$SRC" "-B" "$BUILD"
  "-DCMAKE_BUILD_TYPE=Release"
  "-DCMAKE_INSTALL_PREFIX=${ASSIMP_INSTALL_PREFIX}"
  "-DCMAKE_INSTALL_LIBDIR=lib64"
  "-DCMAKE_INSTALL_RPATH=${ASSIMP_INSTALL_PREFIX}/lib64"
  "-DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF"
  "-DCMAKE_C_FLAGS=${ISA_CFLAGS}"
  "-DCMAKE_CXX_FLAGS=${ISA_CXXFLAGS}"
  "-DASSIMP_BUILD_TESTS=${ASSIMP_BUILD_TESTS}"
  "-DASSIMP_BUILD_ASSIMP_TOOLS=${ASSIMP_BUILD_TOOLS}"
  "-DASSIMP_BUILD_SAMPLES=${ASSIMP_BUILD_SAMPLES}"
  "-DASSIMP_WARNINGS_AS_ERRORS=${ASSIMP_WARNINGS_AS_ERRORS}"
  "-DASSIMP_OPT_BUILD_PACKAGES=OFF"
  "-DASSIMP_INSTALL=ON"
  "-DBUILD_SHARED_LIBS=${ASSIMP_BUILD_SHARED}"
)
printf '%s\n' "${CMAKE_ARGS[@]}" > "${ASSIMP_REPORT_DIR}/assimp-cmake-args.txt"
"$CMAKE" "${CMAKE_ARGS[@]}" 2>&1 | tee "${LOG}/assimp-cmake-config.log"

# ---------------- 编译 ------------------------------------------------------
"$CMAKE" --build "$BUILD" --parallel "$JOBS" 2>&1 | tee "${LOG}/assimp-build.log"

# ---------------- 单元测试（失败也先留下证据，最后统一判定） ----------------
# assimp 6.0.5 的 test/CMakeLists.txt 只有 add_test()，顶层没有 enable_testing()，
# 因此 `ctest` 在根目录永远报 "No tests were found!!!" 且退出码 0（假成功）。
# 直接运行 unit 可执行文件才是真实测试。
UNIT_BIN="$(find "$BUILD" -type f -name unit -perm -u+x | head -n1)"
[[ -n "$UNIT_BIN" ]] || die "未找到 unit 测试程序，编译阶段不完整"
# unit / libassimp 由 GCC11 编译，运行前必须让动态加载器看到新版 libstdc++，
# 否则直接报 GLIBCXX_3.4.29 / CXXABI_1.3.13 not found 而以退出码 1 失败。
GCC_RT="$(dirname "$(readlink -f "$(g++ -print-file-name=libstdc++.so.6 2>/dev/null || echo /nonexistent)")" 2>/dev/null || true)"
if [[ -n "$GCC_RT" && -f "${GCC_RT}/libstdc++.so.6" ]] \
   && grep -aq 'GLIBCXX_3\.4\.29' "${GCC_RT}/libstdc++.so.6" 2>/dev/null; then
  export LD_LIBRARY_PATH="${GCC_RT}:${BUILD}/bin${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  log "unit 运行库: ${GCC_RT}"
else
  die "未定位到 GCC11 libstdc++ 运行库，unit 无法运行"
fi
CTEST_RC=0
"$UNIT_BIN" 2>&1 | tee "${LOG}/assimp-ctest.log" || CTEST_RC=$?
log "unit 测试退出码: ${CTEST_RC}"

# ---------------- DESTDIR 安装 + 私有前缀 ----------------------------------
rm -rf "$STAGE" "$ASSIMP_LOCAL_ROOT"
mkdir -p "$STAGE" "$ASSIMP_LOCAL_ROOT" "${STAGE_PREFIX}/share/assimp-selftest"
DESTDIR="$STAGE" "$CMAKE" --install "$BUILD" 2>&1 | tee "${LOG}/assimp-install.log"
[[ -d "${STAGE_PREFIX}/lib64" ]] || die "DESTDIR 安装未产生 ${STAGE_PREFIX}/lib64"
cp -f "${SRC}/test/models/OBJ/box.obj" "${STAGE_PREFIX}/share/assimp-selftest/box.obj"

# GCC11 运行库：麒麟系统 /usr/lib64 的 libstdc++.so.6 来自 gcc-7.3.0，
# 不含 GLIBCXX_3.4.29，而本机 gcc 11 编出的 libassimp 需要它。必须随 RPM
# 一起打包，否则目标机 ldd/启动失败（QGIS 真机曾踩同一个坑）。
find_gcc_runtime() {
  local cand dir base
  for cand in \
    "$(g++ -print-file-name=libstdc++.so.6 2>/dev/null || true)" \
    "${DEPS_PREFIX:-}/lib/libstdc++.so.6" \
    "${DEPS_PREFIX:-}/lib64/libstdc++.so.6" \
    /usr/local/gcc11/lib64/libstdc++.so.6 \
    /usr/local/gcc11/lib/libstdc++.so.6 \
    /usr/lib/gcc/x86_64-redhat-linux/11/libstdc++.so.6; do
    [[ -e "$cand" ]] || continue
    base="$(readlink -f "$cand" 2>/dev/null || true)"
    [[ -n "$base" && -f "$base" ]] || continue
    if grep -aq 'GLIBCXX_3\.4\.29' "$base" 2>/dev/null; then
      dirname "$base"
      return 0
    fi
  done
  return 1
}
GCC_LIBDIR="$(find_gcc_runtime || true)"
[[ -n "$GCC_LIBDIR" ]] || die "未找到含 GLIBCXX_3.4.29 的 GCC11 libstdc++ 运行库"
cp -L "${GCC_LIBDIR}/$(basename "$(readlink -f "${GCC_LIBDIR}/libstdc++.so.6")")" \
   "${STAGE_PREFIX}/lib64/" 2>/dev/null || cp -L "${GCC_LIBDIR}/libstdc++.so.6" "${STAGE_PREFIX}/lib64/"
ln -sfn "$(basename "$(readlink -f "${GCC_LIBDIR}/libstdc++.so.6")")" \
  "${STAGE_PREFIX}/lib64/libstdc++.so.6"
if [[ -f "${GCC_LIBDIR}/libgcc_s.so.1" ]]; then
  cp -L "${GCC_LIBDIR}/libgcc_s.so.1" "${STAGE_PREFIX}/lib64/" || true
fi
log "已随包打入 GCC11 运行库: $(ls -1 "${STAGE_PREFIX}/lib64"/libstdc++.so.6* | tr '\n' ' ')"

cp -a "$STAGE/." "$ASSIMP_LOCAL_ROOT/"

# /usr/bin wrapper 只在 RPM 里声明，构建机 /usr 不被写入
mkdir -p "${STAGE}/usr/bin"
cat > "${STAGE}/usr/bin/assimp" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH="${ASSIMP_INSTALL_PREFIX}/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "${ASSIMP_INSTALL_PREFIX}/bin/assimp" "\$@"
EOF
chmod 755 "${STAGE}/usr/bin/assimp"

# ---------------- 静态校验 --------------------------------------------------
LIB="${LOCAL_PREFIX}/lib64/libassimp.so.${ASSIMP_VERSION}"
[[ -e "$LIB" ]] || LIB="$(find "${LOCAL_PREFIX}/lib64" -maxdepth 1 -name 'libassimp.so*' -print -quit)"
[[ -n "$LIB" ]] || die "安装树中没有 libassimp.so"
export LD_LIBRARY_PATH="${LOCAL_PREFIX}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
ldd_out="$(ldd "$LIB" 2>&1 || true)"
printf '%s\n' "$ldd_out" > "${ASSIMP_REPORT_DIR}/assimp-ldd.txt"
grep -q 'not found' <<<"$ldd_out" && die "libassimp 动态库依赖未闭合: $ldd_out"

rpath="$(readelf -d "$LIB" 2>/dev/null | grep -E 'RPATH|RUNPATH' || true)"
if grep -Eq 'actions|_assimp-605|/work/|/rpmbuild|BUILDROOT|/tmp/' <<<"$rpath"; then
  die "libassimp RUNPATH 泄漏构建机路径: $rpath"
fi
if objdump -d "$LIB" 2>/dev/null | grep -m1 -Eq '\bzmm[0-9]+\b'; then
  die "libassimp 含 AVX-512 指令，违反 x86-64 baseline 策略"
fi

# ---------------- 二进制 RPM ------------------------------------------------
SPEC="${TOP}/SPECS/assimp-kylin.spec"
cat > "$SPEC" <<EOF
Name:           assimp
Version:        ${ASSIMP_VERSION}
Release:        1.ky10
Summary:        Assimp ${ASSIMP_VERSION} native build for Kylin V10 x86_64
License:        BSD-3-Clause
URL:            ${ASSIMP_UPSTREAM_REPO}
BuildArch:      x86_64
AutoReqProv:    no
%global __os_install_post %{nil}
%description
Open Asset Import Library ${ASSIMP_VERSION}, compiled natively on Kylin V10
(Halberd) / Hygon C86. Runtime libraries are installed under
${ASSIMP_INSTALL_PREFIX}; /usr/bin/assimp is a wrapper.
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
* Tue Nov 17 2026 Assimp Kylin Builder - ${ASSIMP_VERSION}-1.ky10
- Native build from upstream tag ${ASSIMP_TAG} with audited local patch
EOF
cp -f "$SPEC" "${ASSIMP_REPORT_DIR}/assimp-kylin.spec"

rpmbuild -ba --define "_topdir ${TOP}" --define "_smp_mflags -j1" "$SPEC" \
  2>&1 | tee "${LOG}/assimp-rpmbuild.log"
RPMS="$(find "${TOP}/RPMS" -name '*.rpm' -type f | sort)"
[[ -n "$RPMS" ]] || die "rpmbuild 未产生 RPM"
while IFS= read -r f; do cp -f "$f" "${ASSIMP_OUT_DIR}/rpms/"; done <<< "$RPMS"

python3 - "${ASSIMP_REPORT_DIR}" "${ASSIMP_VERSION}" "${CMAKE_VER}" "${CTEST_RC}" \
          "${ASSIMP_OUT_DIR}" "${LIB}" <<'PY'
import datetime, glob, json, os, sys
rep, version, cmake_ver, ctest_rc, out, lib = sys.argv[1:7]
ctest_log = os.path.join(rep, 'logs', 'assimp-ctest.log')
summary = ''
if os.path.exists(ctest_log):
    for line in reversed(open(ctest_log, encoding='utf-8', errors='replace').read().splitlines()):
        if line.strip():
            summary = line.strip()
            break
data = {
    'stage': 'ASSIMP_STAGE_2_NATIVE_BUILD',
    'version': version, 'cmake': cmake_ver,
    'ctest_exit_code': int(ctest_rc), 'ctest_tail': summary,
    'rpms': [os.path.basename(p) for p in sorted(glob.glob(os.path.join(out, 'rpms', 'assimp*.rpm')))],
    'library': lib,
    'isa_policy': 'x86-64-baseline',
    'ldd_clean': True, 'rpath_clean': True, 'no_avx512': True,
    'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
with open(os.path.join(rep, 'assimp-build.json'), 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
print(json.dumps(data, ensure_ascii=False, indent=2))
PY

stage_marker ASSIMP_STAGE_2_BUILD_OK PASS "${ASSIMP_REPORT_DIR}/assimp-build-ok.json"
if [[ "$CTEST_RC" -ne 0 ]]; then
  die "ctest 有失败用例（退出码 ${CTEST_RC}）；证据见 ${LOG}/assimp-ctest.log"
fi
info "ASSIMP BUILD PASS"
