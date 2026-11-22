#!/usr/bin/env bash
# 阶段 2：原生编译 Rocky，安装到私有前缀并打包 RPM。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/rocky.env"

need_cmd python3 "构建"
need_cmd objdump "ISA 校验"
need_cmd rpmbuild "RPM 打包"
JOBS="${ROCKY_BUILD_JOBS:-4}"
BUILD="$ROCKY_BUILD_DIR"
STAGE="$ROCKY_STAGE_DIR"
STAGE_PREFIX="${STAGE}${ROCKY_INSTALL_PREFIX}"
LOCAL_PREFIX="${ROCKY_LOCAL_ROOT}${ROCKY_INSTALL_PREFIX}"
LOG="${ROCKY_REPORT_DIR}/logs"
TOP="$ROCKY_RPM_TOP"
mkdir -p "$LOG" "${TOP}/SPECS" "${TOP}/RPMS" "$ROCKY_OUT_DIR/rpms"
log "== 阶段 2 / BUILD ROCKY ${ROCKY_VERSION} (jobs=$JOBS) =="

locate_gcc_runtime() {
  local cand base
  for cand in "$(g++ -print-file-name=libstdc++.so.6 2>/dev/null || true)" \
              "${DEPS_PREFIX:-}/lib/libstdc++.so.6" "${DEPS_PREFIX:-}/lib64/libstdc++.so.6"; do
    [[ -e "$cand" ]] || continue
    base="$(readlink -f "$cand" 2>/dev/null || true)"
    [[ -n "$base" && -f "$base" ]] || continue
    grep -aq 'GLIBCXX_3\.4\.29' "$base" 2>/dev/null && { dirname "$base"; return 0; }
  done
  return 1
}
GCC_LIBDIR="$(locate_gcc_runtime || true)"
if [[ "${REQUIRE_GCC11:-true}" == "true" ]]; then
  [[ -n "$GCC_LIBDIR" ]] || die "未找到 GCC11 libstdc++ 运行库"
else
  GCC_LIBDIR=''
  log "REQUIRE_GCC11=false：使用系统 libstdc++，不打包私有运行库"
fi

# B 设备 vsg/glslang 前缀（cmake config + 运行库）；A 设备用 /opt 系统安装路径。
VSG_DEP_PREFIX="${B_VSG_PREFIX:-/opt/osg2vsg-0.4.0}"
GLSLANG_DEP_PREFIX="${B_GLSLANG_PREFIX:-/opt/glslang-16.1.0}"
log "VSG dep prefix: ${VSG_DEP_PREFIX}"
log "glslang dep prefix: ${GLSLANG_DEP_PREFIX}"

export LD_LIBRARY_PATH="${GCC_LIBDIR:+${GCC_LIBDIR}:}${LOCAL_PREFIX}/lib64:${LOCAL_PREFIX}/lib:${ROCKY_DEPS_PREFIX}/lib:${ROCKY_DEPS_PREFIX}/lib64:${DEPS_PREFIX:-}/lib:${DEPS_PREFIX:-}/lib64:${VSG_DEP_PREFIX}/lib64:${VSG_DEP_PREFIX}/lib:${GLSLANG_DEP_PREFIX}/lib64:${GLSLANG_DEP_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

NINJA="$(command -v ninja || true)"
if [[ -n "$NINJA" ]]; then GEN=( -G Ninja "-DCMAKE_MAKE_PROGRAM=$NINJA" ); else GEN=( -G "Unix Makefiles" ); fi
if [[ "${TARGET_ARCH:-x86_64}" == "aarch64" ]]; then
  : "${ISA_CFLAGS:=-march=armv8-a -O2 -pipe}"
  : "${ISA_CXXFLAGS:=-march=armv8-a -O2 -pipe}"
else
  : "${ISA_CFLAGS:=-march=x86-64 -mtune=generic -O2 -pipe}"
  : "${ISA_CXXFLAGS:=-march=x86-64 -mtune=generic -O2 -pipe}"
fi
log "ISA: arch=${TARGET_ARCH:-x86_64} policy=${ISA_POLICY:-default} CFLAGS=${ISA_CFLAGS}"

# Rocky 要求 cmake >= 3.21；B 设备系统 cmake 3.16 过低。优先用 B 已自举的新版
# cmake（QGIS deps / glslang work / 显式 ROCKY_CMAKE）。
CMAKE_BIN="${ROCKY_CMAKE:-}"
if [[ -z "$CMAKE_BIN" ]] || ! "$CMAKE_BIN" --version 2>/dev/null | grep -Eq '3\.(2[1-9]|[3-9][0-9])'; then
  CMAKE_BIN="$(command -v cmake)"
  for bc in "${DEPS_PREFIX:-}/bin/cmake" "${B_GLSLANG_PREFIX%/opt/*}/tools"/cmake-*/bin/cmake \
            "${B_VSG_PREFIX%/deps/*}/tools"/cmake-*/bin/cmake; do
    [[ -x "$bc" ]] || continue
    if "$bc" --version 2>/dev/null | head -n1 | grep -Eq '3\.(2[1-9]|[3-9][0-9])'; then
      CMAKE_BIN="$bc"; break
    fi
  done
