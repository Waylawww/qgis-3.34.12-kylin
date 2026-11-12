#!/usr/bin/env bash
# 阶段 5：在「全新的、只含目标系统基础镜像」的麒麟 V10 容器里安装 RPM 并运行。
# 这是对 RPM 依赖闭合性 + QGIS 可启动性的验证，但它仍不是 STAGE_C（真实 VM）。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
load_env "${KYLIN_ENV}"
load_env "${DEPS_ENV}"
require_linux_or_container

PM="${KYLIN_PACKAGE_MANAGER}"
[[ "${PM}" == "dnf" || "${PM}" == "yum" || "${PM}" == "microdnf" ]] || die "未知包管理器 ${PM}"
need_cmd "${PM}" "安装原生 RPM 依赖"
need_cmd rpm "校验已安装包"
need_cmd timeout "GUI 启动超时保护"

RPM_DIR="${OUT_DIR}/rpms"
EVID="${OUT_DIR}/evidence"
STAGES="${REPORT_DIR}/stages"
mkdir -p "${EVID}" "${STAGES}"
shopt -s nullglob
RPMS=("${RPM_DIR}"/*.rpm)
(( ${#RPMS[@]} > 0 )) || die "没有可安装的 RPM"

stage_marker STAGE_B2_CONTAINER_RUNTIME_OK FAIL "${STAGES}/stage-b2.json"

info "== 阶段 5 / FRESH CONTAINER INSTALL + RUNTIME =="

# --- 1. 注入确认过的额外软件源 -----------------------------------------------
if [[ -n "${KYLIN_EXTRA_REPO_URLS:-}" ]]; then
  IFS=',' read -ra urls <<< "${KYLIN_EXTRA_REPO_URLS}"
  i=0
  for u in "${urls[@]}"; do
    i=$((i+1))
    curl -fsSL "$u" -o "/etc/yum.repos.d/qgis-extra-${i}.repo"
  done
fi

# --- 2. 从麒麟原生源解析并安装运行期依赖，然后本地安装全部 QGIS RPM -----------
log "安装运行期依赖（验证 Requires 在麒麟源中可解）"
${PM} -y install ${QGIS_RUNTIME_REQUIRES} 2>&1 | tee "${LOG_DIR}/runtime-deps.log"
log "安装 QGIS RPM"
${PM} -y install --nogpgcheck "${RPMS[@]}" 2>&1 | tee "${LOG_DIR}/rpm-install.log"

rpm -qa | grep -iE '^(qgis|python3-qgis)' | sort | tee "${EVID}/installed-qgis-rpms.txt"
rpm -q qgis python3-qgis qgis-devel | tee "${EVID}/rpm-q.txt"
rpm -V qgis python3-qgis qgis-devel 2>&1 | tee "${EVID}/rpm-V.txt" || warn "rpm -V 有差异，请人工审阅"

ldconfig || true

# --- 3. 运行环境 -------------------------------------------------------------
export QT_QPA_PLATFORM=offscreen
export QGIS_PREFIX_PATH=/usr
export PYTHONPATH="${KYLIN_PYTHON3_SITEARCH}${PYTHONPATH:+:${PYTHONPATH}}"
export LD_LIBRARY_PATH="/usr/${KYLIN_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/qgis-xdg}"
mkdir -p "${XDG_RUNTIME_DIR}" && chmod 700 "${XDG_RUNTIME_DIR}"
unset DISPLAY || true

# --- 4. 版本号 / 3D / PyQGIS ------------------------------------------------
qgis_version="$(python3 -c 'from qgis.core import Qgis; print(Qgis.QGIS_VERSION)')"
log "PyQGIS 报告版本: ${qgis_version}"
[[ "${qgis_version}" == "${QGIS_VERSION}" ]] || die "PyQGIS 版本 ${qgis_version} != ${QGIS_VERSION}"

python3 - <<'PY' | tee "${EVID}/python-modules.txt"
import importlib
for m in ("qgis.core", "qgis.gui", "qgis.analysis", "PyQt5.QtCore"):
    importlib.import_module(m)
    print("OK  " + m)
try:
    importlib.import_module("qgis._3d")
    print("OK  qgis._3d (Python 3D bindings)")
except Exception as exc:
    print("WARN qgis._3d not importable: " + str(exc))
PY

ls -l /usr/${KYLIN_LIBDIR}/libqgis_3d.so.* | tee "${EVID}/libqgis_3d.txt"

# --- 5. 命令行启动 -----------------------------------------------------------
qgis_process --version 2>&1 | tee "${EVID}/qgis-process-version.txt"
grep -q "${QGIS_VERSION}" "${EVID}/qgis-process-version.txt" || \
  die "qgis_process --version 未报告 ${QGIS_VERSION}"

set +e
QT_QPA_PLATFORM=offscreen timeout 90 qgis --version 2>&1 | tee "${EVID}/qgis-version.txt"
qgis_rc=${PIPESTATUS[0]}
set -e
grep -q "${QGIS_VERSION}" "${EVID}/qgis-version.txt" || \
  die "qgis --version 未报告 ${QGIS_VERSION}（rc=${qgis_rc}）"

# --- 6. 离屏地图渲染 ---------------------------------------------------------
log "执行 PyQGIS 离屏地图渲染"
python3 "${REPO_ROOT}/tests/pyqgis_smoke.py" \
  --out "${EVID}/render.png" \
  --json "${EVID}/pyqgis-smoke.json" | tee "${EVID}/pyqgis-smoke.log"
test -s "${EVID}/render.png" || die "未生成地图渲染 PNG"

# --- 7. 报告 -----------------------------------------------------------------
python3 - "${EVID}" "${REPORT_DIR}" "${QGIS_VERSION}" <<'PY'
import json, os, sys
evid, rep, version = sys.argv[1:4]
smoke = json.load(open(os.path.join(evid, "pyqgis-smoke.json"), encoding="utf-8"))
report = {
    "stage": "STAGE_B2_CONTAINER_RUNTIME",
    "environment": "fresh Kylin V10 container (same OS userspace, not a VM)",
    "qgis_version": version,
    "rpm_install": "PASS",
    "pyqgis_version": "PASS",
    "qgis_cli": "PASS",
    "map_render": smoke["status"],
    "render_png_bytes": os.path.getsize(os.path.join(evid, "render.png")),
    "verdict": "PASS" if smoke["status"] == "PASS" else "FAIL",
}
os.makedirs(rep, exist_ok=True)
with open(os.path.join(rep, "container-runtime.json"), "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)
print(json.dumps(report, ensure_ascii=False, indent=2))
sys.exit(0 if report["verdict"] == "PASS" else 1)
PY

stage_marker STAGE_B2_CONTAINER_RUNTIME_OK PASS "${STAGES}/stage-b2.json"
info "FRESH CONTAINER RUNTIME PASS (STAGE_B2)"
info "注意：STAGE_C（真实 Kylin VM）与 STAGE_D（海光 C86 真机）尚未验证"
