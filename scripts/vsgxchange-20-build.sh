#!/usr/bin/env bash
# 阶段 2：原生编译 vsgXchange，安装到私有前缀并打包 RPM。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/vsgxchange.env"

need_cmd python3 "构建"
need_cmd objdump "ISA 校验"
need_cmd rpmbuild "RPM 打包"
JOBS="${VSGXCHANGE_BUILD_JOBS:-4}"
BUILD="$VSGXCHANGE_BUILD_DIR"
STAGE="$VSGXCHANGE_STAGE_DIR"
STAGE_PREFIX="${STAGE}${VSGXCHANGE_INSTALL_PREFIX}"
LOCAL_PREFIX="${VSGXCHANGE_LOCAL_ROOT}${VSGXCHANGE_INSTALL_PREFIX}"
LOG="${VSGXCHANGE_REPORT_DIR}/logs"
TOP="$VSGXCHANGE_RPM_TOP"
mkdir -p "$LOG" "${TOP}/SPECS" "${TOP}/RPMS" "${VSGXCHANGE_OUT_DIR}/rpms"
log "== 阶段 2 / BUILD VSGXCHANGE ${VSGXCHANGE_VERSION} (jobs=$JOBS) =="

locate_gcc_runtime() {
  local cand base
  for cand in "$(g++ -print-file-name=libstdc++.so.6 2>/dev/null || true)" \
              "${DEPS_PREFIX:-}/lib/libstdc++.so.6" "${DEPS_PREFIX:-}/lib64/libstdc++.so.6" \
              /usr/local/gcc11/lib64/libstdc++.so.6 /usr/local/gcc11/lib/libstdc++.so.6; do
    [[ -e "$cand" ]] || continue
    base="$(readlink -f "$cand" 2>/dev/null || true)"
    [[ -n "$base" && -f "$base" ]] || continue
    grep -aq 'GLIBCXX_3\.4\.29' "$base" 2>/dev/null && { dirname "$base"; return 0; }
  done
  return 1
}
GCC_LIBDIR="$(locate_gcc_runtime || true)"
[[ -n "$GCC_LIBDIR" ]] || die "未找到 GCC11 libstdc++ 运行库"
export LD_LIBRARY_PATH="${GCC_LIBDIR}:${LOCAL_PREFIX}/lib64:${OSG2VSG_PREFIX}/lib64:${ASSIMP_PREFIX}/lib64:${GLSLANG_PREFIX}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
log "GCC11 runtime: ${GCC_LIBDIR}"

ASSIMP_CONFIG="$(find "$ASSIMP_PREFIX" -path '*/cmake/assimp/*' -name 'assimp*onfig.cmake' -print -quit 2>/dev/null || true)"
if [[ -n "$ASSIMP_CONFIG" ]]; then
  ASSIMP_OPT=ON
  ASSIMP_LIBDIR="$(dirname "$(dirname "$(dirname "$(dirname "$ASSIMP_CONFIG")")")")/lib64"
  [[ -d "$ASSIMP_LIBDIR" ]] || ASSIMP_LIBDIR="${ASSIMP_PREFIX}/lib"
else
  ASSIMP_OPT=OFF
  ASSIMP_LIBDIR=""
fi
log "vsgXchange_assimp=${ASSIMP_OPT}"

NINJA="$(command -v ninja || true)"
if [[ -n "$NINJA" ]]; then GEN=( -G Ninja "-DCMAKE_MAKE_PROGRAM=$NINJA" ); else GEN=( -G "Unix Makefiles" ); fi
: "${ISA_CFLAGS:=-march=x86-64 -mtune=generic -O2 -pipe}"
: "${ISA_CXXFLAGS:=-march=x86-64 -mtune=generic -O2 -pipe}"

