# QGIS 3.34.12 · 银河麒麟 V10 (Halberd) · 海光 C86-3G · 云端 RPM 构建工程

完全基于 **GitHub Codespaces（开发）+ GitHub Actions（构建/验证）+ Docker（固定环境）+ QEMU/KVM（目标系统验证）**，
不依赖麒麟物理机。源码严格锁定 QGIS 官方 `final-3_34_12`（commit
`eeb6af363865e463b8f058b7d79fd5378c4bf065`），构建 **Qt5 + PyQGIS + 3D 的 QGIS Desktop 原生 RPM**。

---

## 0. 先说清楚：哪些参数尚未确认，工程不会假装成功

> 以下是**必须由你提供/在真实麒麟环境实测**的参数。在它们被确认前，
> `scripts/00-preflight.sh` 会让流水线直接失败，**不会产出"看起来成功"的 RPM**。
> 完整清单与获取方法见 **[`docs/CONFIRM.md`](docs/CONFIRM.md)**。

| # | 待确认参数 | 为什么不能猜 |
|---|---|---|
| 1 | `KYLIN_BASE_IMAGE` + digest | Kylin V10 是商业发行版，公开 Docker Hub 上通常**没有**可合法拉取的官方镜像；必须用私有/GHCR 镜像，或从官方 ISO 生成 rootfs（`scripts/bootstrap/10-make-rootfs.sh`） |
| 2 | 麒麟软件源 `.repo` URL / repo id / GPG key / 是否含 EPOL、Update、PowerTools，以及 Actions runner 是否可达 | 商业源常有授权与白名单，URL 与 gpgkey 无法虚构 |
| 3 | 各依赖在麒麟源里的**真实 RPM 包名**与**真实版本** | `config/capabilities.tsv` 里是 QGIS 官方 Fedora 表的**候选名**，不是麒麟包名；由 `probe-kylin.py` 用 `repoquery --whatprovides` 实测解析 |
| 4 | 麒麟源是否能满足官方下限：**Qt>=5.14 / PROJ>=7.2 / GEOS>=3.9 / GDAL>=3.2**（以及 Qt5 3D 开发包、SIP/PyQt5/Qsci） | Kylin V10 内核 4.19、用户态偏旧，很可能不满足；若不满足必须建立"麒麟原生工具链产出的依赖叠加 RPM 仓库"，**禁止**用 Ubuntu 二进制或降 QGIS 版本 |
| 5 | rpm 宏：`%{_libdir}`、`%{python3_sitearch}`、`%{?dist}`、`rpmbuild` 版本 | 决定 `QGIS_LIB_SUBDIR`、`%files` 清单与 Release 字段 |
| 6 | 目标系统 QEMU 镜像：`KYLIN_QCOW2_URL` / SHA256 / 是否已装 cloud-init + sshd / Xvfb 包名 / UKUI 版本 | 没有它，`STAGE_C` 明确标记 `UNVERIFIED`，不得宣称目标系统运行成功 |
| 7 | `/dev/kvm` 是否可用 | GitHub 托管 runner 不保证；脚本自动降级 TCG 并记录加速模式 |
| 8 | 海光 C86-3G 的 `lscpu` flags、目标机 glibc、UKUI/GPU 驱动 | 云端**永远无法验证**，恒标 `UNVERIFIED` |
| 9 | CI 磁盘/时长/Artifact 配额、私有仓库凭据 | QGIS 全量编译需 25~40GB、可达数小时 |

**已核实、无需再确认的事实**：QGIS tag/commit、版本三元组、CMake/Qt/Python/PROJ/GEOS/GDAL
等官方最低版本、官方 `rpm/qgis.spec.template` 与 `rpm/buildrpms.sh` 内容 —— 见
[`docs/UPSTREAM.md`](docs/UPSTREAM.md) 与 `config/build.env`。

