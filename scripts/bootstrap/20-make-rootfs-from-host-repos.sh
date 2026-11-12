#!/usr/bin/env bash
# ============================================================================
# 从已安装的 Kylin V10 x86_64 主机及其现有 DNF 软件源制作最小容器 rootfs。
# 不需要 ISO。建议在目标麒麟主机上以 root 执行。
#
# 用法：
#   sudo bash scripts/bootstrap/20-make-rootfs-from-host-repos.sh
#   sudo KEEP_REPO_CONFIG=1 bash scripts/bootstrap/20-make-rootfs-from-host-repos.sh
#
# KEEP_REPO_CONFIG=1 会把主机 .repo 文件和 RPM GPG 公钥复制进 rootfs，
# 仅当这些文件不含账号、密码、Token、客户端证书路径等敏感信息时使用。
# 若软件源依赖主机专属凭据，请不要复制；改用私有 runner / 安全注入 repo。
# ============================================================================
set -Eeuo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
OUT="${OUT_DIR:-${REPO_ROOT}/out}"
ROOTFS="${ROOTFS:-${OUT}/kylin-v10-rootfs}"
TAR_FILE="${ROOTFS_TAR:-${OUT}/kylin-v10-rootfs.tar}"
CACHE="${DNF_CACHE:-${OUT}/dnf-cache}"
REPO_DIR="${KYLIN_REPO_DIR:-/etc/yum.repos.d}"
KEEP_REPO_CONFIG="${KEEP_REPO_CONFIG:-0}"
LOG="${OUT}/rootfs-from-host-repos.log"

log(){ printf '[rootfs] %s\n' "$*"; }
die(){ printf '[rootfs][FATAL] %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "请在麒麟主机上使用 sudo/root 执行"
[[ "$(uname -m)" == "x86_64" ]] || die "当前架构为 $(uname -m)，目标要求 x86_64"

[[ -r /etc/os-release ]] || die "缺少 /etc/os-release"
. /etc/os-release
case "${ID:-} ${NAME:-} ${PRETTY_NAME:-}" in
  *kylin*|*Kylin*|*麒麟*) ;;
  *) die "当前系统未识别为麒麟：${PRETTY_NAME:-unknown}" ;;
esac
case "${VERSION_ID:-}" in
  10*|V10*|v10*) ;;
  *) die "当前系统版本号不是明确的 V10：${VERSION_ID:-unknown}；请先核实发行版版本" ;;
esac

command -v dnf >/dev/null 2>&1 || die "未找到 dnf。请确认该麒麟 V10 环境使用 DNF；不要直接改用其他发行版包管理器。"
command -v rpm >/dev/null 2>&1 || die "未找到 rpm"
command -v tar >/dev/null 2>&1 || die "未找到 tar"
[[ -d "${REPO_DIR}" ]] || die "软件源目录不存在：${REPO_DIR}"

mkdir -p "$OUT" "$CACHE"
log "主机：${PRETTY_NAME:-Kylin} / $(uname -m)"
log "检查主机软件源..."
dnf -q repolist --enabled | tee "$LOG"
# 不在此处猜测仓库 ID；若仓库不可用，后续 dnf install 会以原始错误退出。

if [[ "$KEEP_REPO_CONFIG" == "1" ]]; then
  if grep -RniE '(^|[[:space:]])(username|password|token|sslclientcert|sslclientkey)[[:space:]]*=|https?://[^/@:]+:[^/@]+@|[?&](token|password|apikey)=' "$REPO_DIR" 2>/dev/null; then
    die "检测到 repo 文件可能含账号/密码/Token/客户端证书配置。拒绝把凭据写入镜像；请使用不含凭据的 repo 文件或 KEEP_REPO_CONFIG=0。"
  fi
fi

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
rpm --root "$ROOTFS" --initdb

# 依赖集合刻意保持精简。QGIS 构建依赖由后续 probe/build 阶段单独安装。
PACKAGES=(
  filesystem setup basesystem
  bash coreutils glibc glibc-common
  rpm rpm-libs dnf
  python3 ca-certificates curl
  tar bzip2 xz gzip
  findutils which hostname procps-ng
  shadow-utils util-linux
)

log "使用主机现有仓库创建干净 rootfs（不复制宿主机整个 /）..."
set -o pipefail
dnf --installroot="$ROOTFS" --releasever=/ \
  --setopt="reposdir=$REPO_DIR" \
  --setopt="varsdir=/etc/dnf/vars" \
  --setopt="cachedir=$CACHE" \
  --setopt=install_weak_deps=False \
  --setopt=tsflags=nodocs \
  -y install "${PACKAGES[@]}" 2>&1 | tee -a "$LOG"

# 容器需要这些挂载点，但不需要宿主机的运行时内容。
mkdir -p "$ROOTFS"/{dev,proc,sys,run,tmp}
chmod 1777 "$ROOTFS/tmp"
: > "$ROOTFS/etc/machine-id"
rm -f "$ROOTFS"/etc/ssh/ssh_host_* 2>/dev/null || true
if [[ -d "$ROOTFS/var/log" ]]; then
  find "$ROOTFS/var/log" -type f -delete
fi
rm -rf "$ROOTFS/var/cache/dnf" "$ROOTFS/var/cache/yum" 2>/dev/null || true

if [[ "$KEEP_REPO_CONFIG" == "1" ]]; then
  mkdir -p "$ROOTFS/etc/yum.repos.d" "$ROOTFS/etc/pki/rpm-gpg"
  cp -a "$REPO_DIR/." "$ROOTFS/etc/yum.repos.d/"
  if [[ -d /etc/pki/rpm-gpg ]]; then
    cp -a /etc/pki/rpm-gpg/. "$ROOTFS/etc/pki/rpm-gpg/"
  fi
  log "已复制 repo 配置。请确认镜像只推送到可信的私有仓库。"
else
  log "未复制 repo 配置；后续探测/编译需通过私有 runner 挂载或安全注入软件源。"
fi

rm -f "$TAR_FILE"
tar --numeric-owner --xattrs --acls -C "$ROOTFS" -cf "$TAR_FILE" .
[[ -s "$TAR_FILE" ]] || die "rootfs tar 生成失败"

log "ROOTFS TAR: $TAR_FILE"
log "SIZE: $(du -h "$TAR_FILE" | awk '{print $1}')"
log "OS: $(grep '^PRETTY_NAME=' "$ROOTFS/etc/os-release" 2>/dev/null || true)"
log "下一步（在有 Docker 的麒麟主机上）："
log "  docker build -f docker/Dockerfile.bootstrap --build-arg ROOTFS=kylin-v10-rootfs.tar -t kylin-v10-x86_64:local $OUT"
log "  docker run --rm --entrypoint /bin/bash kylin-v10-x86_64:local -lc 'cat /etc/os-release; rpm --version; dnf --version'"