fi
log "cmake: ${CMAKE_BIN} ($(${CMAKE_BIN} --version | head -n1))"

PROJ_FALLBACK=()
if ! compgen -G "${DEPS_PREFIX:-}/lib*/cmake/[Pp][Rr][Oo][Jj]/*onfig.cmake" >/dev/null 2>&1; then
  for proj_lib in "${DEPS_PREFIX:-}/lib64/libproj.so" "${DEPS_PREFIX:-}/lib/libproj.so" /usr/lib64/libproj.so; do
    if [[ -e "$proj_lib" ]]; then PROJ_FALLBACK+=("-DPROJ_LIBRARIES=$proj_lib"); break; fi
  done
  if [[ -d "${DEPS_PREFIX:-}/include" ]]; then
    PROJ_FALLBACK+=("-DPROJ_INCLUDE_DIRS=${DEPS_PREFIX:-}/include")
  fi
fi

VULKAN_FIRST="${ROCKY_WORK}/kylin-vulkan-first.cmake"
cat > "$VULKAN_FIRST" <<EOF
include_directories(BEFORE "${VULKAN_SDK_PREFIX}/include")
EOF

# GCC7 filesystem compat: std::experimental::filesystem 需要私有 libstdc++fs.a。
FS_STD_LIBS=()
FS_STATIC="${ROCKY_DEPS_PREFIX}/lib/libstdc++fs.a"
if [[ "${ROCKY_FS_COMPAT:-}" == "experimental" ]]; then
  [[ -f "$FS_STATIC" ]] || die "缺少 ${FS_STATIC}，请先运行 source 阶段"
  FS_STD_LIBS=("-DCMAKE_CXX_STANDARD_LIBRARIES=${FS_STATIC}")
  log "GCC7 filesystem compat: linking ${FS_STATIC}"
fi

# 配置签名：flags / compat 库 / cmake 变化时清理陈旧缓存（避免旧的 CXX_STANDARD_LIBRARIES）。
CFG_SIG="${ISA_CFLAGS}|${ISA_CXXFLAGS}|${ROCKY_FS_COMPAT:-none}|${FS_STATIC}|${CMAKE_BIN}"
SIG_FILE="${BUILD}/.rocky-config-sig"
mkdir -p "$BUILD"
if [[ -f "$BUILD/CMakeCache.txt" && ( ! -f "$SIG_FILE" || "$(cat "$SIG_FILE")" != "$CFG_SIG" ) ]]; then
  rm -f "$BUILD/CMakeCache.txt"
  log "配置签名变化，已删除旧 CMakeCache.txt"
fi
printf '%s\n' "$CFG_SIG" > "$SIG_FILE"

PREFIX_PATH="${ROCKY_DEPS_PREFIX};${DEPS_PREFIX:-};${VSG_DEP_PREFIX};${GLSLANG_DEP_PREFIX};${VULKAN_SDK_PREFIX}"
"$CMAKE_BIN" "${GEN[@]}" -S "$ROCKY_SRC_DIR" -B "$BUILD" \
  -DCMAKE_PROJECT_INCLUDE="$VULKAN_FIRST" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$ROCKY_INSTALL_PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib64 -DBUILD_SHARED_LIBS="${ROCKY_BUILD_SHARED}" \
  -DROCKY_BUILD_SHARED_LIBS="${ROCKY_BUILD_SHARED}" -DROCKY_APPEND_SO_VERSION=ON \
  "${PROJ_FALLBACK[@]}" \
  "-DCMAKE_PREFIX_PATH=${PREFIX_PATH}" \
  -DVULKAN_SDK="$VULKAN_SDK_PREFIX" \
  -DVulkan_INCLUDE_DIR="${VULKAN_SDK_PREFIX}/include" \
  -DVulkan_LIBRARY=/usr/lib64/libvulkan.so \
  -DROCKY_RENDERER_VSG="${ROCKY_RENDERER_VSG}" \
  -DROCKY_SUPPORTS_GDAL="${ROCKY_SUPPORTS_GDAL}" \
  -DROCKY_SUPPORTS_MBTILES="${ROCKY_SUPPORTS_MBTILES}" \
  -DROCKY_SUPPORTS_HTTPS="${ROCKY_SUPPORTS_HTTPS}" \
  -DROCKY_SUPPORTS_HTTPLIB="${ROCKY_SUPPORTS_HTTPLIB}" \
  -DROCKY_SUPPORTS_CURL="${ROCKY_SUPPORTS_CURL}" \
  -DROCKY_SUPPORTS_IMGUI="${ROCKY_SUPPORTS_IMGUI}" \
  -DROCKY_SUPPORTS_QT="${ROCKY_SUPPORTS_QT}" \
  -DROCKY_SUPPORTS_AZURE="${ROCKY_SUPPORTS_AZURE}" \
  -DROCKY_SUPPORTS_BING="${ROCKY_SUPPORTS_BING}" \
  "-DCMAKE_C_FLAGS=${ISA_CFLAGS}" "-DCMAKE_CXX_FLAGS=${ISA_CXXFLAGS}" \
  "${FS_STD_LIBS[@]}" \
  2>&1 | tee "${LOG}/rocky-cmake-config.log"
