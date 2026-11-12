#!/usr/bin/env bash
# 阶段 0：门禁。任何"未确认参数"都会让构建直接失败，杜绝凭猜测出包。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env

MODE="${1:---ci}"
ONLINE=0
[[ "${PREFLIGHT_ONLINE:-0}" == "1" ]] && ONLINE=1

info "== 阶段 0 / PREFLIGHT (${MODE}) =="
log "QGIS 目标版本 : ${QGIS_VERSION} (tag ${QGIS_GIT_TAG}, commit ${QGIS_GIT_COMMIT})"
log "目标平台     : ${TARGET_OS} / ${TARGET_ARCH} / ${TARGET_CPU} / ${TARGET_KERNEL}"
log "ISA 基线     : ${ISA_POLICY} (${ISA_CFLAGS})"

# --- 1. 宿主工具 -------------------------------------------------------------
need_cmd python3 "用于依赖矩阵与报告"
need_cmd git "用于锁定 QGIS 官方 tag"
need_cmd sha256sum "用于校验产物"
need_cmd bzip2 "用于生成官方风格源码 tarball"
need_cmd awk "基础工具"
if [[ "${MODE}" == "--ci" ]]; then
  need_cmd docker "GitHub Actions 用 Docker 固定编译环境"
  need_cmd df "检查磁盘空间"
fi

# --- 2. 麒麟环境确认文件 -----------------------------------------------------
[[ -f "${KYLIN_ENV}" ]] || die "缺少 ${KYLIN_ENV}
请在 Kylin V10 容器内运行: python3 scripts/probe-kylin.py --write
再把生成的文件提交到仓库（或由 probe workflow 上传后下载）。详见 docs/CONFIRM.md"
[[ -f "${DEPS_ENV}" ]] || die "缺少 ${DEPS_ENV}（同上，由 probe-kylin.py 生成）"

KYLIN_CRITICAL=(
  KYLIN_OS_ID KYLIN_OS_VERSION_ID KYLIN_KERNEL KYLIN_GLIBC KYLIN_GCC
  KYLIN_RPM_VERSION KYLIN_PACKAGE_MANAGER KYLIN_LIBDIR
  KYLIN_PYTHON3_BIN KYLIN_PYTHON3_SITEARCH KYLIN_MACRO_LIBDIR KYLIN_DIST_TAG
)
reject_placeholders "${KYLIN_ENV}" "${KYLIN_CRITICAL[@]}"
reject_placeholders "${DEPS_ENV}" QGIS_BUILDREQUIRES QGIS_RUNTIME_REQUIRES UNRESOLVED_DEPS DEPS_VERSION_FAILURES

if grep -q '__UNCONFIRMED__' "${DEPS_ENV}"; then
  bad="$(grep '__UNCONFIRMED__' "${DEPS_ENV}" | cut -d= -f1 | paste -sd, -)"
  warn "以下可选依赖未解析: ${bad}"
fi

# 只有确认过的包名才允许进 spec；拒绝任何 Debian/Ubuntu 痕迹
if grep -Eqi '(^|[[:space:]])(apt-get|libqt5core5a|libgdal-dev|libproj-dev|python3-pyqt5\.)' "${DEPS_ENV}"; then
  die "依赖映射中出现 Debian/Ubuntu 体系内容；本工程禁止把 Ubuntu 产物包装成 RPM"
fi

# --- 3. 基础镜像 -------------------------------------------------------------
KYLIN_BASE_IMAGE="${KYLIN_BASE_IMAGE:-$(grep -E '^KYLIN_BASE_IMAGE=' "${KYLIN_ENV}" | tail -n1 | cut -d= -f2- | tr -d "\"'" || true)}"
if [[ -z "${KYLIN_BASE_IMAGE}" || "${KYLIN_BASE_IMAGE}" == *"__UNCONFIRMED__"* ]]; then
  die "KYLIN_BASE_IMAGE 未确认。
需在 GitHub Repository Variables 中设置，或写入 config/kylin.confirmed.env。
必须是 Kylin V10 RPM 体系镜像（含 digest），不得使用 Ubuntu 基础镜像。"
fi
log "基础镜像     : ${KYLIN_BASE_IMAGE}"

# --- 4. 在线核验 QGIS 官方 tag ------------------------------------------------
if [[ "${ONLINE}" == "1" ]]; then
  need_cmd git "在线校验 tag"
  log "在线核验 https://github.com/qgis/QGIS tag=${QGIS_GIT_TAG}"
  remote="$(git ls-remote "${QGIS_GIT_REPO}" "refs/tags/${QGIS_GIT_TAG}" "refs/tags/${QGIS_GIT_TAG}^{}" || true)"
  [[ -n "${remote}" ]] || die "官方仓库中找不到 tag ${QGIS_GIT_TAG}"
  tag_commit="$(printf '%s\n' "${remote}" | grep -v '\^{}$' | awk 'NR==1{print $1}' || true)"
  peeled="$(printf '%s\n' "${remote}" | grep '\^{}$' | awk 'NR==1{print $1}' || true)"
  resolved="${peeled:-${tag_commit}}"
  if [[ "${resolved}" != "${QGIS_GIT_COMMIT}" ]]; then
    die "QGIS tag 解析结果 ${resolved} 与锁定的 commit ${QGIS_GIT_COMMIT} 不一致；拒绝构建非 3.34.12 源码"
  fi
  log "官方 tag 已核验 -> ${resolved}"
fi

# --- 5. 磁盘空间 -------------------------------------------------------------
avail="$(free_gb "${WORK_DIR}")"
log "可用磁盘     : ${avail} GB (要求 >= ${MIN_FREE_GB} GB)"
if (( avail < MIN_FREE_GB )); then
  warn "磁盘不足。QGIS 全量编译通常需要 25~40GB。建议使用 larger runner 或自托管 runner，"
  warn "并在 workflow 中执行 scripts/ci-free-space.sh 清理预装软件。"
  [[ "${ALLOW_LOW_DISK:-0}" == "1" ]] || die "磁盘空间不足，构建中止"
fi

# --- 6. 三层验证契约 ---------------------------------------------------------
cat > "${REPORT_DIR}/preflight.json" <<JSON
{
  "qgis_version": "${QGIS_VERSION}",
  "qgis_tag": "${QGIS_GIT_TAG}",
  "qgis_commit": "${QGIS_GIT_COMMIT}",
  "base_image": "${KYLIN_BASE_IMAGE}",
  "isa_policy": "${ISA_POLICY}",
  "target": "${TARGET_OS}/${TARGET_ARCH}/${TARGET_CPU}",
  "free_gb": ${avail},
  "online_tag_verified": $([[ "${ONLINE}" == "1" ]] && echo true || echo false),
  "result": "PASS"
}
JSON

info "PREFLIGHT PASS —— 已确认参数齐全，可以继续"
info "提示: STAGE_A(源码编译) / STAGE_B(RPM 打包) / STAGE_B2(容器运行) / STAGE_C(目标 VM 运行) / STAGE_D(C86 真机) 将分别记录，互不冒充"
