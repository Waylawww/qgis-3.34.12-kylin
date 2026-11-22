#!/usr/bin/env bash
# 阶段 1：下载锁定 tag 的 Assimp 官方源码，应用本地补丁，校验指纹。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
source "${REPO_ROOT}/config/assimp.env"

need_cmd curl "源码下载"
need_cmd tar  "源码解压"
need_cmd git  "补丁应用"

PATCH="${REPO_ROOT}/${ASSIMP_PATCH_REL}"
TARBALL="${ASSIMP_WORK}/assimp-${ASSIMP_VERSION}.tar.gz"
URLS=(
  "https://ghproxy.net/https://github.com/${ASSIMP_UPSTREAM_REPO#https://github.com/}/archive/refs/tags/${ASSIMP_TAG}.tar.gz"
  "https://codeload.github.com/${ASSIMP_UPSTREAM_REPO#https://github.com/}/tar.gz/refs/tags/${ASSIMP_TAG}"
  "https://github.com/${ASSIMP_UPSTREAM_REPO#https://github.com/}/archive/refs/tags/${ASSIMP_TAG}.tar.gz"
)

log "== 阶段 1 / FETCH ASSIMP ${ASSIMP_VERSION} =="
STAMP="${ASSIMP_WORK}/.source-ready"
PATCH_SHA_NOW="$(sha256sum "$PATCH" | awk '{print $1}')"
if [[ -f "${ASSIMP_SRC_DIR}/CMakeLists.txt" ]] \
   && grep -q "VERSION ${ASSIMP_VERSION}" "${ASSIMP_SRC_DIR}/CMakeLists.txt" \
   && grep -q 'bool isDone()' "${ASSIMP_SRC_DIR}/code/AssetLib/Obj/ObjFileParser.h" \
   && [[ -f "$STAMP" ]] && grep -q "$PATCH_SHA_NOW" "$STAMP"; then
  cached_sha="$(awk '{print $1}' "$STAMP")"
  log "复用已校验源码（tarball sha256=${cached_sha}），避免重复下载触发全量重编"
  python3 - "${ASSIMP_REPORT_DIR}" "${cached_sha}" "${ASSIMP_SRC_DIR}" <<'PY'
import json, os, sys
rep, sha, src = sys.argv[1:4]
with open(os.path.join(rep, 'assimp-source.json'), 'w', encoding='utf-8') as f:
    json.dump({'stage': 'ASSIMP_STAGE_1_SOURCE', 'tarball_sha256': sha,
               'source_dir': src, 'verdict': 'PASS (cached)'}, f, indent=2)
PY
  stage_marker ASSIMP_STAGE_1_SOURCE_OK PASS "${ASSIMP_REPORT_DIR}/assimp-source-ok.json"
  info "ASSIMP SOURCE PASS (cached)"
  exit 0
fi
rm -f "$TARBALL"
for url in "${URLS[@]}"; do
  log "尝试下载: $url"
  if curl -fL --retry 4 --retry-delay 3 --connect-timeout 20 --max-time 1800 \
       -o "$TARBALL" "$url" && tar -tzf "$TARBALL" >/dev/null 2>&1; then
    log "下载成功: $(stat -c%s "$TARBALL") bytes"
    break
  fi
  rm -f "$TARBALL"
done
[[ -s "$TARBALL" ]] || die "三个下载地址均失败，拒绝继续"

# 官方归档必须自带 CMakeLists 且版本三元组与锁定值一致
grep -q 'CMakeLists.txt' < <(tar -tzf "$TARBALL") || die "归档缺少 CMakeLists.txt"
ver_line="$(tar -xOzf "$TARBALL" --wildcards '*/CMakeLists.txt' 2>/dev/null \
            | grep -m1 'PROJECT(Assimp VERSION' || true)"
[[ "$ver_line" == *"VERSION ${ASSIMP_VERSION}"* ]] \
  || die "源码版本不符: ${ver_line:-<未找到>}，期望 ${ASSIMP_VERSION}"

rm -rf "$ASSIMP_SRC_DIR"
mkdir -p "$ASSIMP_SRC_DIR"
tar -xzf "$TARBALL" --strip-components=1 -C "$ASSIMP_SRC_DIR"
[[ -f "${ASSIMP_SRC_DIR}/CMakeLists.txt" ]] || die "解压后缺少 CMakeLists.txt"

if grep -q 'bool isDone()' "${ASSIMP_SRC_DIR}/code/AssetLib/Obj/ObjFileParser.h"; then
  log "补丁已应用，跳过"
else
  ( cd "$ASSIMP_SRC_DIR" && git apply --check "$PATCH" ) \
    || ( cd "$ASSIMP_SRC_DIR" && patch -p1 --dry-run --forward < "$PATCH" ) \
    || die "补丁 ${ASSIMP_PATCH_REL} 无法应用到上游 ${ASSIMP_TAG}"
  ( cd "$ASSIMP_SRC_DIR" && git apply "$PATCH" ) \
    || ( cd "$ASSIMP_SRC_DIR" && patch -p1 --forward < "$PATCH" ) \
    || die "补丁应用失败"
fi
grep -q 'bool isDone()' "${ASSIMP_SRC_DIR}/code/AssetLib/Obj/ObjFileParser.h" \
  || die "补丁应用后仍缺少 ObjFileParser::isDone()"

tarball_sha="$(sha256sum "$TARBALL" | awk '{print $1}')"
patch_sha="$(sha256sum "$PATCH" | awk '{print $1}')"
python3 - "${ASSIMP_REPORT_DIR}" "${ASSIMP_VERSION}" "${ASSIMP_TAG}" \
          "${tarball_sha}" "${patch_sha}" "${ASSIMP_SRC_DIR}" <<'PY'
import datetime, json, os, sys
rep, version, tag, tsha, psha, src = sys.argv[1:7]
data = {
    'stage': 'ASSIMP_STAGE_1_SOURCE',
    'version': version, 'tag': tag,
    'tarball_sha256': tsha, 'patch_sha256': psha,
    'source_dir': src,
    'file_count': sum(len(f) for _, _, f in os.walk(src)),
    'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'verdict': 'PASS',
}
with open(os.path.join(rep, 'assimp-source.json'), 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
print(json.dumps(data, ensure_ascii=False, indent=2))
PY

printf '%s %s\n' "$tarball_sha" "$patch_sha" > "$STAMP"
stage_marker ASSIMP_STAGE_1_SOURCE_OK PASS "${ASSIMP_REPORT_DIR}/assimp-source-ok.json"
info "ASSIMP SOURCE PASS"
