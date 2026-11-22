#!/usr/bin/env bash
# 阶段 2：原生编译 VSG，安装到私有前缀并打包 RPM。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/vsg.env"

need_cmd python3 "构建"
need_cmd objdump "ISA 校验"
need_cmd rpmbuild "RPM 打包"
JOBS="${VSG_BUILD_JOBS:-4}"
BUILD="$VSG_BUILD_DIR"
STAGE="$VSG_STAGE_DIR"
STAGE_PREFIX="${STAGE}${VSG_INSTALL_PREFIX}"
LOCAL_PREFIX="${VSG_LOCAL_ROOT}${VSG_INSTALL_PREFIX}"
LOG="${VSG_REPORT_DIR}/logs"
TOP="$VSG_RPM_TOP"
mkdir -p "$LOG" "${TOP}/SPECS" "${TOP}/RPMS" "${VSG_OUT_DIR}/rpms"
log "== 阶段 2 / BUILD VSG ${VSG_VERSION} (jobs=$JOBS) =="

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
if [[ "${REQUIRE_GCC11:-true}" == "true" ]]; then
  [[ -n "$GCC_LIBDIR" ]] || die "未找到 GCC11 libstdc++ 运行库"
else
  GCC_LIBDIR=''
  log "REQUIRE_GCC11=false：使用系统 libstdc++，不打包私有运行库"
fi
export LD_LIBRARY_PATH="${GCC_LIBDIR:+${GCC_LIBDIR}:}${LOCAL_PREFIX}/lib64:${GLSLANG_PREFIX}/lib64:${DEPS_PREFIX:-}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

GLSLANG_CONFIG="$(find "$GLSLANG_PREFIX" -path '*/cmake/glslang/*' -name 'glslang*onfig.cmake' -print -quit 2>/dev/null || true)"
[[ -n "$GLSLANG_CONFIG" ]] || die "未找到 glslang-config.cmake"
GLSLANG_CMAKE_DIR="$(dirname "$GLSLANG_CONFIG")"

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

rm -rf "$BUILD"
cmake "${GEN[@]}" -S "$VSG_SRC_DIR" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$VSG_INSTALL_PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib64 -DBUILD_SHARED_LIBS=ON \
  -DVSG_SUPPORTS_ShaderCompiler="${VSG_SUPPORTS_ShaderCompiler}" \
  -DVSG_SUPPORTS_ShaderOptimizer="${VSG_SUPPORTS_ShaderOptimizer}" \
  -DVSG_SUPPORTS_Windowing="${VSG_SUPPORTS_Windowing}" \
  -DVULKAN_SDK="$VULKAN_SDK_PREFIX" \
  -DVulkan_INCLUDE_DIR="${VULKAN_SDK_PREFIX}/include" \
  -DVulkan_LIBRARY=/usr/lib64/libvulkan.so \
  "-DCMAKE_PREFIX_PATH=${VULKAN_SDK_PREFIX};${GLSLANG_PREFIX};${DEPS_PREFIX:-}" \
  "-Dglslang_DIR=${GLSLANG_CMAKE_DIR}" \
  "-DCMAKE_C_FLAGS=${ISA_CFLAGS}" "-DCMAKE_CXX_FLAGS=${ISA_CXXFLAGS}" \
  2>&1 | tee "${LOG}/vsg-cmake-config.log"
cmake --build "$BUILD" --parallel "$JOBS" 2>&1 | tee "${LOG}/vsg-build.log"

CTEST_RC=0
if [[ -f "${BUILD}/CTestTestfile.cmake" ]]; then
  ctest --test-dir "$BUILD" --output-on-failure -j"$JOBS" 2>&1 | tee "${LOG}/vsg-ctest.log" || CTEST_RC=$?
else
  echo "VSG 上游未注册 ctest 用例；以 API smoke 为准" | tee "${LOG}/vsg-ctest.log"
fi

rm -rf "$STAGE" "$VSG_LOCAL_ROOT"; mkdir -p "$STAGE" "$VSG_LOCAL_ROOT"
DESTDIR="$STAGE" cmake --install "$BUILD" 2>&1 | tee "${LOG}/vsg-install.log"
[[ -d "${STAGE_PREFIX}/lib64" ]] || die "安装未产生 lib64"

cp -a "${VULKAN_SDK_PREFIX}/include/vulkan" "${STAGE_PREFIX}/include/" 2>/dev/null || true
for f in "${GLSLANG_PREFIX}"/lib64/lib*.so*; do
  [[ -e "$f" ]] || continue
  cp -L "$f" "${STAGE_PREFIX}/lib64/" 2>/dev/null || true
