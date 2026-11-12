#!/usr/bin/env bash
# 容器内一键构建：preflight -> 源码 -> SPEC -> rpmbuild -> 静态校验
# 用法：docker run ... /opt/qgis-build/scripts/build-all.sh
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
require_linux_or_container

run_step() {
  local s="$1"; shift
  info "################ ${s} ################"
  bash "${REPO_ROOT}/scripts/${s}" "$@"
}

run_step 00-preflight.sh --container
run_step 10-fetch-source.sh
run_step 20-render-spec.sh
run_step 30-rpmbuild.sh
run_step 40-verify-rpm.sh

info "############################################################"
info "BUILD ALL DONE —— STAGE_A + STAGE_B 完成"
info "RPM: ${OUT_DIR}/rpms/"
info "报告: ${REPORT_DIR}/"
info "注意：这不等于目标麒麟系统/海光 C86 真机运行成功（STAGE_C / STAGE_D）"