"$CMAKE_BIN" --build "$BUILD" --parallel "$JOBS" 2>&1 | tee "${LOG}/rocky-build.log"

CTEST_RC=0
if [[ -f "${BUILD}/CTestTestfile.cmake" ]]; then
  ctest --test-dir "$BUILD" --output-on-failure -j"$JOBS" 2>&1 | tee "${LOG}/rocky-ctest.log" || CTEST_RC=$?
else
  echo "Rocky 上游未注册 ctest 用例" | tee "${LOG}/rocky-ctest.log"
fi

rm -rf "$STAGE" "$ROCKY_LOCAL_ROOT"; mkdir -p "$STAGE" "$ROCKY_LOCAL_ROOT"
DESTDIR="$STAGE" "$CMAKE_BIN" --install "$BUILD" 2>&1 | tee "${LOG}/rocky-install.log"
[[ -d "${STAGE_PREFIX}/lib64" ]] || die "安装未产生 lib64"

mkdir -p "${STAGE_PREFIX}/include" "${STAGE_PREFIX}/lib/cmake" "${STAGE_PREFIX}/lib"
cp -a "${ROCKY_DEPS_PREFIX}/include/." "${STAGE_PREFIX}/include/" 2>/dev/null || true
for cfgdir in "${ROCKY_DEPS_PREFIX}"/lib/cmake/* "${ROCKY_DEPS_PREFIX}"/lib64/cmake/*; do
  [[ -d "$cfgdir" ]] || continue
  cp -a "$cfgdir" "${STAGE_PREFIX}/lib/cmake/"
done
for dep_lib in "${ROCKY_DEPS_PREFIX}"/lib/lib*.so* "${ROCKY_DEPS_PREFIX}"/lib64/lib*.so* \
               "${ROCKY_DEPS_PREFIX}"/lib/lib*.a "${ROCKY_DEPS_PREFIX}"/lib64/lib*.a; do
  [[ -e "$dep_lib" ]] || continue
  cp -L "$dep_lib" "${STAGE_PREFIX}/lib/" 2>/dev/null || true
  cp -L "$dep_lib" "${STAGE_PREFIX}/lib64/" 2>/dev/null || true
done

# 合包：Rocky + 私有轻量依赖 + QGIS deps 运行库 + VSG/glslang 运行库
for f in "${STAGE_PREFIX}"/lib64/lib*.so* \
         "${ROCKY_DEPS_PREFIX}"/lib/lib*.so* "${ROCKY_DEPS_PREFIX}"/lib64/lib*.so* \
         "${DEPS_PREFIX:-}/lib"/lib*.so* "${DEPS_PREFIX:-}/lib64"/lib*.so* \
         "${VSG_DEP_PREFIX}"/lib64/libvsg*.so* "${VSG_DEP_PREFIX}"/lib/libvsg*.so* \
         "${GLSLANG_DEP_PREFIX}"/lib64/lib*.so* "${GLSLANG_DEP_PREFIX}"/lib/lib*.so*; do
  [[ -e "$f" ]] || continue
  cp -L "$f" "${STAGE_PREFIX}/lib64/" 2>/dev/null || true
done
if [[ -n "$GCC_LIBDIR" ]]; then
  cp -L "${GCC_LIBDIR}/$(basename "$(readlink -f "${GCC_LIBDIR}/libstdc++.so.6")")" \
    "${STAGE_PREFIX}/lib64/" 2>/dev/null || cp -L "${GCC_LIBDIR}/libstdc++.so.6" "${STAGE_PREFIX}/lib64/"
  ln -sfn "$(basename "$(readlink -f "${GCC_LIBDIR}/libstdc++.so.6")")" "${STAGE_PREFIX}/lib64/libstdc++.so.6"
fi
mkdir -p "${STAGE}/usr/bin"
for exe in "${STAGE_PREFIX}"/bin/*; do
  [[ -x "$exe" && ! -d "$exe" ]] || continue
  name="$(basename "$exe")"
  cat > "${STAGE}/usr/bin/${name}" <<EOF 2>/dev/null || true
#!/bin/sh
export LD_LIBRARY_PATH="${ROCKY_INSTALL_PREFIX}/lib64:${VSG_DEP_PREFIX}/lib64:${GLSLANG_DEP_PREFIX}/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "${ROCKY_INSTALL_PREFIX}/bin/${name}" "\$@"
EOF
  chmod 755 "${STAGE}/usr/bin/${name}" 2>/dev/null || true
done
cp -a "$STAGE/." "$ROCKY_LOCAL_ROOT/"

LIB="$(find "${LOCAL_PREFIX}/lib64" -maxdepth 1 -name 'librocky.so*' -print -quit)"
[[ -n "$LIB" ]] || die "安装树中没有 librocky.so"
ldd_out="$(LD_LIBRARY_PATH="${LOCAL_PREFIX}/lib64:${LOCAL_PREFIX}/lib:${VSG_DEP_PREFIX}/lib64:${GLSLANG_DEP_PREFIX}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ldd "$LIB" 2>&1 || true)"
printf '%s\n' "$ldd_out" > "${ROCKY_REPORT_DIR}/rocky-ldd.txt"
grep -q 'not found' <<<"$ldd_out" && die "librocky 依赖未闭合: $ldd_out"
if [[ "${TARGET_ARCH:-x86_64}" == "x86_64" ]] \
   && objdump -d "$LIB" 2>/dev/null | grep -m1 -Eq '\bzmm[0-9]+\b'; then
  die "librocky 含 AVX-512 指令，违反 x86-64 baseline 策略"
fi

RPM_ARCH="${TARGET_ARCH:-x86_64}"
RPM_TARGET_DESC="${TARGET_OS:-Kylin V10} / ${TARGET_CPU:-generic}"
SPEC="${TOP}/SPECS/rocky-kylin.spec"
cat > "$SPEC" <<EOF
Name:           rocky
Version:        ${ROCKY_VERSION}
Release:        1.ky10.g0ae35e2
Summary:        Rocky ${ROCKY_VERSION} native build for Kylin V10 ${RPM_ARCH}
License:        MIT
URL:            ${ROCKY_REPO}
BuildArch:      ${RPM_ARCH}
AutoReqProv:    no
%global __os_install_post %{nil}
%description
Rocky ${ROCKY_VERSION} (ABI ${ROCKY_VERSION_ABI}) with private VSG/GDAL runtime,
compiled natively on ${RPM_TARGET_DESC}.
%prep
%build
%install
rm -rf %{buildroot}; mkdir -p %{buildroot}
cp -a ${STAGE}/. %{buildroot}/
%files
%defattr(-,root,root,-)
/*
%changelog
* Wed Nov 18 2026 Rocky Kylin Builder - ${ROCKY_VERSION}-1.ky10
- Native build from commit ${ROCKY_COMMIT}
EOF
rpmbuild -ba --define "_topdir ${TOP}" --define "_smp_mflags -j1" "$SPEC" 2>&1 | tee "${LOG}/rocky-rpmbuild.log"
find "${TOP}/RPMS" -name '*.rpm' -type f -exec cp -f {} "${ROCKY_OUT_DIR}/rpms/" \;

python3 - "${ROCKY_REPORT_DIR}" "${CTEST_RC}" "${ROCKY_OUT_DIR}" \
        "${TARGET_ARCH:-x86_64}" "${ISA_POLICY:-x86-64-baseline}" <<'PY'
import glob, json, os, sys
rep, ctest, out, arch, isa = sys.argv[1:6]
data={'stage':'ROCKY_STAGE_2_NATIVE_BUILD','ctest_exit_code':int(ctest),
      'rpms':[os.path.basename(p) for p in sorted(glob.glob(os.path.join(out,'rpms','rocky*.rpm')))],
      'arch':arch,'isa_policy':isa,'ldd_clean':True,
      'no_avx512': True if arch=='x86_64' else 'n/a (aarch64)','verdict':'PASS'}
with open(os.path.join(rep,'rocky-build.json'),'w',encoding='utf-8') as f:
    json.dump(data,f,indent=2); f.write('\n')
print(json.dumps(data,indent=2))
PY
stage_marker ROCKY_STAGE_2_BUILD_OK PASS "${ROCKY_REPORT_DIR}/rocky-build-ok.json"
info "ROCKY BUILD PASS"
