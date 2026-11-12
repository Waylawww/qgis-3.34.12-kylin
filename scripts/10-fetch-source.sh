#!/usr/bin/env bash
# 阶段 1：从 QGIS 官方 GitHub 仓库获取且仅获取 3.34.12，并按官方 rpm/buildrpms.sh
#        的方式用 `git archive --prefix=qgis-$version/` 生成源码 tarball。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env
need_cmd git "拉取 QGIS 官方源码"
need_cmd bzip2 "官方 buildrpms.sh 使用 bzip2 压缩源码"
need_cmd sha256sum "生成源码指纹"

SRC="${WORK_DIR}/src/QGIS"
SOURCES="${WORK_DIR}/rpmbuild/SOURCES"
mkdir -p "${SOURCES}" "${REPORT_DIR}/upstream"
rm -rf "${SRC}"

info "== 阶段 1 / FETCH SOURCE (严格锁定 ${QGIS_VERSION}) =="
log "clone ${QGIS_GIT_REPO} @ ${QGIS_GIT_TAG}"
git init -q "${SRC}"
git -C "${SRC}" remote add origin "${QGIS_GIT_REPO}"
git -C "${SRC}" fetch -q --depth 1 origin "refs/tags/${QGIS_GIT_TAG}:refs/tags/${QGIS_GIT_TAG}"
git -C "${SRC}" fetch -q --depth 1 origin "${QGIS_GIT_COMMIT}" || true

# 1) 带注释 tag 必须能解析到锁定的 commit
tag_commit="$(git -C "${SRC}" rev-parse "${QGIS_GIT_TAG}^{commit}")"
[[ "${tag_commit}" == "${QGIS_GIT_COMMIT}" ]] || \
  die "tag ${QGIS_GIT_TAG} -> ${tag_commit}，与锁定 commit ${QGIS_GIT_COMMIT} 不符"
git -C "${SRC}" checkout -q --detach "${QGIS_GIT_COMMIT}"
head_commit="$(git -C "${SRC}" rev-parse HEAD)"
[[ "${head_commit}" == "${QGIS_GIT_COMMIT}" ]] || die "HEAD 不是锁定的 3.34.12 commit"

# 2) 再次从源码 CMakeLists.txt 校验版本三元组，防止 tag 被替换
cmake_lists="${SRC}/CMakeLists.txt"
[[ -f "${cmake_lists}" ]] || die "源码缺少 CMakeLists.txt"
major="$(grep -E '^set\(CPACK_PACKAGE_VERSION_MAJOR' "${cmake_lists}" | grep -oE '[0-9]+' | head -n1)"
minor="$(grep -E '^set\(CPACK_PACKAGE_VERSION_MINOR' "${cmake_lists}" | grep -oE '[0-9]+' | head -n1)"
patch="$(grep -E '^set\(CPACK_PACKAGE_VERSION_PATCH' "${cmake_lists}" | grep -oE '[0-9]+' | head -n1)"
src_version="${major}.${minor}.${patch}"
[[ "${src_version}" == "${QGIS_VERSION}" ]] || \
  die "源码 CMakeLists.txt 版本为 ${src_version}，不是 ${QGIS_VERSION}；拒绝构建"
log "源码版本校验通过: ${src_version} ($(grep -E '^set\(RELEASE_NAME' "${cmake_lists}" | head -n1))"

# 3) 保留官方 RPM 构建脚本作为上游依据（不直接使用 Fedora/mock chroot）
cp -f "${SRC}/rpm/qgis.spec.template" "${REPORT_DIR}/upstream/qgis.spec.template"
cp -f "${SRC}/rpm/buildrpms.sh"        "${REPORT_DIR}/upstream/buildrpms.sh"
cp -f "${SRC}/rpm/default.cfg"         "${REPORT_DIR}/upstream/default.cfg"
cp -f "${SRC}/INSTALL.md"              "${REPORT_DIR}/upstream/INSTALL.md"

# 4) 官方 buildrpms.sh 的源码打包方式：git archive + bzip2
TARBALL="${SOURCES}/${QGIS_SOURCE_TARBALL}"
git -C "${SRC}" archive --format=tar --prefix="${QGIS_SOURCE_DIR_NAME}/" HEAD | bzip2 -9 > "${TARBALL}"
[[ -s "${TARBALL}" ]] || die "源码 tarball 生成失败"
sha="$(sha256_file "${TARBALL}")"

cat > "${WORK_DIR}/source-manifest.json" <<JSON
{
  "qgis_version": "${QGIS_VERSION}",
  "git_repo": "${QGIS_GIT_REPO}",
  "git_tag": "${QGIS_GIT_TAG}",
  "git_commit": "${head_commit}",
  "source_dir_name": "${QGIS_SOURCE_DIR_NAME}",
  "tarball": "${QGIS_SOURCE_TARBALL}",
  "tarball_sha256": "${sha}",
  "tarball_bytes": $(stat -c %s "${TARBALL}"),
  "upstream_rpm_spec": "rpm/qgis.spec.template",
  "upstream_rpm_build_script": "rpm/buildrpms.sh",
  "method": "git archive (same as QGIS official rpm/buildrpms.sh)"
}
JSON
cp -f "${WORK_DIR}/source-manifest.json" "${REPORT_DIR}/source-manifest.json"

info "FETCH SOURCE PASS —— ${QGIS_SOURCE_TARBALL} sha256=${sha}"
