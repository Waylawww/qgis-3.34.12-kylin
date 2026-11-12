# 必须先确认的参数（不要虚构，不要假设编译一定成功）

> 本工程**已经写好全部可执行代码**，但下列参数在拿到真实的银河麒麟 V10 (Halberd)
> 环境之前无法凭空确定。工程用 `__UNCONFIRMED__` 占位，并由
> `scripts/00-preflight.sh` 强制拦截：任何一个必需参数未确认，CI 直接失败，
> **不会产出一个"看起来成功"的 RPM**。

请把本文件当作验收清单。每确认一项，就在右侧记录来源（命令输出 / 官方链接 / 镜像 digest）。

---

## 1. 麒麟 V10 基础镜像（最高优先级，且没有官方公开保证）

| 参数 | 需要确认的内容 | 获取方式 |
|---|---|---|
| `KYLIN_BASE_IMAGE` | 是否存在可用于 Docker 的**银河麒麟高级服务器操作系统 V10 (Halberd) x86_64** 镜像；registry / namespace / tag / digest | 向麒麟官方或镜像提供方确认；`docker pull <image>`；`docker inspect --format='{{index .RepoDigests 0}}'` |
| `KYLIN_BASE_IMAGE_DIGEST` | `sha256:...`，用于可复现构建 | 同上 |
| glibc / gcc / rpm 版本 | 决定 GLIBC 符号上限与 C++17 能力 | 容器内 `ldd --version`、`gcc -dumpfullversion -dumpversion`、`rpm --version` |

**已知风险**：Kylin V10 属于商业发行版，公开 Docker Hub 上通常**没有**可合法拉取的官方镜像。
本工程提供两条路径：

- **路径 A（推荐）**：由你方提供私有/GHCR 镜像，填入 `KYLIN_BASE_IMAGE`（必须为 RPM/dnf 体系）。
- **路径 B（兜底）**：用官方 ISO 生成 rootfs：
  `scripts/bootstrap/10-make-rootfs.sh` → `docker/Dockerfile.bootstrap` → push 私有仓库。
  该脚本会打印 ISO 内实际发现的 `repodata` 目录，不假设 `BaseOS/AppStream` 布局；
  最小包集合与 `--repofrompath` 需按实际 ISO 调整，**此路径不保证一次成功**。

> 严禁使用 Ubuntu/Fedora 镜像编译后 `alien`/`fpm` 转 RPM：
> glibc、Qt、PROJ/GDAL ABI 与麒麟不一致，即使能装上也无法运行。

---

## 2. 软件源（repo）定义

| 参数 | 需要确认的内容 |
|---|---|
| `KYLIN_REPO_FILE_URL` | 目标机 `/etc/yum.repos.d/*.repo` 的可访问 URL；确认 `baseurl`、`gpgkey`、`gpgcheck`、`enabled`、repo id |
| `KYLIN_EXTRA_REPO_URLS` | 是否需要 EPOL / Update / PowerTools / 自建"依赖叠加源" |
| `KYLIN_REPO_GPGCHECK` | 是否允许 `--nogpgcheck`；GPG key 的 URL |
| `KYLIN_PACKAGE_MANAGER` | `dnf`、`yum` 还是 `microdnf`（由 probe 自动采集） |
| 网络可达性 | GitHub Actions runner 是否能访问麒麟源（商业源常有授权/白名单/限速） |

验证命令（在真实麒麟环境里）：

```bash
cat /etc/os-release; cat /etc/kylin-release
cat /etc/yum.repos.d/*.repo
(dnf -q repolist || yum -q repolist)
dnf -q repoquery --whatprovides 'pkgconfig(Qt5Core)'
```

---

## 3. QGIS 3.34.12 的官方依赖下限（**已核实，无需再确认**）

来源：QGIS 官方 `INSTALL.md`（release-3_34）与 `final-3_34_12/CMakeLists.txt`。

