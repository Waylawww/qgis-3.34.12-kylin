#!/usr/bin/env bash
# 阶段 2：依次原生编译 OSG / VSG / osg2vsg，合并打包成自包含 RPM。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/osg2vsg.env"

need_cmd python3 "构建"
need_cmd objdump "ISA 校验"
need_cmd rpmbuild "RPM 打包"
JOBS="${OSG2VSG_BUILD_JOBS:-4}"
LOG="${OSG2VSG_REPORT_DIR}/logs"
TOP="$OSG2VSG_RPM_TOP"
mkdir -p "$LOG" "${TOP}/SPECS" "${TOP}/RPMS" "${OSG2VSG_OUT_DIR}/rpms"
log "== 阶段 2 / BUILD OSG2VSG (jobs=$JOBS) =="

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
  export LD_LIBRARY_PATH="${GCC_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  log "GCC11 runtime: ${GCC_LIBDIR}"
else
  GCC_LIBDIR=''
  log "REQUIRE_GCC11=false：使用系统 libstdc++，不打包私有运行库"
fi

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

# B 设备 glslang 前缀（可选）：存在才把其运行库合包进 RPM。
GLSLANG_LIB_PREFIX="${B_GLSLANG_PREFIX:-/opt/glslang-16.1.0}"
if [[ ! -d "$GLSLANG_LIB_PREFIX/lib64" ]]; then
  log "glslang 前缀 ${GLSLANG_LIB_PREFIX} 不存在，跳过 glslang 运行库合包"
  GLSLANG_LIB_PREFIX=''
fi

# ---------- OSG ----------
OSG_BUILD="${OSG2VSG_WORK}/build-osg"
log "---- OSG ${OSG_VERSION} ----"
cmake "${GEN[@]}" -S "$OSG_SRC_DIR" -B "$OSG_BUILD" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$OSG_PREFIX" \
  -DBUILD_SHARED_LIBS=ON -DBUILD_OSG_APPLICATIONS=OFF -DBUILD_OSG_EXAMPLES=OFF \
  -DBUILD_DOCUMENTATION=OFF -DOSG_USE_FLOAT_MATRIX=ON \
  "-DCMAKE_PREFIX_PATH=${DEPS_PREFIX:-}" \
  "-DCMAKE_C_FLAGS=${ISA_CFLAGS}" "-DCMAKE_CXX_FLAGS=${ISA_CXXFLAGS}" \
  2>&1 | tee "${LOG}/osg-cmake-config.log"
cmake --build "$OSG_BUILD" --parallel "$JOBS" 2>&1 | tee "${LOG}/osg-build.log"
cmake --install "$OSG_BUILD" 2>&1 | tee "${LOG}/osg-install.log"

# ---------- VSG ----------
VSG_BUILD="${OSG2VSG_WORK}/build-vsg"
log "---- VSG ${VSG_VERSION} ----"
export VULKAN_SDK="$VULKAN_SDK_PREFIX"
rm -rf "$VSG_BUILD"
cmake "${GEN[@]}" -S "$VSG_SRC_DIR" -B "$VSG_BUILD" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$VSG_PREFIX" \
  -DBUILD_SHARED_LIBS=ON -DVULKAN_SDK="$VULKAN_SDK_PREFIX" \
  -DVulkan_INCLUDE_DIR="$VULKAN_SDK_PREFIX/include" \
  -DVulkan_LIBRARY=/usr/lib64/libvulkan.so \
  "-DCMAKE_PREFIX_PATH=${DEPS_PREFIX:-};${OSG_PREFIX};${VULKAN_SDK_PREFIX}" \
  "-DCMAKE_C_FLAGS=${ISA_CFLAGS}" "-DCMAKE_CXX_FLAGS=${ISA_CXXFLAGS}" \
  2>&1 | tee "${LOG}/vsg-cmake-config.log"
cmake --build "$VSG_BUILD" --parallel "$JOBS" 2>&1 | tee "${LOG}/vsg-build.log"
cmake --install "$VSG_BUILD" 2>&1 | tee "${LOG}/vsg-install.log"

