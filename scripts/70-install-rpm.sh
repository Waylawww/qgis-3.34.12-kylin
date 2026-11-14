#!/usr/bin/env bash
# 阶段 7：在本机（self-hosted runner 所在机器）安装刚构建出的 RPM。
#
# runner 是 actionsrunner(uid 1001)，而 rpm -e/-ivh 需要 root。安装动作通过
# root 预先配置的 /etc/sudoers.d/qgis-ci-install 只放行一个固定脚本
# /usr/local/sbin/qgis-ci-install（root 拥有，runner 不可改、不可传参）；
# 该脚本再用 root 维护的 /etc/qgis-ci/allowed-rpm.sha256 校验 RPM 指纹，
# 保证 runner 无法借"安装自己构造的 RPM"间接获得 root。
set -Eeuo pipefail

RPM="${OUT_DIR}/rpms/qgis-${QGIS_VERSION}-1.ky10.x86_64.rpm"
INSTALLER=/usr/local/sbin/qgis-ci-install

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

sudo -n "${INSTALLER}"
echo "INSTALL RPM DONE"