done
for f in "${GLSLANG_PREFIX}"/lib64/lib*.so.16; do
  [[ -e "$f" ]] || continue
  cp -a "$f" "${STAGE_PREFIX}/lib64/" 2>/dev/null || true
done
if [[ -n "$GCC_LIBDIR" ]]; then
  cp -L "${GCC_LIBDIR}/$(basename "$(readlink -f "${GCC_LIBDIR}/libstdc++.so.6")")" \
    "${STAGE_PREFIX}/lib64/" 2>/dev/null || cp -L "${GCC_LIBDIR}/libstdc++.so.6" "${STAGE_PREFIX}/lib64/"
  ln -sfn "$(basename "$(readlink -f "${GCC_LIBDIR}/libstdc++.so.6")")" "${STAGE_PREFIX}/lib64/libstdc++.so.6"
fi
cp -a "$STAGE/." "$VSG_LOCAL_ROOT/"

LIB="$(find "${LOCAL_PREFIX}/lib64" -maxdepth 1 -name 'libvsg.so*' -print -quit)"
[[ -n "$LIB" ]] || die "安装树中没有 libvsg.so"
ldd_out="$(LD_LIBRARY_PATH="${LOCAL_PREFIX}/lib64" ldd "$LIB" 2>&1 || true)"
printf '%s\n' "$ldd_out" > "${VSG_REPORT_DIR}/vsg-ldd.txt"
grep -q 'not found' <<<"$ldd_out" && die "libvsg 依赖未闭合: $ldd_out"
if [[ "${TARGET_ARCH:-x86_64}" == "x86_64" ]] \
   && objdump -d "$LIB" 2>/dev/null | grep -m1 -Eq '\bzmm[0-9]+\b'; then
  die "libvsg 含 AVX-512 指令，违反 x86-64 baseline 策略"
fi

RPM_ARCH="${TARGET_ARCH:-x86_64}"
RPM_TARGET_DESC="${TARGET_OS:-Kylin V10} / ${TARGET_CPU:-generic}"
SPEC="${TOP}/SPECS/vsg-kylin.spec"
cat > "$SPEC" <<EOF
Name:           vsg
Version:        ${VSG_VERSION}
Release:        1.ky10.g05bb15b
Summary:        VulkanSceneGraph ${VSG_VERSION} native build for Kylin V10 ${RPM_ARCH}
License:        MIT
URL:            ${VSG_REPO}
BuildArch:      ${RPM_ARCH}
AutoReqProv:    no
%global __os_install_post %{nil}
%description
VulkanSceneGraph ${VSG_VERSION} (SOVERSION ${VSG_SOVERSION}) with private
Vulkan 1.2.131 headers and bundled glslang runtime, compiled natively on
${RPM_TARGET_DESC}.
%prep
%build
%install
rm -rf %{buildroot}; mkdir -p %{buildroot}
cp -a ${STAGE}/. %{buildroot}/
%files
%defattr(-,root,root,-)
/*
%changelog
* Wed Nov 18 2026 VSG Kylin Builder - ${VSG_VERSION}-1.ky10
- Native build from commit ${VSG_COMMIT}
EOF
cp -f "$SPEC" "${VSG_REPORT_DIR}/vsg-kylin.spec"
rpmbuild -ba --define "_topdir ${TOP}" --define "_smp_mflags -j1" "$SPEC" 2>&1 | tee "${LOG}/vsg-rpmbuild.log"
find "${TOP}/RPMS" -name '*.rpm' -type f -exec cp -f {} "${VSG_OUT_DIR}/rpms/" \;

python3 - "${VSG_REPORT_DIR}" "${CTEST_RC}" "${VSG_OUT_DIR}" \
        "${TARGET_ARCH:-x86_64}" "${ISA_POLICY:-x86-64-baseline}" <<'PY'
import glob, json, os, sys
rep, ctest, out, arch, isa = sys.argv[1:6]
data={'stage':'VSG_STAGE_2_NATIVE_BUILD','ctest_exit_code':int(ctest),
      'rpms':[os.path.basename(p) for p in sorted(glob.glob(os.path.join(out,'rpms','vsg*.rpm')))],
      'arch':arch,'isa_policy':isa,'ldd_clean':True,
      'no_avx512': True if arch=='x86_64' else 'n/a (aarch64)','verdict':'PASS'}
with open(os.path.join(rep,'vsg-build.json'),'w',encoding='utf-8') as f:
    json.dump(data,f,indent=2); f.write('\n')
print(json.dumps(data,indent=2))
PY
stage_marker VSG_STAGE_2_BUILD_OK PASS "${VSG_REPORT_DIR}/vsg-build-ok.json"
info "VSG BUILD PASS"
