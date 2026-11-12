# 上游依据（已在线核验，2026-11-12）

本工程所有"版本/标签/依赖下限"均来自 QGIS 官方，未虚构。

| 事实 | 值 | 核验来源 |
|---|---|---|
| 发布 tag | `final-3_34_12`（带注释 tag 对象 `526ce8a48f32b31ec03efec74407f3da25c858a0`） | `https://api.github.com/repos/qgis/QGIS/git/ref/tags/final-3_34_12` |
| tag 指向的 commit | `eeb6af363865e463b8f058b7d79fd5378c4bf065` | `https://api.github.com/repos/qgis/QGIS/git/tags/526ce8a48f32b31ec03efec74407f3da25c858a0` |
| 发布时间 | 2024-10-25T12:24:10Z | `https://api.github.com/repos/qgis/QGIS/releases/tags/final-3_34_12` |
| 版本三元组 | `3 / 34 / 12`，RELEASE_NAME `Prizren` | `CMakeLists.txt` @ `final-3_34_12` |
| CMake 最低 | 3.12.0 | 同上，`cmake_minimum_required` |
| Qt5 最低 | 5.14.0 | 同上，`QT_MIN_VERSION` |
| Python 最低 | 3.7 | 同上，`MIN_PYTHON_VERSION` |
| Flex | 2.6 REQUIRED | 同上，`find_package(FLEX 2.6 REQUIRED)` |
| 默认开关 | `WITH_3D/WITH_BINDINGS/WITH_DESKTOP/WITH_GUI/WITH_ANALYSIS=TRUE`，`WITH_SERVER=FALSE`，`WITH_QTWEBKIT=TRUE`（REQUIRED Qt5WebKit），`WITH_QTSERIALPORT=TRUE`，`WITH_PDAL/DRACO/GRASS=TRUE` | 同上 |
| PyQGIS 安装 | `BINDINGS_GLOBAL_INSTALL` 控制是否装到 `Python_SITEARCH` | 同上 |
| 官方依赖下限表 | CMake>=3.12, Flex>=2.5.6, Bison>=2.4, Python>=3.7, Qt>=5.14, Proj>=7.2, GEOS>=3.9, Sqlite3>=3.0, SpatiaLite>=4.2, GDAL>=3.2, Qwt>=5.0, expat>=1.95, qtkeychain>=0.5 | `https://raw.githubusercontent.com/qgis/QGIS/release-3_34/INSTALL.md` |
| 官方 RPM 构建脚本 | `rpm/buildrpms.sh`（`git archive --prefix=qgis-$version/ \| bzip2` + mock + SRPM） | `final-3_34_12/rpm/buildrpms.sh` |
| 官方 SPEC 模板 | `rpm/qgis.spec.template`（Fedora 口径，`%cmake`、`%files` 固定清单、GRASS/Server 分包） | `final-3_34_12/rpm/qgis.spec.template` |
| Fedora 38 依赖包表 | QGIS 官方 INSTALL.md §3.11.1，本工程 `capabilities.tsv` 的**候选名**来源 | 同上 |

## 我们如何"优先采用官方脚本与官方依赖"

1. **源码**：只用官方 GitHub tag `final-3_34_12`，并双重校验 commit 与
   `CMakeLists.txt` 版本三元组；不下载任何第三方镜像/其它版本。
2. **源码打包**：完全复用官方 `rpm/buildrpms.sh` 的
   `git archive --format=tar --prefix=qgis-$version/ HEAD | bzip2` 方式生成 `Source0`。
3. **SPEC**：以官方 `rpm/qgis.spec.template` 为蓝本，保留其
   `%build` 开关口径、`BINDINGS_GLOBAL_INSTALL=TRUE`、分包设计；
   针对麒麟做下列**明确记录的适配**：
   - 去掉 Fedora 专用宏（`%cmake` / `%cmake_build` / `%cmake_install` / `%find_lang --with-qt`），
     改显式 `cmake` + `make`；
   - 去掉官方 `Source1..6`（server httpd/nginx/mime 配置），因为本工程 `WITH_SERVER=FALSE`；
   - 去掉 `mock` 的 Fedora chroot，改在**同一个 Kylin V10 容器**里 `rpmbuild -ba`，
     保证 ABI / glibc / 依赖体系一致；
   - 关闭麒麟通常不具备的 QtWebKit / PDAL / Draco / GRASS / Server / OpenCL；
   - `%files` 改为按真实安装树动态生成，避免把 Fedora 文件清单硬套到麒麟；
   - `BuildRequires/Requires` 由麒麟实测依赖矩阵注入，而不是照抄 Fedora 包名。
4. **依赖**：一律来自麒麟 V10 原生 RPM 仓库（或由麒麟原生工具链产出的叠加 RPM 仓库），
   **不存在**任何 Ubuntu/Debian 二进制、`alien` / `fpm` 转换或打包系统库的行为
   （SPEC 明确 `QGIS_INSTALL_SYS_LIBS=FALSE`）。

## 未采用官方做法的地方及原因

| 官方做法 | 本工程 | 原因 |
|---|---|---|
| `mock -r fedora-XX-x86_64 --rebuild` | `rpmbuild -ba` 直接在 Kylin 容器 | mock 的 chroot 配置是 Fedora 的，对麒麟不适用 |
| 官方 spec 固定 `%files` 清单 | 动态生成 | QGIS 3.34.12 在麒麟上实际安装的文件集合与 Fedora 不同 |
| 官方 spec 启用 GRASS/Server/PDAL | 关闭 | 这些依赖在麒麟源上未确认，且不是本次交付目标 |
| 官方 spec 使用 `%{?dist}` | 固定 `1.<KYLIN_DIST_TAG>` | 麒麟 rpm 未必定义 `dist` 宏 |