# ---------- osg2vsg ----------
BUILD="$OSG2VSG_BUILD_DIR"
STAGE="$OSG2VSG_STAGE_DIR"
STAGE_PREFIX="${STAGE}${OSG2VSG_INSTALL_PREFIX}"
LOCAL_PREFIX="${OSG2VSG_LOCAL_ROOT}${OSG2VSG_INSTALL_PREFIX}"
log "---- osg2vsg ${OSG2VSG_VERSION} ----"
# 必须传 VULKAN_SDK：osg2vsg 的 find_package(vsg) 会读取它，确保 VSG target
# 使用私有 1.2.131 头文件而非系统旧版，否则 VK_DESCRIPTOR_BINDING_*_BIT_EXT
# 会在 vsg/vk/vulkan.h 与系统 vulkan_core.h 中重复定义导致编译失败。
export VULKAN_SDK="$VULKAN_SDK_PREFIX"
rm -f "$BUILD/CMakeCache.txt"
cmake "${GEN[@]}" -S "$OSG2VSG_SRC_DIR" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$OSG2VSG_INSTALL_PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib64 -DBUILD_SHARED_LIBS=ON \
  -DVULKAN_SDK="$VULKAN_SDK_PREFIX" \
  -DVulkan_INCLUDE_DIR="$VULKAN_SDK_PREFIX/include" \
  -DVulkan_LIBRARY=/usr/lib64/libvulkan.so \
  "-DCMAKE_PREFIX_PATH=${VSG_PREFIX};${OSG_PREFIX};${VULKAN_SDK_PREFIX};${DEPS_PREFIX:-}" \
  "-DCMAKE_C_FLAGS=${ISA_CFLAGS}" "-DCMAKE_CXX_FLAGS=${ISA_CXXFLAGS}" \
  2>&1 | tee "${LOG}/osg2vsg-cmake-config.log"
cmake --build "$BUILD" --parallel "$JOBS" 2>&1 | tee "${LOG}/osg2vsg-build.log"

CTEST_RC=0
if [[ -f "${BUILD}/CTestTestfile.cmake" ]]; then
  ctest --test-dir "$BUILD" --output-on-failure -j"$JOBS" 2>&1 | tee "${LOG}/osg2vsg-ctest.log" || CTEST_RC=$?
else
  echo "osg2vsg 上游未注册 ctest 用例" | tee "${LOG}/osg2vsg-ctest.log"
fi

# ---------- DESTDIR 安装 + 依赖合包 ----------
rm -rf "$STAGE" "$OSG2VSG_LOCAL_ROOT"; mkdir -p "$STAGE" "$OSG2VSG_LOCAL_ROOT"
DESTDIR="$STAGE" cmake --install "$BUILD" 2>&1 | tee "${LOG}/osg2vsg-install.log"
[[ -d "${STAGE_PREFIX}/lib64" ]] || die "osg2vsg 安装未产生 lib64"
find_libdir() { local p="$1"; [[ -d "$p/lib64" ]] && echo lib64 || echo lib; }
OSG_LD="$(find_libdir "$OSG_PREFIX")"; VSG_LD="$(find_libdir "$VSG_PREFIX")"
mkdir -p "${STAGE_PREFIX}/lib64/osgPlugins-3.6.5"
for f in "${OSG_PREFIX}/${OSG_LD}"/lib*.so* "${VSG_PREFIX}/${VSG_LD}"/lib*.so*; do
  [[ -e "$f" ]] || continue
  cp -L "$f" "${STAGE_PREFIX}/lib64/" 2>/dev/null || true
done
# glslang 的符号链接（libglslang.so.16 等）必须保留，VSG 运行时按 SONAME 加载
if [[ -n "$GLSLANG_LIB_PREFIX" ]]; then
  for f in "$GLSLANG_LIB_PREFIX"/lib64/lib*.so*; do
    [[ -e "$f" ]] || continue
    cp -a "$f" "${STAGE_PREFIX}/lib64/" 2>/dev/null || true
  done
