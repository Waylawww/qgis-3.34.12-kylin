#!/usr/bin/env bash
# ============================================================================
# 兜底方案：从「官方银河麒麟 V10 x86_64 ISO」生成最小 rootfs tar，供
# docker/Dockerfile.bootstrap 打成基础镜像。
#
# 前提（必须自行确认，脚本不会猜测）：
#   * KYLIN_ISO_PATH 或 KYLIN_ISO_URL：官方 ISO（与 4.19.90-89.11.v2401.ky10 同版本）
#   * ISO 内的仓库布局（BaseOS / AppStream / Packages / repodata）
#   * 运行本脚本的机器允许 loop mount（GitHub 托管 runner 通常可以 sudo mount，
#     但Codespaces不支持 --privileged，必要时用自托管 runner）
#
# 产物：out/kylin-v10-rootfs.tar
# 之后：docker build -f docker/Dockerfile.bootstrap -t <registry>/kylin-v10:base out/
#       docker push <registry>/kylin-v10:base
#      把「镜像@sha256:...」填入 KYLIN_BASE_IMAGE
# ============================================================================
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${REPO_ROOT}/out"
MNT="${MNT:-/mnt/kylin-iso}"
ROOTFS="${ROOTFS:-/tmp/kylin-rootfs}"
ISO="${KYLIN_ISO_PATH:-${OUT}/kylin-v10.iso}"

log() { printf '[bootstrap] %s\n' "$*"; }
die() { printf '[bootstrap][FATAL] %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "需要 root（sudo）以执行 loop mount 与 dnf --installroot"
mkdir -p "${OUT}" "${MNT}"

if [[ ! -f "${ISO}" ]]; then
  [[ -n "${KYLIN_ISO_URL:-}" ]] || die "请设置 KYLIN_ISO_PATH 或 KYLIN_ISO_URL（官方 ISO 下载地址）"
  log "下载 ISO: ${KYLIN_ISO_URL}"
  curl -fL "${KYLIN_ISO_URL}" -o "${ISO}"
fi
if [[ -n "${KYLIN_ISO_SHA256:-}" ]]; then
  echo "${KYLIN_ISO_SHA256}  ${ISO}" | sha256sum -c - || die "ISO sha256 校验失败"
else
  log "[WARN] 未提供 KYLIN_ISO_SHA256，强烈建议补齐以保证可复现"
fi

mountpoint -q "${MNT}" || mount -o loop,ro "${ISO}" "${MNT}"
trap 'umount "${MNT}" 2>/dev/null || true' EXIT

log "ISO 顶层目录："
ls -1 "${MNT}" | sed 's/^/    /'

# 找出所有含 repodata 的目录，作为 --repofrompath 的源
mapfile -t repo_dirs < <(find "${MNT}" -type d -name repodata -printf '%h\n' | sort -u)
(( ${#repo_dirs[@]} > 0 )) || die "ISO 中未找到 repodata/，请确认 KYLIN_ISO_LAYOUT 后修改本脚本"
log "发现 ${#repo_dirs[@]} 个 RPM 仓库："
printf '    %s\n' "${repo_dirs[@]}"

for tool in dnf rpm tar; do
  command -v "${tool}" >/dev/null 2>&1 || die "宿主缺少 ${tool}（Ubuntu 可 sudo apt-get install -y dnf rpm tar）"
done

rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"
rpm --root "${ROOTFS}" --initdb

repo_args=()
i=0
for d in "${repo_dirs[@]}"; do
  i=$((i+1))
  repo_args+=( "--repofrompath=kylin${i},file://${d}" )
  repo_args+=( "--enablerepo=kylin${i}" )
done

log "用 dnf --installroot 安装最小 RPM 用户态（包名需在真实 ISO 上确认）"
dnf --installroot="${ROOTFS}" --releasever=/ \
    --setopt=install_weak_deps=False \
    --setopt=cachedir="${OUT}/dnf-cache" \
    --nogpgcheck \
    --disablerepo='*' \
    "${repo_args[@]}" \
    -y install \
    bash coreutils glibc rpm dnf yum python3 ca-certificates curl \
    tar bzip2 xz gzip findutils which hostname procps-ng \
    passwd shadow-utils util-linux filesystem \
    2>&1 | tee "${OUT}/bootstrap-dnf.log"

# 让容器内有可用的 DNS / repo 定义
cp -f /etc/resolv.conf "${ROOTFS}/etc/resolv.conf" 2>/dev/null || true
mkdir -p "${ROOTFS}/etc/yum.repos.d"
for f in /etc/yum.repos.d/*.repo "${MNT}"/etc/yum.repos.d/*.repo; do
  [[ -f "$f" ]] && cp -f "$f" "${ROOTFS}/etc/yum.repos.d/" || true
done

tar -C "${ROOTFS}" -cf "${OUT}/kylin-v10-rootfs.tar" .
log "已生成 ${OUT}/kylin-v10-rootfs.tar ($(stat -c %s "${OUT}/kylin-v10-rootfs.tar") bytes)"
log "下一步："
log "  docker build -f docker/Dockerfile.bootstrap --build-arg ROOTFS=kylin-v10-rootfs.tar \\"
log "               -t ${KYLIN_BASE_IMAGE:-<registry>/kylin-v10:base} out/"
log "  docker push ${KYLIN_BASE_IMAGE:-<registry>/kylin-v10:base}"
log "  docker inspect --format='{{index .RepoDigests 0}}' ${KYLIN_BASE_IMAGE:-<image>}"
log "把 digest 写入 config/kylin.confirmed.env 的 KYLIN_BASE_IMAGE / _DIGEST"
log "[注意] 本脚本的 ISO 仓库布局与最小包集合必须在真实 ISO 上验证；"
log "       它是兜底路径，不保证一次成功，失败时请按 docs/CONFIRM.md 第 1 节记录实际布局。"
