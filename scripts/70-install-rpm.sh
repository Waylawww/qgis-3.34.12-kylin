#!/usr/bin/env bash
# 阶段 7：在本机（self-hosted runner 所在机器）安装刚构建出的 RPM 并做运行自测。
#
# runner 是 actionsrunner(uid 1001)，而 rpm -e/-ivh 需要 root。安装动作通过
# root 预先配置的 /etc/sudoers.d/qgis-ci-install 只放行一个固定脚本
# /usr/local/sbin/qgis-ci-install（root 拥有，runner 不可改、不可传参）；
# 该脚本再用 root 维护的 /etc/qgis-ci/allowed-rpm.sha256 校验 RPM 指纹，
# 保证 runner 无法借"安装自己构造的 RPM"间接获得 root。
#
# 安装后以普通用户身份跑完整自测（CLI / PyQGIS / 离屏地图渲染），结果写入
# ${REPORT_DIR}/install-selftest/，随 evidence artifact 上传，作为真机验收凭证。
set -Eeuo pipefail

RPM="${OUT_DIR}/rpms/qgis-${QGIS_VERSION}-1.ky10.x86_64.rpm"
INSTALLER=/usr/local/sbin/qgis-ci-install
PREFIX="/opt/qgis-${QGIS_VERSION}"
DEPS="${PREFIX}/deps"
EVID="${REPORT_DIR}/install-selftest"
mkdir -p "${EVID}"

echo "runner: $(id -un) uid=$(id -u)"
echo "rpm: ${RPM}"
[[ -f "${RPM}" ]] || { echo "FATAL: RPM 不存在: ${RPM}" >&2; exit 1; }
command -v sudo >/dev/null 2>&1 || { echo "FATAL: sudo 不可用" >&2; exit 1; }

# -l 只查询权限、不执行命令；未配置免密规则时给出明确提示
if ! sudo -n -l "${INSTALLER}" >/dev/null 2>&1; then
  echo "FATAL: actionsrunner 未被授权调用 ${INSTALLER}" >&2
  echo "       请先在 root 下配置 /etc/sudoers.d/qgis-ci-install" >&2
  exit 1
fi
# RPM 的 %files 把 /usr/bin 等公共目录也声明为自有，与 filesystem 包冲突，
# 安装器必须带 --replacefiles；这里提前检查，避免又白跑一次。
if ! grep -q -- '--replacefiles' "${INSTALLER}" 2>/dev/null; then
  echo "FATAL: 安装器缺少 --replacefiles" >&2
  echo "       root 下执行: sed -i 's/rpm -ivh /rpm -ivh --replacefiles /' ${INSTALLER}" >&2
  exit 1
fi

echo "== 安装（受限 sudo） =="
sudo -n "${INSTALLER}"
echo "INSTALL RPM DONE"

# --- 运行环境：与 /usr/bin/qgis wrapper 保持一致 ----------------------------
export LD_LIBRARY_PATH="${DEPS}/lib:${DEPS}/lib64:${PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export PYTHONPATH="${DEPS}/lib/python3.7/site-packages:${PREFIX}/share/qgis/python${PYTHONPATH:+:${PYTHONPATH}}"
export QT_PLUGIN_PATH="${DEPS}/plugins"
export QML2_IMPORT_PATH="${DEPS}/qml"
export QGIS_PREFIX_PATH="${PREFIX}"
export PROJ_LIB="${DEPS}/share/proj"
export GDAL_DATA="${DEPS}/share/gdal"
export QT_QPA_PLATFORM=offscreen
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/qgis-xdg-$(id -u)}"
mkdir -p "${XDG_RUNTIME_DIR}" && chmod 700 "${XDG_RUNTIME_DIR}" 2>/dev/null || true
unset DISPLAY || true