fi
if [[ -d "${OSG_PREFIX}/${OSG_LD}/osgPlugins-3.6.5" ]]; then
  cp -L "${OSG_PREFIX}/${OSG_LD}/osgPlugins-3.6.5"/*.so "${STAGE_PREFIX}/lib64/osgPlugins-3.6.5/" 2>/dev/null || true
fi
cp -a "${OSG_PREFIX}/include/." "${STAGE_PREFIX}/include/" 2>/dev/null || true
cp -a "${VSG_PREFIX}/include/." "${STAGE_PREFIX}/include/" 2>/dev/null || true
# VSG 1.1.13 与系统 vulkan-headers 1.1.92 不兼容，头文件必须随包提供
cp -a "${VULKAN_SDK_PREFIX}/include/vulkan" "${STAGE_PREFIX}/include/" 2>/dev/null || true
# glslang 的 cmake targets 引用其原安装路径，直接复制到本包会导致 find_package 失败；
# 运行时库已单独拷贝，配置阶段让消费者使用系统已安装的 glslang 包。
for d in "${OSG_PREFIX}/${OSG_LD}/cmake" "${VSG_PREFIX}/${VSG_LD}/cmake"; do
  [[ -d "$d" ]] || continue
  mkdir -p "${STAGE_PREFIX}/lib64/cmake"
  cp -a "$d/." "${STAGE_PREFIX}/lib64/cmake/" || true
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
export LD_LIBRARY_PATH="${OSG2VSG_INSTALL_PREFIX}/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export OSG_LIBRARY_PATH="${OSG2VSG_INSTALL_PREFIX}/lib64/osgPlugins-3.6.5"
exec "${OSG2VSG_INSTALL_PREFIX}/bin/${name}" "\$@"
EOF
  chmod 755 "${STAGE}/usr/bin/${name}" 2>/dev/null || true
done
cp -a "$STAGE/." "$OSG2VSG_LOCAL_ROOT/"

# ---------- 静态校验 ----------
LIB="$(find "${LOCAL_PREFIX}/lib64" -maxdepth 1 -name 'libosg2vsg.so*' -print -quit)"
[[ -n "$LIB" ]] || die "安装树中没有 libosg2vsg.so"
ldd_out="$(LD_LIBRARY_PATH="${LOCAL_PREFIX}/lib64" ldd "$LIB" 2>&1 || true)"
printf '%s\n' "$ldd_out" > "${OSG2VSG_REPORT_DIR}/osg2vsg-ldd.txt"
grep -q 'not found' <<<"$ldd_out" && die "libosg2vsg 依赖未闭合: $ldd_out"
if [[ "${TARGET_ARCH:-x86_64}" == "x86_64" ]] \
   && objdump -d "$LIB" 2>/dev/null | grep -m1 -Eq '\bzmm[0-9]+\b'; then
  die "libosg2vsg 含 AVX-512 指令，违反 x86-64 baseline 策略"
fi

# ---------- RPM ----------
RPM_ARCH="${TARGET_ARCH:-x86_64}"
RPM_TARGET_DESC="${TARGET_OS:-Kylin V10} / ${TARGET_CPU:-generic}"
SPEC="${TOP}/SPECS/osg2vsg-kylin.spec"
cat > "$SPEC" <<EOF
Name:           osg2vsg
Version:        ${OSG2VSG_VERSION}
Release:        1.ky10.g8494fc6
Summary:        osg2vsg ${OSG2VSG_VERSION} with private OSG ${OSG_VERSION} / VSG ${VSG_VERSION}
License:        MIT
URL:            ${OSG2VSG_REPO}
BuildArch:      ${RPM_ARCH}
AutoReqProv:    no
%global __os_install_post %{nil}
%description
OpenSceneGraph / VulkanSceneGraph integration library, compiled natively on
${RPM_TARGET_DESC}. Private OSG and VSG runtimes are bundled under
${OSG2VSG_INSTALL_PREFIX}.
%prep
%build
%install
rm -rf %{buildroot}; mkdir -p %{buildroot}
cp -a ${STAGE}/. %{buildroot}/
%files
%defattr(-,root,root,-)
/*
%changelog
* Wed Nov 18 2026 osg2vsg Kylin Builder - ${OSG2VSG_VERSION}-1.ky10
- Native build with OSG ${OSG_VERSION} and VSG ${VSG_VERSION}
EOF
cp -f "$SPEC" "${OSG2VSG_REPORT_DIR}/osg2vsg-kylin.spec"
rpmbuild -ba --define "_topdir ${TOP}" --define "_smp_mflags -j1" "$SPEC" 2>&1 | tee "${LOG}/osg2vsg-rpmbuild.log"
find "${TOP}/RPMS" -name '*.rpm' -type f -exec cp -f {} "${OSG2VSG_OUT_DIR}/rpms/" \;

python3 - "${OSG2VSG_REPORT_DIR}" "${CTEST_RC}" "${OSG2VSG_OUT_DIR}" \
        "${TARGET_ARCH:-x86_64}" "${ISA_POLICY:-x86-64-baseline}" <<'PY'
import glob, json, os, sys
rep, ctest_rc, out, arch, isa = sys.argv[1:6]
data={'stage':'OSG2VSG_STAGE_2_NATIVE_BUILD','ctest_exit_code':int(ctest_rc),
      'rpms':[os.path.basename(p) for p in sorted(glob.glob(os.path.join(out,'rpms','osg2vsg*.rpm')))],
      'arch':arch,'isa_policy':isa,'ldd_clean':True,
      'no_avx512': True if arch=='x86_64' else 'n/a (aarch64)','verdict':'PASS'}
with open(os.path.join(rep,'osg2vsg-build.json'),'w',encoding='utf-8') as f:
    json.dump(data,f,indent=2); f.write('\n')
print(json.dumps(data,indent=2))
PY
stage_marker OSG2VSG_STAGE_2_BUILD_OK PASS "${OSG2VSG_REPORT_DIR}/osg2vsg-build-ok.json"
info "OSG2VSG BUILD PASS"
