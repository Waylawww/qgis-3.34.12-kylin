#!/usr/bin/env bash
# 阶段 4：RPM 产物静态校验（元数据 / 内容 / 依赖 / ldd / ISA / GLIBC / 3D / PyQGIS）
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
need_cmd rpm "RPM 元数据校验"
need_cmd rpm2cpio "解包校验"
need_cmd cpio "解包校验"
need_cmd ldd "动态链接校验"
need_cmd sha256sum "产物指纹"

RPM_DIR="${OUT_DIR}/rpms"
ROOT="${WORK_DIR}/rpm-verify/root"
mkdir -p "${REPORT_DIR}/rpm" "${ROOT}"
shopt -s nullglob
RPMS=("${RPM_DIR}"/*.rpm)
(( ${#RPMS[@]} > 0 )) || die "没有可校验的 RPM：${RPM_DIR}"

info "== 阶段 4 / VERIFY RPM (${#RPMS[@]} 个包) =="

# --- 1. 元数据 ---------------------------------------------------------------
: > "${REPORT_DIR}/rpm/checksums.sha256"
for f in "${RPMS[@]}"; do
  b="$(basename "$f")"
  rpm -qpi "$f"  > "${REPORT_DIR}/rpm/${b}.info.txt"
  rpm -qpl "$f"  > "${REPORT_DIR}/rpm/${b}.files.txt"
  rpm -qpR "$f"  > "${REPORT_DIR}/rpm/${b}.requires.txt"
  rpm -qp --scripts "$f" > "${REPORT_DIR}/rpm/${b}.scripts.txt"
  rpm -K "$f"    > "${REPORT_DIR}/rpm/${b}.sig.txt" 2>&1 || true
  ver="$(rpm -qp --qf '%{VERSION}' "$f")"
  arch="$(rpm -qp --qf '%{ARCH}' "$f")"
  name="$(rpm -qp --qf '%{NAME}' "$f")"
  [[ "${ver}" == "${QGIS_VERSION}" ]] || die "${b}: VERSION=${ver}，不是 ${QGIS_VERSION}"
  [[ "${arch}" == "x86_64" ]] || die "${b}: ARCH=${arch}，不是 x86_64"
  sha256sum "$f" >> "${REPORT_DIR}/rpm/checksums.sha256"
  log "  ${b}: ${name}-${ver}.${arch}  $(stat -c %s "$f") bytes"
done

# --- 2. 解包 -----------------------------------------------------------------
for f in "${RPMS[@]}"; do
  ( cd "${ROOT}" && rpm2cpio "$f" | cpio -idm --quiet )
done

# --- 3. 强制交付项 -----------------------------------------------------------
test -n "$(find "${ROOT}" -name 'libqgis_3d.so.*' -print -quit)" || die "RPM 中缺少 libqgis_3d.so.*（3D 未启用）"
test -n "$(find "${ROOT}" -path '*/qgis/core/__init__.py' -print -quit)" || die "RPM 中缺少 PyQGIS"
test -x "${ROOT}/usr/bin/qgis" || die "RPM 中缺少 /usr/bin/qgis（Desktop）"
test -x "${ROOT}/usr/bin/qgis_process" || die "RPM 中缺少 /usr/bin/qgis_process"
test -n "$(find "${ROOT}" -name 'libqgis_analysis.so.*' -print -quit)" || die "缺少 qgis analysis 库"

# 严禁把 Debian/Ubuntu 体系的东西塞进 RPM。
# 注意：x86_64-linux-gnu 是 Python C 扩展的标准 arch 后缀
# （如 PyQt5/sip.cpython-37m-x86_64-linux-gnu.so），所有 Linux 发行版（含
# 麒麟/RHEL）都这样命名，并非 Debian 专属；因此只匹配真正的 Debian 库目录
# （路径中间的 */x86_64-linux-gnu/*），避免误伤合法的 .so 文件名后缀。
if find "${ROOT}" \( -name '*.deb' -o -name 'dpkg*' -o -path '*/x86_64-linux-gnu/*' \) -print -quit | grep -q .; then
  die "检测到 Debian/Ubuntu 体系文件：本工程要求麒麟原生 RPM 依赖体系"
fi
if grep -RIl 'ubuntu\|debian' "${REPORT_DIR}/rpm/"*.requires.txt 2>/dev/null | grep -q .; then
  warn "Requires 中出现 ubuntu/debian 字样，请人工核对是否为合法的包描述"
fi

# --- 4. 动态链接 -------------------------------------------------------------
# 本 RPM 自带私有依赖（Qt/PROJ/GEOS/GDAL），不在系统 ldconfig 路径里，
# 解包校验必须显式注入解包根内的私有库目录，否则 ldd 会把它们全部误报成
# "not found"。运行时由 /usr/bin/qgis wrapper 做同样的注入。
export LD_LIBRARY_PATH="${ROOT}/opt/qgis-${QGIS_VERSION}/deps/lib:${ROOT}/opt/qgis-${QGIS_VERSION}/deps/lib64:${ROOT}/opt/qgis-${QGIS_VERSION}/lib:${LD_LIBRARY_PATH:-}"
LDD_LOG="${REPORT_DIR}/rpm/ldd.txt"
: > "${LDD_LOG}"
missing=0
while IFS= read -r -d '' f; do
  echo "### ${f#"${ROOT}"}" >> "${LDD_LOG}"
  ldd -r "$f" >> "${LDD_LOG}" 2>&1 || true
  if grep -q 'not found' <<<"$(ldd "$f" 2>&1 || true)"; then
    warn "ldd 有未解析库: ${f#"${ROOT}"}"
    missing=$((missing+1))
  fi
done < <(find "${ROOT}" -type f \( -name 'libqgis*.so.*' -o -path '*/bin/qgis*' \) -print0)
[[ "${missing}" -eq 0 ]] || die "${missing} 个 ELF 存在 'not found' 依赖；请用 dnf repoquery 补齐原生 RPM 依赖"

# --- 5. ISA / ABI ------------------------------------------------------------
bash "${REPO_ROOT}/scripts/check-isa.sh" "${ROOT}"

# --- 6. 汇总 -----------------------------------------------------------------
python3 - "${REPORT_DIR}" "${QGIS_VERSION}" "${#RPMS[@]}" "${RPMS[@]}" <<'PY'
import hashlib, json, os, sys
rep, version, count, *rpms = sys.argv[1:]
out = {
    "qgis_version": version,
    "rpm_count": int(count),
    "rpms": [{"name": os.path.basename(p), "bytes": os.path.getsize(p),
              "sha256": hashlib.sha256(open(p, "rb").read()).hexdigest()} for p in rpms],
    "checks": {
        "version_lock": "PASS", "arch_x86_64": "PASS", "3d_library": "PASS",
        "pyqgis": "PASS", "desktop_binary": "PASS", "ldd": "PASS",
        "isa_glibc": json.load(open(os.path.join(rep, "isa-report.json"), encoding="utf-8"))["verdict"],
    },
    "verdict": "PASS",
}
with open(os.path.join(rep, "rpm-verification.json"), "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
print(json.dumps(out, ensure_ascii=False, indent=2))
PY

stage_marker STAGE_B_STATIC_VERIFY_OK PASS "${REPORT_DIR}/stages/stage-b-static.json"
info "VERIFY RPM PASS"