| 依赖 | 官方下限 | 来源 |
|---|---|---|
| CMake | >= 3.12.0 | `cmake_minimum_required(VERSION 3.12.0)` |
| Flex | >= 2.6.0 | `find_package(FLEX 2.6 REQUIRED)`（INSTALL.md 写 2.5.6，以源码为准） |
| Bison | >= 2.4 | INSTALL.md |
| Python | >= 3.7 | `MIN_PYTHON_VERSION "3.7"` |
| Qt5 | >= 5.14.0 | `QT_MIN_VERSION 5.14.0` |
| PROJ | >= 7.2.0 | INSTALL.md |
| GEOS | >= 3.9 | INSTALL.md |
| GDAL/OGR | >= 3.2.0 | INSTALL.md |
| SpatiaLite | >= 4.2.0 | INSTALL.md |
| Sqlite3 | >= 3.0.0 | INSTALL.md |
| Qwt | >= 5.0（且 < 6.1，若用内部 QwtPolar） | INSTALL.md |
| qtkeychain | >= 0.5 | INSTALL.md |
| expat | >= 1.95 | INSTALL.md |

CMakeLists 里还有 `find_package(... REQUIRED)` 但未声明版本下限的：
`Proj / GEOS / GDAL / EXPAT / Spatialindex / LibZip / Sqlite3 / Protobuf(+protoc) /
ZLIB / EXIV2 / SpatiaLite / QScintilla / Qwt / QtKeychain / QCA / GSL / SIP / PyQt5 / Qsci /
Qt5(3DCore,3DRender,3DInput,3DLogic,3DExtras)`。

**这些下限是官方事实，但麒麟源里"有没有、叫什么名字、是什么版本"必须实测。**

---

## 4. 依赖包名映射与版本（由 `probe-kylin.yml` / `probe-kylin.py` 自动确认）

`config/capabilities.tsv` 里给的是 **Fedora/RHEL 风格的候选名**（来自 QGIS 官方
`rpm/qgis.spec.template` 和官方 `INSTALL.md` 的 Fedora 38 依赖表），**不是麒麟的真实包名**。
真实映射必须由脚本在麒麟环境里用 `repoquery --whatprovides` 解析：

```bash
# 云端：Actions -> "Probe Kylin V10 dependency matrix" -> Run workflow
# 本地/Codespaces（在麒麟容器内）：
python3 scripts/probe-kylin.py --write
cat reports/dependency-matrix.json
```

必须确认的输出：

- `DEP_*` 每一项都解析成麒麟源里真实存在的 RPM 包名；
- `qgis_buildrequires` / `qgis_runtime_requires` 非空；
- `unresolved_required = []`；
- `version_failures = []`；
- `system.KYLIN_PYTHON3_SITEARCH`、`system.KYLIN_MACRO_LIBDIR` 有值。

### 最关键的兼容性风险（很可能触发）

Kylin V10 内核 4.19 / 用户态偏旧，**Qt 很可能 < 5.14，PROJ / GEOS / GDAL 很可能低于官方下限**。
如果出现 `version_failures`，**不要**降低 QGIS 版本，**不要**改用 Ubuntu 二进制。正确做法是二选一：

1. 使用麒麟官方/授权的更新源（若提供 Qt 5.15、PROJ >= 7.2、GEOS >= 3.9、GDAL >= 3.2）；
2. 用**麒麟原生工具链**把这些依赖从源码打成 RPM，建立"依赖叠加仓库"，
   通过 `KYLIN_EXTRA_REPO_URLS` 注入；QGIS 与叠加 RPM 必须同一编译器/同一 glibc 构建。

本工程提供 `scripts/check-deps.py` 作为构建镜像内的硬门禁，版本不达标直接失败。

---

## 5. rpm 宏 / 打包口径

| 参数 | 需要确认 | 验证命令 |
|---|---|---|
| `%{_libdir}` / `%{_lib}` | `lib64` 还是 `lib` | `rpm --eval '%{_libdir}'` |
| `%{python3_sitearch}` | PyQGIS 安装位置 | `rpm --eval '%{python3_sitearch}'` |
| `%{?dist}` | 是否定义 | `rpm --eval '%{?dist}'` |
| `%cmake` / `%find_lang --with-qt` | 是否存在 | 本工程**不使用**这些 Fedora 宏，改用显式 `cmake`/`make` |
| `rpmbuild` 版本 | 是否支持 `%files -f`、debuginfo 宏 | `rpm --version` |

> 官方 SPEC 里还有 `Source1..6`（server httpd/nginx 配置、mime xml）。
> 本工程关闭了 `WITH_SERVER`，因此**不引入**这些 Fedora 专属文件，避免虚构来源。

---

## 6. QEMU/KVM 目标系统验证镜像