**本工程不承诺**：麒麟源一定满足依赖下限、编译一定一次通过、RPM 一定能在海光 C86 真机运行。
它承诺的是：**把每一次"成功/未验证/失败"如实分层记录，并给出可执行的定位路径**。

---

## 1. 三层验证的严格区分

| 阶段 | 含义 | 证据 |
|---|---|---|
| `STAGE_A` | 源码在麒麟原生工具链上**编译成功** | `QGIS_STAGE_A_SOURCE_BUILD_OK`、`reports/CMakeCache.txt` |
| `STAGE_B` | **RPM 软件包构建成功**并通过静态校验 | `qgis-3.34.12-*.rpm`、`rpm-verification.json`、`isa-report.json` |
| `STAGE_B2` | 全新麒麟**容器**中安装/启动/离屏渲染 | `container-runtime.json`、`render.png`（**不是 VM**） |
| `STAGE_C` | **目标系统实际运行成功**：QEMU/KVM 真实麒麟 V10 VM | `target-vm-runtime.json`、`out/evidence/vm/*` |
| `STAGE_D` | 海光 C86 真机 / UKUI GPU / 3D OpenGL 视图 | **恒为 `UNVERIFIED`**，附真机验收命令 |

容器运行 ≠ 虚拟机运行 ≠ 物理机运行。详见 [`docs/STAGES.md`](docs/STAGES.md)。

---

## 2. 项目目录结构

```
.
├── .devcontainer/
│   └── devcontainer.json              # Codespaces：以麒麟构建镜像为开发容器
├── .github/workflows/
│   ├── build.yml                      # 主流水线：门禁→编译→打包→容器运行→VM→发布
│   └── probe-kylin.yml                # 云端探测麒麟真实依赖矩阵
├── config/
│   ├── build.env                      # 已核验的 QGIS 版本/依赖下限/ISA 基线（锁死）
│   ├── capabilities.tsv               # 能力→候选 RPM 名→最低版本（数据驱动）
│   ├── kylin.env.example              # 【待确认】麒麟环境参数模板
│   └── deps.env.example               # 【待确认】依赖映射格式示例
├── docker/
│   ├── Dockerfile.kylin               # 麒麟原生构建镜像（FROM ${KYLIN_BASE_IMAGE}）
│   ├── Dockerfile.probe               # 轻量依赖探测镜像
│   ├── Dockerfile.bootstrap           # 从 ISO 生成的 rootfs 打成基础镜像
│   └── entrypoint.sh                  # build / test-install / verify / shell
├── packaging/
│   ├── qgis-kylin.spec.in             # 基于 QGIS 官方 spec 模板改写的 SPEC 模板
│   └── generated/                     # probe 生成的 BuildRequires / Requires 行
├── scripts/
│   ├── lib/common.sh                  # 公共函数与占位符门禁
│   ├── probe-kylin.py                 # 在真实麒麟上解析依赖矩阵（核心）
│   ├── check-deps.py                  # 安装后依赖版本硬门禁
│   ├── render-spec.py                 # 渲染 SPEC（拒绝未替换占位符）
│   ├── install-builddeps.sh           # 安装麒麟原生构建依赖
│   ├── check-isa.sh                   # AVX/AVX-512、RPATH、GLIBC 符号校验
│   ├── 00-preflight.sh                # 参数门禁 + 官方 tag 在线核验
│   ├── 10-fetch-source.sh             # 锁定 3.34.12 源码 + 官方 git archive 打包
│   ├── 20-render-spec.sh              # 渲染 SPEC + rpmbuild 目录树
│   ├── 30-rpmbuild.sh                 # 原生全量编译 + rpmbuild
│   ├── 40-verify-rpm.sh               # RPM 静态校验
│   ├── 50-test-install.sh             # 全新容器安装/启动/渲染
│   ├── 60-test-qemu-vm.sh             # QEMU/KVM 目标系统验证
│   ├── 70-collect-evidence.sh         # 分层验证报告
│   ├── build-all.sh                   # 容器内一键 00→40
│   ├── devcontainer-init.sh / devcontainer-postcreate.sh
│   ├── ci-free-space.sh               # runner 磁盘清理
│   └── bootstrap/10-make-rootfs.sh    # 官方 ISO → rootfs（兜底）
├── tests/
│   ├── pyqgis_smoke.py                # 离屏 PyQGIS 地图渲染测试
│   ├── cloud-init/{user-data,meta-data}.tpl
│   └── vm/run-in-vm.sh                # VM 内安装/启动/渲染脚本
├── docs/
│   ├── CONFIRM.md                     # 【必读】待确认参数清单
│   ├── STAGES.md                      # 【必读】各阶段命令/预期/常见错误
│   ├── C86-COMPATIBILITY.md           # C86 与云端不可验证项
│   └── UPSTREAM.md                    # 官方依据与 SPEC 适配说明
├── Makefile
└── README.md
```