# --- 自测：逐项收集结果，全部跑完再判定 ------------------------------------
CHECKS=()
check() {
  local name="$1"; shift
  if "$@" >"${EVID}/${name}.log" 2>&1; then
    echo "  PASS  ${name}"
    CHECKS+=("${name}:PASS")
  else
    echo "  FAIL  ${name}"
    tail -n 15 "${EVID}/${name}.log" >&2 || true
    CHECKS+=("${name}:FAIL")
  fi
}

rpm_installed()      { rpm -q qgis; }
private_libstdcpp()  { test -e "${DEPS}/lib/libstdc++.so.6.0.29"; }
ldd_clean() {
  local out
  out="$(ldd "${PREFIX}/bin/qgis" 2>&1 || true)"
  printf '%s\n' "${out}" > "${EVID}/ldd.txt"
  ! grep -Eq 'not found|GLIBCXX|CXXABI' <<<"${out}"
}
qgis_process_version() {
  local out
  out="$(timeout 90 qgis_process --version 2>&1)"
  printf '%s\n' "${out}"
  grep -q "${QGIS_VERSION}" <<<"${out}"
}
qgis_version() {
  local out
  out="$(timeout 90 qgis --version 2>&1)"
  printf '%s\n' "${out}"
  grep -q "${QGIS_VERSION}" <<<"${out}"
}
pyqgis_version() {
  local out
  out="$(python3 -c 'from qgis.core import Qgis; print(Qgis.QGIS_VERSION)')"
  printf '%s\n' "${out}"
  [[ "${out}" == "${QGIS_VERSION}" ]]
}
pyqgis_smoke() {
  python3 "${REPO_ROOT}/tests/pyqgis_smoke.py" \
    --out "${EVID}/render.png" --json "${EVID}/pyqgis-smoke.json"
  test -s "${EVID}/render.png"
}

echo "== 运行自测 =="
check rpm_installed          rpm_installed
check private_libstdcpp      private_libstdcpp
check ldd_clean              ldd_clean
check qgis_process_version   qgis_process_version
check qgis_version           qgis_version
check pyqgis_version         pyqgis_version
check pyqgis_smoke           pyqgis_smoke

# --- 汇总报告 ---------------------------------------------------------------
if ! python3 - "${EVID}" "${QGIS_VERSION}" "${CHECKS[@]}" <<'PY'
import json, os, sys

evid, version, *items = sys.argv[1:]
checks = {}
for item in items:
    k, _, v = item.partition(":")
    checks[k] = v

smoke_path = os.path.join(evid, "pyqgis-smoke.json")
smoke = {}
if os.path.exists(smoke_path):
    smoke = json.load(open(smoke_path, encoding="utf-8"))
    checks["map_render"] = smoke.get("status", "FAIL")

mandatory = ("rpm_installed", "private_libstdcpp", "ldd_clean",
             "qgis_process_version", "qgis_version", "pyqgis_version",
             "pyqgis_smoke", "map_render")
failed = [k for k in mandatory if checks.get(k) != "PASS"]
render_png = os.path.join(evid, "render.png")
report = {
    "stage": "STAGE_D_TARGET_HOST_INSTALL_AND_SELFTEST",
    "environment": "self-hosted runner host, Kylin V10 (Halberd) / x86_64 / Hygon C86",
    "host": os.uname().nodename,
    "run_as": os.popen("id -un").read().strip(),
    "qgis_version": version,
    "checks": checks,
    "render_png_bytes": os.path.getsize(render_png) if os.path.exists(render_png) else 0,
    "render_detail": smoke.get("render"),
    "smoke_checks": smoke.get("checks"),
    "failed_checks": failed,
    "verdict": "PASS" if not failed else "FAIL",
}
out = os.path.join(evid, "install-selftest.json")
with open(out, "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)
print(json.dumps(report, f, ensure_ascii=False, indent=2))
sys.exit(0 if not failed else 1)
PY
then
  echo "INSTALL + SELFTEST FAIL" >&2
  exit 1
fi
echo "INSTALL + SELFTEST PASS"