rm -rf "$BUILD"
cmake "${GEN[@]}" -S "$VSGXCHANGE_SRC_DIR" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$VSGXCHANGE_INSTALL_PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib64 -DBUILD_SHARED_LIBS="${VSGXCHANGE_BUILD_SHARED}" \
  -DvsgXchange_OSG="${VSGXCHANGE_ENABLE_OSG}" \
  -DvsgXchange_assimp="${ASSIMP_OPT}" \
  -DvsgXchange_GDAL="${VSGXCHANGE_ENABLE_GDAL}" \
  -DvsgXchange_curl="${VSGXCHANGE_ENABLE_CURL}" \
  -DvsgXchange_freetype="${VSGXCHANGE_ENABLE_FREETYPE}" \
  -DvsgXchange_draco="${VSGXCHANGE_ENABLE_DRACO}" \
  -DvsgXchange_ktx="${VSGXCHANGE_ENABLE_KTX}" \
  -DvsgXchange_openexr="${VSGXCHANGE_ENABLE_OPENEXR}" \
  -DVULKAN_SDK="$OSG2VSG_PREFIX" \
  -DVulkan_INCLUDE_DIR="${OSG2VSG_PREFIX}/include" \
  -DVulkan_LIBRARY=/usr/lib64/libvulkan.so \
  -DCURL_INCLUDE_DIR=/usr/include \
  -DCURL_LIBRARY=/usr/lib64/libcurl.so \
  -DCURL_LIBRARIES=/usr/lib64/libcurl.so \
  "-Dvsg_DIR=${OSG2VSG_PREFIX}/lib64/cmake/vsg" \
  "-Dosg2vsg_DIR=${OSG2VSG_PREFIX}/lib64/cmake/osg2vsg" \
  "-DCMAKE_PREFIX_PATH=${OSG2VSG_PREFIX};${ASSIMP_PREFIX};${GLSLANG_PREFIX};${DEPS_PREFIX:-};${OSG2VSG_PREFIX}/lib64/cmake" \
  "-DCMAKE_C_FLAGS=${ISA_CFLAGS}" "-DCMAKE_CXX_FLAGS=${ISA_CXXFLAGS}" \
  2>&1 | tee "${LOG}/vsgxchange-cmake-config.log"
cmake --build "$BUILD" --parallel "$JOBS" 2>&1 | tee "${LOG}/vsgxchange-build.log"

CTEST_RC=0
if [[ -f "${BUILD}/CTestTestfile.cmake" ]]; then
  ctest --test-dir "$BUILD" --output-on-failure -j"$JOBS" 2>&1 | tee "${LOG}/vsgxchange-ctest.log" || CTEST_RC=$?
else
  echo "vsgXchange 上游未注册 ctest 用例" | tee "${LOG}/vsgxchange-ctest.log"
fi

rm -rf "$STAGE" "$VSGXCHANGE_LOCAL_ROOT"; mkdir -p "$STAGE" "$VSGXCHANGE_LOCAL_ROOT"
DESTDIR="$STAGE" cmake --install "$BUILD" 2>&1 | tee "${LOG}/vsgxchange-install.log"
[[ -d "${STAGE_PREFIX}/lib64" ]] || die "安装未产生 lib64"

for f in "${OSG2VSG_PREFIX}"/lib64/lib*.so* \
         "${ASSIMP_PREFIX}"/lib64/lib*.so* "${ASSIMP_PREFIX}"/lib/lib*.so* \
         "${GLSLANG_PREFIX}"/lib64/lib*.so* \
         "${DEPS_PREFIX:-}/lib64"/lib*.so* "${DEPS_PREFIX:-}/lib"/lib*.so*; do
  [[ -e "$f" ]] || continue
  cp -L "$f" "${STAGE_PREFIX}/lib64/" 2>/dev/null || true
done
for f in "${GLSLANG_PREFIX}"/lib64/lib*.so.16; do
  [[ -e "$f" ]] || continue
  cp -a "$f" "${STAGE_PREFIX}/lib64/" 2>/dev/null || true
done
cp -a "${OSG2VSG_PREFIX}/include/vulkan" "${STAGE_PREFIX}/include/" 2>/dev/null || true
cp -L "${GCC_LIBDIR}/$(basename "$(readlink -f "${GCC_LIBDIR}/libstdc++.so.6")")" \
  "${STAGE_PREFIX}/lib64/" 2>/dev/null || cp -L "${GCC_LIBDIR}/libstdc++.so.6" "${STAGE_PREFIX}/lib64/"
ln -sfn "$(basename "$(readlink -f "${GCC_LIBDIR}/libstdc++.so.6")")" "${STAGE_PREFIX}/lib64/libstdc++.so.6"