---

## 3. 部署与运行（完整步骤）

### 步骤 0 · 建仓与配置

```bash
git clone <your-repo> && cd qgis-3.34.12-kylin-c86-build
```

在 GitHub 仓库 `Settings → Secrets and variables → Actions / Codespaces` 中配置：

| 类型 | 名称 | 说明 |
|---|---|---|
| Variable | `KYLIN_BASE_IMAGE` | Kylin V10 x86_64 RPM 基础镜像，建议带 `@sha256:...` |
| Variable | `KYLIN_TEST_IMAGE` | 可选；全新安装测试用镜像，默认同 `KYLIN_BASE_IMAGE` |
| Variable | `KYLIN_REPO_FILE_URL` | 可选，麒麟 `.repo` 文件 URL |
| Variable | `KYLIN_EXTRA_REPO_URLS` | 可选，逗号分隔的依赖叠加源 |
| Variable | `KYLIN_QCOW2_SHA256` / `KYLIN_VM_SSH_USER` / `VM_REQUIRE_KVM` | VM 验证参数 |
| Variable | `KYLIN_REGISTRY` | 可选，私有仓库地址（如 `ghcr.io`） |
| Secret | `KYLIN_QCOW2_URL` | 目标系统 qcow2 下载地址（签名 URL） |
| Secret | `KYLIN_VM_SSH_PASSWORD` | cloud-init 用户口令 |
| Secret | `KYLIN_REGISTRY_USERNAME` / `KYLIN_REGISTRY_TOKEN` | 私有仓库凭据 |

### 步骤 1 · 云端确认麒麟依赖（**必须先做**）

```
GitHub → Actions → "Probe Kylin V10 dependency matrix" → Run workflow
  base_image       : <KYLIN_BASE_IMAGE>
  repo_file_url    : <可选>
  extra_repos      : <可选>
  allow_unverified : true（先看诊断报告）
```

下载 artifact `kylin-dependency-matrix`，审阅 `dependency-matrix.json`：

```bash
python3 -c "import json;d=json.load(open('reports/dependency-matrix.json'));\
print(d['verdict'], d['unresolved_required'], d['version_failures'])"
```

- `PASS` / `[]` / `[]` → 把 4 个文件提交入库：
  ```bash
  git add config/*.confirmed.env packaging/generated/*.inc
  git commit -m "chore: confirm Kylin V10 dependency matrix"
  ```
- 有 `VERSION-TOO-OLD` → 按 [`docs/CONFIRM.md` 第 4 节](docs/CONFIRM.md) 建依赖叠加 RPM 仓库，
  **不要**改成 Ubuntu 产物，也不要改 QGIS 版本。

### 步骤 2 · Codespaces 开发（可选）

打开仓库 → `Code → Codespaces → Create codespace`。`devcontainer.json` 会用同一个
`Dockerfile.kylin` 拉起麒麟构建容器（Codespaces 变量里也要有 `KYLIN_BASE_IMAGE`）。

