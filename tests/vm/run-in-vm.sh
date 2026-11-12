#!/usr/bin/env bash
# ============================================================================
# 在 QEMU 启动的「真实银河麒麟 V10 目标系统」里执行（由 60-test-qemu-vm.sh 通过
# ssh 调用）。这是 STAGE_C：验证 RPM 安装、QGIS 启动、基本地图渲染。
# 不做任何 Ubuntu/Debian 兼容层假设；依赖全部从麒麟原生源解析。
# ============================================================================
set -Eeuo pipefail
CI_DIR="${CI_DIR:-/tmp/qgis-ci}"
EV="${CI_DIR}/evidence"
mkdir -p "${EV}"
log() { printf '[vm] %s\n' "$*"; }
fail() { printf '[vm][FAIL] %s\n' "$*" >&2; exit 1; }

if command -v dnf >/dev/null 2>&1; then PM=dnf
elif command -v yum >/dev/null 2>&1; then PM=yum
else fail "目标系统没有 dnf/yum，不是 RPM 体系"; fi

log "== 目标系统事实 =="
{ uname -a; cat /etc/os-release; cat /etc/kylin-release 2>/dev/null || true; } | tee "${EV}/os-release.txt"
lscpu | tee "${EV}/lscpu.txt" || true
${PM} --version | tee "${EV}/package-manager.txt"

# --- 1. 安装 -----------------------------------------------------------------
log "安装运行期依赖（验证 Requires 在目标系统源中可解）"
${PM} -y install $(cat "${CI_DIR}/runtime-requires.txt") 2>&1 | tee "${EV}/deps-install.log"
log "安装 QGIS RPM"
${PM} -y install --nogpgcheck "${CI_DIR}"/rpms/*.rpm 2>&1 | tee "${EV}/rpm-install.log"

rpm -qa | sort | tee "${EV}/rpm-qa.txt"
rpm -q qgis python3-qgis qgis-devel | tee "${EV}/qgis-rpms.txt"
rpm -V qgis python3-qgis qgis-devel 2>&1 | tee "${EV}/rpm-V.txt" || true
ldconfig || true

SITEARCH="$(python3 -c 'import sysconfig; print(sysconfig.get_path("platlib"))')"
LIBDIR="$(rpm --eval '%{_lib}')"
export QT_QPA_PLATFORM=offscreen
export QGIS_PREFIX_PATH=/usr
export PYTHONPATH="${SITEARCH}${PYTHONPATH:+:${PYTHONPATH}}"
export LD_LIBRARY_PATH="/usr/${LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export XDG_RUNTIME_DIR=/tmp/qgis-xdg
mkdir -p "${XDG_RUNTIME_DIR}" && chmod 700 "${XDG_RUNTIME_DIR}"
unset DISPLAY || true

# --- 2. 版本 / 3D / PyQGIS --------------------------------------------------
log "PyQGIS 版本"
version="$(python3 -c 'from qgis.core import Qgis; print(Qgis.QGIS_VERSION)')"
echo "${version}" | tee "${EV}/pyqgis-version.txt"
[[ "${version}" == "3.34.12" ]] || fail "PyQGIS 版本 ${version} != 3.34.12"

python3 - <<'PY' | tee "${EV}/python-modules.txt"
import importlib
for m in ("qgis.core", "qgis.gui", "qgis.analysis", "PyQt5.QtCore"):
    importlib.import_module(m)
    print("OK  " + m)
try:
    importlib.import_module("qgis._3d")
    print("OK  qgis._3d")
except Exception as e:
    print("WARN qgis._3d: " + str(e))
PY

ls -l /usr/${LIBDIR}/libqgis_3d.so.* | tee "${EV}/libqgis-3d.txt" || fail "缺少 3D 库"
ldd /usr/${LIBDIR}/libqgis_3d.so.* 2>&1 | tee "${EV}/ldd-3d.txt"

# --- 3. 命令行启动 -----------------------------------------------------------
qgis_process --version 2>&1 | tee "${EV}/qgis-process-version.txt"
grep -q '3.34.12' "${EV}/qgis-process-version.txt" || fail "qgis_process 版本不符"

set +e
QT_QPA_PLATFORM=offscreen timeout 120 qgis --version 2>&1 | tee "${EV}/qgis-version.txt"
set -e
grep -q '3.34.12' "${EV}/qgis-version.txt" || fail "qgis --version 未报告 3.34.12"

# --- 4. UKUI / X11 环境记录（无 GPU 时不做 OpenGL 3D 视图断言） --------------
log "UKUI / 桌面会话信息（仅记录，不作为硬断言）"
rpm -qa | grep -iE 'ukui|kylin' | sort | tee "${EV}/ukui-packages.txt" || true
ls -1 /usr/share/xsessions/ 2>/dev/null | tee "${EV}/xsessions.txt" || true
if command -v Xvfb >/dev/null 2>&1; then
  set +e
  xvfb-run -a --server-args="-screen 0 1280x800x24" timeout 120 qgis --version \
    2>&1 | tee "${EV}/qgis-xvfb-version.txt"
  set -e
  echo "Xvfb GUI start attempted" | tee -a "${EV}/ukui-note.txt"
else
  echo "UNVERIFIED: 目标镜像未安装 Xvfb / 无 GPU，UKUI 图形会话未启动验证" | \
    tee "${EV}/ukui-note.txt"
fi

# --- 5. 离屏地图渲染 ---------------------------------------------------------
log "离屏地图渲染"
python3 "${CI_DIR}/pyqgis_smoke.py" --out "${EV}/render.png" \
  --json "${EV}/pyqgis-smoke.json" | tee "${EV}/pyqgis-smoke.log"
test -s "${EV}/render.png" || fail "未生成地图 PNG"

# --- 6. 结论 -----------------------------------------------------------------
python3 - "${EV}" <<'PY'
import json, os, sys
ev = sys.argv[1]
smoke = json.load(open(os.path.join(ev, "pyqgis-smoke.json"), encoding="utf-8"))
out = {
    "stage": "STAGE_C_TARGET_VM_RUNTIME",
    "environment": "QEMU/KVM 虚拟机，运行真实 Kylin V10 内核与用户态",
    "qgis_version": open(os.path.join(ev, "pyqgis-version.txt")).read().strip(),
    "rpm_install": "PASS",
    "qgis_cli": "PASS",
    "3d_library": "PASS",
    "map_render": smoke["status"],
    "ukui_gui": "UNVERIFIED" if os.path.exists(os.path.join(ev, "ukui-note.txt"))
                 and "UNVERIFIED" in open(os.path.join(ev, "ukui-note.txt")).read()
                 else "BEST_EFFORT",
    "verdict": "PASS" if smoke["status"] == "PASS" else "FAIL",
}
with open(os.path.join(ev, "verdict.json"), "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
print(json.dumps(out, ensure_ascii=False, indent=2))
sys.exit(0 if out["verdict"] == "PASS" else 1)
PY
log "STAGE_C PASS"