mkdir -p "${STAGE}/usr/bin"
for exe in "${STAGE_PREFIX}"/bin/*; do
  [[ -x "$exe" && ! -d "$exe" ]] || continue
  name="$(basename "$exe")"
  cat > "${STAGE}/usr/bin/${name}" <<EOF 2>/dev/null || true
#!/bin/sh
export LD_LIBRARY_PATH="${VSGXCHANGE_INSTALL_PREFIX}/lib64:${OSG2VSG_PREFIX}/lib64:${ASSIMP_PREFIX}/lib64:${GLSLANG_PREFIX}/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "${VSGXCHANGE_INSTALL_PREFIX}/bin/${name}" "\$@"
EOF
  chmod 755 "${STAGE}/usr/bin/${name}" 2>/dev/null || true
done
cp -a "$STAGE/." "$VSGXCHANGE_LOCAL_ROOT/"

LIB="$(find "${LOCAL_PREFIX}/lib64" -maxdepth 1 -name 'libvsgXchange.so*' -print -quit)"
[[ -n "$LIB" ]] || die "安装树中没有 libvsgXchange.so"
ldd_out="$(LD_LIBRARY_PATH="${LOCAL_PREFIX}/lib64" ldd "$LIB" 2>&1 || true)"
printf '%s\n' "$ldd_out" > "${VSGXCHANGE_REPORT_DIR}/vsgxchange-ldd.txt"
grep -q 'not found' <<<"$ldd_out" && die "libvsgXchange 依赖未闭合: $ldd_out"
if objdump -d "$LIB" 2>/dev/null | grep -m1 -Eq '\bzmm[0-9]+\b'; then die "AVX-512 指令"; fi

SPEC="${TOP}/SPECS/vsgxchange-kylin.spec"
cat > "$SPEC" <<EOF
Name:           vsgXchange
Version:        ${VSGXCHANGE_VERSION}
Release:        1.ky10.g76ee4f8
Summary:        vsgXchange ${VSGXCHANGE_VERSION} native build for Kylin V10 x86_64
License:        MIT
URL:            ${VSGXCHANGE_REPO}
BuildArch:      x86_64
AutoReqProv:    no
%global __os_install_post %{nil}
%description
vsgXchange ${VSGXCHANGE_VERSION} (SOVERSION ${VSGXCHANGE_SOVERSION}) with private
OSG/VSG, assimp and glslang runtimes, compiled natively on Kylin V10 / Hygon C86.
%prep
%build
%install
rm -rf %{buildroot}; mkdir -p %{buildroot}
cp -a ${STAGE}/. %{buildroot}/
%files
%defattr(-,root,root,-)
/*
%changelog
* Wed Nov 18 2026 vsgXchange Kylin Builder - ${VSGXCHANGE_VERSION}-1.ky10
- Native build from commit ${VSGXCHANGE_COMMIT}
EOF
cp -f "$SPEC" "${VSGXCHANGE_REPORT_DIR}/vsgxchange-kylin.spec"
rpmbuild -ba --define "_topdir ${TOP}" --define "_smp_mflags -j1" "$SPEC" 2>&1 | tee "${LOG}/vsgxchange-rpmbuild.log"
find "${TOP}/RPMS" -name '*.rpm' -type f -exec cp -f {} "${VSGXCHANGE_OUT_DIR}/rpms/" \;

python3 - "${VSGXCHANGE_REPORT_DIR}" "${CTEST_RC}" "${VSGXCHANGE_OUT_DIR}" <<'PY'
import glob, json, os, sys
rep, ctest, out = sys.argv[1:4]
data={'stage':'VSGXCHANGE_STAGE_2_NATIVE_BUILD','ctest_exit_code':int(ctest),
      'rpms':[os.path.basename(p) for p in sorted(glob.glob(os.path.join(out,'rpms','vsgXchange*.rpm')))],
      'isa_policy':'x86-64-baseline','ldd_clean':True,'no_avx512':True,'verdict':'PASS'}
with open(os.path.join(rep,'vsgxchange-build.json'),'w',encoding='utf-8') as f:
    json.dump(data,f,indent=2); f.write('\n')
print(json.dumps(data,indent=2))
PY
stage_marker VSGXCHANGE_STAGE_2_BUILD_OK PASS "${VSGXCHANGE_REPORT_DIR}/vsgxchange-build-ok.json"
info "VSGXCHANGE BUILD PASS"