```bash
make help
python3 scripts/probe-kylin.py --write     # 也可在 Codespaces 里直接探测
bash scripts/00-preflight.sh --container
bash scripts/build-all.sh                  # 全量编译（数小时，建议交给 Actions）
```

> Codespaces **不提供 `/dev/kvm`**，QEMU 验证请走 Actions。

### 步骤 3 · GitHub Actions 自动构建

```
GitHub → Actions → "QGIS 3.34.12 / Kylin V10 / x86_64 RPM" → Run workflow
```

或 `git push` / `git tag v3.34.12-kylin10 && git push --tags`。

流水线 job：

```
0 preflight  →  A+B build  →  B2 test-install  →  C test-vm  →  D publish
（参数门禁）   （原生编译+打包） （全新容器运行）   （QEMU 真 VM）  （证据+Artifacts+Release）
```

### 步骤 4 · 获取产物

- Artifact `qgis-3.34.12-rpms`：3 个二进制 RPM
- Artifact `qgis-3.34.12-srpms`：源码 RPM
- Artifact `qgis-3.34.12-final-bundle`：RPM + `verification-status.json` + `BUILD_REPORT.md` + 全部证据
- Tag 推送时自动创建 GitHub Release，附 RPM 与验证报告

在目标机安装：

```bash
sudo dnf install -y ./qgis-3.34.12-*.rpm ./python3-qgis-3.34.12-*.rpm
qgis --version
python3 -c 'from qgis.core import Qgis; print(Qgis.QGIS_VERSION)'
```

---

## 4. 分阶段验证命令速查

| 阶段 | 命令 | 预期结果 |
|---|---|---|
| -1 依赖探测 | `python3 scripts/probe-kylin.py --write` | `verdict=PASS unresolved=[] version_failures=[]` |
| 0 门禁 | `PREFLIGHT_ONLINE=1 bash scripts/00-preflight.sh --ci` | `PREFLIGHT PASS` |
| 1 源码 | `bash scripts/10-fetch-source.sh` | `源码版本校验通过: 3.34.12` + tarball sha256 |
| 2 SPEC | `bash scripts/20-render-spec.sh` | 无 `@TOKEN@` 残留，`Version=3.34.12` |
| 3 编译打包 | `bash scripts/30-rpmbuild.sh` | `QGIS_STAGE_A_SOURCE_BUILD_OK` + `QGIS_STAGE_B_INSTALL_OK` + 3 个 RPM |
| 4 静态校验 | `bash scripts/40-verify-rpm.sh` | `VERIFY RPM PASS`，`avx512_files=[]`、`glibc_too_new=[]` |
| 5 容器运行 | `bash scripts/50-test-install.sh` | `FRESH CONTAINER RUNTIME PASS`，`render.png` 非空白 |
| 6 VM 运行 | `bash scripts/60-test-qemu-vm.sh` | `STAGE_C PASS` 或明确 `UNVERIFIED` |
| 7 汇总 | `bash scripts/70-collect-evidence.sh` | `out/verification-status.json` + `BUILD_REPORT.md` |

**每个阶段的验证命令、预期输出和常见错误处理（含具体报错文本与修复动作）见
[`docs/STAGES.md`](docs/STAGES.md)。**

---

## 5. 关键设计决策

1. **不用 Ubuntu 产物包装成 RPM**：`Dockerfile.kylin` 的 `FROM` 就是 Kylin V10 镜像；
   依赖按麒麟实测包名由 `dnf/yum` 安装；SPEC 显式 `QGIS_INSTALL_SYS_LIBS=FALSE`；
   `40-verify-rpm.sh` 会拒绝任何 Debian 体系文件；`preflight` 会拒绝 Debian 包名。
2. **优先复用官方**：源码用官方 tag + 官方 `git archive` 方式；SPEC 以官方
   `rpm/qgis.spec.template` 为蓝本；依赖下限全部取自官方 `INSTALL.md` / `CMakeLists.txt`。
   差异与原因逐条记录在 [`docs/UPSTREAM.md`](docs/UPSTREAM.md)。
