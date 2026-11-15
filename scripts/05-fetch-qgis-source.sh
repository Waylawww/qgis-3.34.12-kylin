#!/usr/bin/env bash
# 阶段 1：下载并校验 QGIS 3.34.12 官方源码（多端点回退，缓存可复用）。
# 与旧 10-fetch-source.sh 的区别：不依赖裸 git clone（国内麒麟主机常失败），
# 使用官方 tag tarball，并用 CMakeLists.txt 三元组复核版本。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env

CACHE_DIR="${CACHE_DIR:-${REPO_ROOT}/cache}"
SRC_DIR="${WORK_DIR}/src/qgis-${QGIS_VERSION}"
TARBALL="${CACHE_DIR}/qgis-${QGIS_VERSION}.tar.gz"
mkdir -p "$CACHE_DIR" "${WORK_DIR}/src"

info "== 阶段 1 / FETCH QGIS SOURCE (${QGIS_VERSION}, tag ${QGIS_GIT_TAG}) =="

urls=(
  "https://codeload.github.com/qgis/QGIS/tar.gz/refs/tags/${QGIS_GIT_TAG}"
  "https://github.com/qgis/QGIS/archive/refs/tags/${QGIS_GIT_TAG}.tar.gz"
  "https://ghproxy.net/https://github.com/qgis/QGIS/archive/refs/tags/${QGIS_GIT_TAG}.tar.gz"
  "https://download.qgis.org/downloads/qgis-${QGIS_VERSION}.tar.bz2"
)

check_source_dir() {
  local f="$1/CMakeLists.txt"
  [[ -f "$f" ]] || return 1
  local major minor patch
  major="$(grep -E '^set\(CPACK_PACKAGE_VERSION_MAJOR' "$f" | grep -oE '[0-9]+' | head -n1 || true)"
  minor="$(grep -E '^set\(CPACK_PACKAGE_VERSION_MINOR' "$f" | grep -oE '[0-9]+' | head -n1 || true)"
  patch="$(grep -E '^set\(CPACK_PACKAGE_VERSION_PATCH' "$f" | grep -oE '[0-9]+' | head -n1 || true)"
  [[ "${major}.${minor}.${patch}" == "${QGIS_VERSION}" ]]
}

if check_source_dir "$SRC_DIR"; then
  log "源码已存在且版本正确: ${SRC_DIR}（跳过下载）"
else
  rm -rf "$SRC_DIR"
  got=0
  for url in "${urls[@]}"; do
    log "尝试下载: ${url}"
    tmp="${TARBALL}.part"
    rm -f "$tmp"
    case "$url" in
      *.bz2) suffix=bz2 ;;
      *)     suffix=gz ;;
    esac
    if curl -fsSL --retry 2 --connect-timeout 20 --max-time 900 "$url" -o "$tmp" \
       && [[ -s "$tmp" ]] && [[ $(stat -c %s "$tmp") -gt 10000000 ]]; then
      if [[ "$suffix" == "gz" ]]; then
        tar -tzf "$tmp" >/dev/null 2>&1 || { warn "tar 校验失败: ${url}"; continue; }
      else
        bzip2 -t "$tmp" >/dev/null 2>&1 || { warn "bzip2 校验失败: ${url}"; continue; }
      fi
      mv -f "$tmp" "${TARBALL}.${suffix}"
      TARBALL="${TARBALL}.${suffix}"
      TARBALL_SUFFIX="$suffix"
      got=1
      break
    fi
    warn "下载失败或文件过小: ${url}"
  done
  [[ "$got" == "1" ]] || die "所有源码下载端点均不可用；详见 10-probe-env 的 network_http_status"

  mkdir -p "$SRC_DIR"
  if [[ "${TARBALL_SUFFIX}" == "gz" ]]; then
    tar -xzf "$TARBALL" -C "$SRC_DIR" --strip-components=1
  else
    tar -xjf "$TARBALL" -C "$SRC_DIR" --strip-components=1
  fi
  check_source_dir "$SRC_DIR" || die "解压后的源码版本不是 ${QGIS_VERSION}，拒绝构建"
fi

sha="$(sha256sum "$TARBALL" 2>/dev/null | awk '{print $1}' || echo unavailable)"
size="$(stat -c %s "$TARBALL" 2>/dev/null || echo 0)"
python3 - "$REPORT_DIR/source-manifest.json" "$QGIS_VERSION" "$QGIS_GIT_TAG" \
          "$QGIS_GIT_COMMIT" "$SRC_DIR" "$TARBALL" "$sha" "$size" <<'PY'
import datetime, json, sys
path = sys.argv[1]
d = {
    "qgis_version": sys.argv[2], "git_tag": sys.argv[3], "git_commit": sys.argv[4],
    "source_dir": sys.argv[5], "tarball": sys.argv[6],
    "tarball_sha256": sys.argv[7], "tarball_bytes": int(sys.argv[8] or 0),
    "recorded_at": datetime.datetime.utcnow().isoformat() + "Z",
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
PY
cp -f "$REPORT_DIR/source-manifest.json" "${REPO_ROOT}/reports/source-manifest.json" 2>/dev/null || true
log "源码就绪: ${SRC_DIR} (tarball ${size} bytes, sha256=${sha})"
info "FETCH SOURCE PASS"