| 参数 | 需要确认 |
|---|---|
| `KYLIN_QCOW2_URL` | 与目标机同版本的 Kylin V10 x86_64 qcow2 下载地址（建议放 Secrets，带签名 URL） |
| `KYLIN_QCOW2_SHA256` | 镜像校验和 |
| `cloud-init` + `sshd` | qcow2 内必须已安装并启用；否则 NoCloud seed 不生效 |
| `KYLIN_VM_SSH_USER` / `KYLIN_VM_SSH_PASSWORD` | cloud-init 创建的用户与口令（放 Secrets） |
| `KYLIN_XVFB_PACKAGE` | 目标系统里 Xvfb 的真实包名（用于 UKUI 会话验证） |
| UKUI 版本 / GPU 驱动 | 云端 VM 无 GPU 时无法验证 3D OpenGL 视图 |

**没有 qcow2 时**，流水线仍会产出 RPM，但 `STAGE_C = UNVERIFIED`，
`out/BUILD_REPORT.md` 会明确写出"不得宣称目标系统运行成功"。

**GitHub 托管 runner 的 `/dev/kvm` 不保证存在**：脚本自动降级为 TCG 软件模拟
（`-cpu qemu64`），并在报告中记录加速模式。若要 KVM，需自托管 runner 或大规格 runner
并确认 `ls -l /dev/kvm` 可读写。

---

## 7. 海光 Hygon C86-3G 的 CPU/固件事实（云端无法验证）

| 参数 | 需要确认 | 获取方式（真机） |
|---|---|---|
| `C86_CPU_MODEL` | 具体型号 | `lscpu`、`cat /proc/cpuinfo` |
| `C86_CPU_FLAGS` | 是否支持 AVX2 / AVX-512 / SHA 等 | `lscpu \| grep Flags` |
| `C86_GLIBC` | 目标机 glibc 版本（与镜像是否一致） | `ldd --version` |
| `C86_UKUI_VERSION` | UKUI 版本 | `rpm -qa \| grep -i ukui` |
| `C86_GPU_DRIVER` | 显卡驱动 / OpenGL 版本 | `glxinfo -B` |

本工程统一用 `-march=x86-64 -mtune=generic` 基线，不产生 AVX/AVX2/AVX-512 指令；
`scripts/check-isa.sh` 会反汇编 QGIS 自身 ELF 校验这一点。
**但依赖库（Qt/GDAL/PROJ）由麒麟官方 RPM 提供，其运行时 SIMD 分发不在本工程控制范围内**，
这一点必须在真机确认。

---

## 8. CI 资源与配额

| 参数 | 需要确认 |
|---|---|
| 磁盘 | GitHub 托管 runner 通常仅 14~25GB 可用；QGIS 全量编译需 25~40GB。必要时换 larger runner / 自托管 runner |
| 时长 | 单 job 上限 360 分钟；TCG 软件模拟下 VM 启动很慢，预留 `VM_BOOT_TIMEOUT_SEC=900` |
| Artifact | RPM 体积、retention（默认 90 天）、是否改用 Releases 长期保存 |
| 私有源凭据 | `KYLIN_REGISTRY_USERNAME` / `KYLIN_REGISTRY_TOKEN` / repo 访问白名单 |

---

## 确认完成后的落地动作

```bash
# 1. 把 probe 生成的 4 个文件放进仓库并提交（它们不含密钥）
#    config/kylin.confirmed.env
#    config/deps.confirmed.env
#    packaging/generated/buildrequires.inc
#    packaging/generated/runtime-requires.inc
git add config/*.confirmed.env packaging/generated/*.inc
git commit -m "chore: confirm Kylin V10 dependency matrix"

# 2. 在 GitHub 仓库 Settings 中配置
#    Variables: KYLIN_BASE_IMAGE, KYLIN_REPO_FILE_URL, KYLIN_EXTRA_REPO_URLS,
#               KYLIN_QCOW2_SHA256, KYLIN_VM_SSH_USER, VM_REQUIRE_KVM
#    Secrets:   KYLIN_QCOW2_URL, KYLIN_VM_SSH_PASSWORD,
#               KYLIN_REGISTRY_USERNAME, KYLIN_REGISTRY_TOKEN

# 3. 本地门禁
bash scripts/00-preflight.sh --ci
```

只有做完这些，`build.yml` 才会真正开始编译。