3. **严格锁定 3.34.12**：`config/build.env` 固定 tag 与 commit；三处独立校验
   （`git ls-remote` → `rev-parse` → `CMakeLists.txt` 版本三元组），任何不符立即失败。
4. **CPU 基线**：`-march=x86-64 -mtune=generic`，禁用 OpenCL / Qt6；
   `check-isa.sh` 反汇编校验无 AVX-512、无构建机 RPATH、GLIBC 符号不越界；
   QEMU 用 `-cpu qemu64` 再实测一次。
5. **不假设麒麟源可用**：`probe` → `check-deps.py` → `cmake` 三道门禁；
   缺依赖时给出"叠加 RPM 仓库"路径，而不是悄悄降级功能或换发行版。
6. **不假设 `/dev/kvm`**：自动降级 TCG，并把加速模式写进报告。

---

## 6. 云端无法验证的 C86 特定问题（明确标注）

- Hygon C86-3G 的微架构、CPUID 特性位、固件与 `4.19.90-89.11.v2401.ky10` 内核补丁；
- 麒麟官方 Qt/GDAL/PROJ RPM 内部的运行时 SIMD 分发（不在本工程编译范围）；
- UKUI 图形会话、中文字体/主题、国产 GPU 驱动与 3D OpenGL 视图；
- 真机 glibc 与基础镜像 glibc 的一致性（本工程只做符号版本上限静态校验）。

这些都写在 `out/verification-status.json` 的 `STAGE_D_C86_HARDWARE_RUNTIME`
（恒为 `UNVERIFIED`）并附真机验收命令。详见
[`docs/C86-COMPATIBILITY.md`](docs/C86-COMPATIBILITY.md)。

> **结论表述规范**：没跑 `STAGE_C` 时只能说"RPM 构建成功"；跑了 `STAGE_C` 才能说
> "在麒麟 V10 虚拟机中安装运行成功"；只有真机人工验收后才能说
> "可在海光 C86 麒麟 V10 上运行"。

---

## 7. 常见错误速查（完整版见 STAGES.md）

| 现象 | 处理 |
|---|---|
| `docker build` 在 `FROM` 处失败 | `KYLIN_BASE_IMAGE` 未设置；见 `docs/CONFIRM.md` 第 1 节 |
| `Could NOT find Qt5WebKit / PDAL / Draco / GRASS` | SPEC 已关闭这些开关，检查是否被误改 |
| `VERSION-TOO-OLD: qt5core` | 麒麟 Qt 太旧；建依赖叠加 RPM 仓库，不许换 Ubuntu/降 QGIS |
| `GLIBC_2.xx not found` / `glibc_too_new` | 构建镜像比目标机新；换同版本基础镜像，**不要**放宽判定 |
| `ld terminated with signal 9` | 并行编译 OOM；`QGIS_BUILD_JOBS=2` |
| `No space left on device` | `bash scripts/ci-free-space.sh` / larger runner |
| `Installed (but unpackaged) file(s)` | 修 `%install` 的 `classify()` 动态清单，不靠 `%exclude` 硬糊 |
| `qt.qpa.plugin "xcb"` | 设 `QT_QPA_PLATFORM=offscreen` |
| VM 无 sshd / 超时 | qcow2 缺 cloud-init；看 `work/vm/serial.log` |
| `/dev/kvm` 不存在 | 正常，自动 TCG；要 KVM 用自托管 runner |

---

## 8. 许可与合规

- QGIS 源码遵循 GPLv2+，RPM 包 `License: GPL-2.0-or-later`；
- 分发 Kylin V10 基础镜像/ISO、商业软件源凭据前请确认你的授权；
- 不要把私有镜像、qcow2 下载 URL、SSH 口令写进仓库，一律用 GitHub Secrets。
