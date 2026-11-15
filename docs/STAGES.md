# 分阶段验证命令、预期结果与常见错误处理

> **三层结论不能互相冒充**
>
> | 结论 | 由哪个阶段证明 | 证据文件 |
> |---|---|---|
> | ① 源码编译成功 | `STAGE_A`（rpmbuild `%build` 完成） | `reports/stages/stage-a.json`、`CMakeCache.txt`、`rpmbuild.log` 中的 `QGIS_STAGE_A_SOURCE_BUILD_OK` |
> | ② 软件包构建成功 | `STAGE_B` + `STAGE_B_STATIC_VERIFY` | `reports/stages/stage-b.json`、`rpm-verification.json`、`out/rpms/*.rpm` |
> | ③ 目标系统实际运行成功 | `STAGE_C`（真实麒麟 VM） | `reports/target-vm-runtime.json`、`out/evidence/vm/render.png` |
>
> `STAGE_B2`（容器安装运行）**只是**同用户态的便捷冒烟，不能替代 ③。
> `STAGE_D`（海光 C86 物理机 / UKUI GPU / 3D OpenGL）云端**永远 UNVERIFIED**。

---

## 阶段 -1 · 麒麟依赖探测（probe）

**命令**

```bash
# 云端：Actions -> Probe Kylin V10 dependency matrix -> Run workflow
# 或麒麟容器内：
python3 scripts/probe-kylin.py --write
cat reports/dependency-matrix.json
```

**预期结果**

```
verdict=PASS  unresolved=[]  version_failures=[]
```

生成 `config/kylin.confirmed.env`、`config/deps.confirmed.env`、
`packaging/generated/buildrequires.inc`、`packaging/generated/runtime-requires.inc`。

**常见错误**

| 现象 | 原因 / 处理 |
|---|---|
| `UNRESOLVED: qt5_3d` | 麒麟源里 Qt5 3D 开发包不叫 `qt5-qt3d-devel`。用 `dnf repoquery --whatprovides 'pkgconfig(Qt53DCore)'` 查真名，改 `config/capabilities.tsv` 的 `provides/candidates` 后重跑 |
| `VERSION-TOO-OLD: qt5core 5.11 < 5.14.0` | 麒麟源 Qt 过旧。不要降 QGIS 版本；按 `docs/CONFIRM.md` 第 4 节建立依赖叠加 RPM 仓库，通过 `KYLIN_EXTRA_REPO_URLS` 注入 |
| `dnf repoquery` 全部为空 | repo 未配置 / 网络不通 / GPG key 缺失。先 `curl` 检查 `KYLIN_REPO_FILE_URL`，再 `dnf -q repolist` |
| `KYLIN_PYTHON3_SITEARCH=__UNCONFIRMED__` | rpm 缺少 `python3-rpm-macros`。装它，或手工在 `kylin.confirmed.env` 填 `python3 -c 'import sysconfig;print(sysconfig.get_path("platlib"))'` 的结果 |

---

## 阶段 0 · 参数门禁（preflight）

**命令**

```bash
PREFLIGHT_ONLINE=1 bash scripts/00-preflight.sh --ci     # GitHub runner
bash scripts/00-preflight.sh --container                 # 构建容器内
```

**预期结果**

```
PREFLIGHT PASS —— 已确认参数齐全，可以继续
reports/preflight.json  {"result":"PASS","online_tag_verified":true,...}
```

**常见错误**

| 现象 | 处理 |
|---|---|
| `config/kylin.confirmed.env 中 KYLIN_GLIBC 尚未确认` | 未跑 probe 或探测失败；见阶段 -1 |
| `QGIS tag 解析结果 xxx 与锁定的 commit 不一致` | 有人改了 `config/build.env`。**不要改 commit 去迁就**，应调查上游 tag 是否被移动 |
| `磁盘不足` | 执行 `bash scripts/ci-free-space.sh`；仍不足则换 larger/自托管 runner。不要设 `ALLOW_LOW_DISK=1` 硬撑 |
| `依赖映射中出现 Debian/Ubuntu 体系内容` | `deps.confirmed.env` 被手改污染，重新 probe |

---

## 阶段 1 · 拉取并锁定官方源码

**命令**

```bash
bash scripts/10-fetch-source.sh
cat work/source-manifest.json
```

**预期结果**

```
源码版本校验通过: 3.34.12 (set(RELEASE_NAME "Prizren"))
FETCH SOURCE PASS —— qgis-3.34.12.tar.bz2 sha256=<64 hex>
```

`work/rpmbuild/SOURCES/qgis-3.34.12.tar.bz2` 由
`git archive --prefix=qgis-3.34.12/ HEAD | bzip2` 生成，与 QGIS 官方
`rpm/buildrpms.sh` 完全一致；`reports/upstream/` 保存官方 spec 模板与 INSTALL.md 作为依据。

**常见错误**

| 现象 | 处理 |
|---|---|
| `git fetch` 超时 | runner 到 github.com 网络问题；配置镜像代理或重试，不要改用其它版本 tarball |
| `tag ... 与锁定 commit 不符` | 上游 tag 被移动；停止构建并人工核实，禁止"先跑起来再说" |
| `CMakeLists.txt 版本为 3.34.x` | SOURCE0 被替换；`rm -rf work/src && 重跑` |
| `bzip2: command not found` | 基础镜像缺 bzip2；`capabilities.tsv` 已把它列为必需构建依赖 |

---

## 阶段 2 · 渲染 SPEC

**命令**

```bash
bash scripts/20-render-spec.sh
head -n 30 packaging/qgis-kylin.spec
```

**预期结果**

```
[OK] 已渲染 packaging/qgis-kylin.spec (Version=3.34.12, Release=1.kylin10, ...)
rpm 宏: _libdir=/usr/lib64  python3_sitearch=/usr/lib64/python3.X/site-packages
无任何 @TOKEN@ 残留
```

**常见错误**

| 现象 | 处理 |
|---|---|
| `SPEC 中仍有未替换占位符` | `render-spec.py` 的值表缺项；检查 `kylin.confirmed.env` 对应字段 |
| `无法生成 BuildRequires：依赖映射为空` | `deps.confirmed.env` 未生成；回到阶段 -1 |
| `rpmbuild: command not found` | 基础镜像未装 `rpm-build`；它由 `install-builddeps.sh` 按已确认包名安装 |
| `%files -f ... file not found` | `%install` 的 Python 文件清单生成失败；看 `rpmbuild.log` 中 `filelist:` 行 |

---

## 阶段 3 · 全量编译 + RPM 打包（耗时最长）

**命令**

```bash
bash scripts/30-rpmbuild.sh
# 实时观察
tail -f reports/logs/rpmbuild.log
```

**预期结果**

```
QGIS_STAGE_A_SOURCE_BUILD_OK
QGIS_STAGE_B_INSTALL_OK
RPMBUILD PASS —— STAGE_A(源码编译) + STAGE_B(RPM 打包) 均已通过
out/rpms/qgis-3.34.12-1.kylin10.x86_64.rpm
out/rpms/python3-qgis-3.34.12-1.kylin10.x86_64.rpm
out/rpms/qgis-devel-3.34.12-1.kylin10.x86_64.rpm
```

`reports/CMakeCache.txt` 中必须能看到 `WITH_3D:BOOL=TRUE`、
`WITH_BINDINGS:BOOL=TRUE`、`WITH_DESKTOP:BOOL=TRUE`、`BUILD_WITH_QT6:BOOL=FALSE`。

**常见错误（按出现频率）**

| 现象 | 原因 / 处理 |
|---|---|
| `Could NOT find Qt5WebKit` | 麒麟没有 QtWebKit。SPEC 已设 `WITH_QTWEBKIT=FALSE`；若仍报错，说明改了 SPEC，改回来 |
| `Could NOT find PDAL / Draco / GRASS` | 这些默认 `TRUE` 且 `find_package REQUIRED`。SPEC 已全部关掉；不要删这些开关 |
| `Could NOT find QCA / QtKeychain / Qsci / SIP / PyQt5` | 对应 `-devel` 包名不对或没装；用 `repoquery --whatprovides` 查真名，更新 `capabilities.tsv` |
| `error: 'optional' / C++17 编译错误` | GCC 过旧或 `CMAKE_CXX_STANDARD` 未生效；SPEC 已显式 `-D CMAKE_CXX_STANDARD=17`，需确认麒麟 GCC 支持 C++17 |
| `collect2: ld terminated with signal 9` / OOM | 并行度过高。`QGIS_BUILD_JOBS=2` 重跑；QGIS 单个 TU 峰值可达 1~2GB |
| `No space left on device` | 见阶段 0；清 `/opt/qgis-build/work` 后重跑，或换更大 runner |
| `Installed (but unpackaged) file(s) found` | `%install` 生成的动态文件清单漏项；把路径规则补进 SPEC 的 `classify()`，不要靠 `%exclude` 硬糊 |
| `libqgis_3d.so.* 缺失` | Qt5 3D 开发包缺失导致 3D 被静默关闭；`cmake` 日志搜 `3D`，补齐 `pkgconfig(Qt53DCore)` |
| `PyQGIS 未找到` | `BINDINGS_GLOBAL_INSTALL` 未生效或 SIP/PyQt5 版本不匹配；检查 `reports/CMakeCache.txt` |
| `rpmbuild 超过 360 分钟` | 用更大 runner / 提高 `QGIS_BUILD_JOBS` / 启用 ccache 卷，或拆分 job（不建议为绕限制而降低功能） |
| 日志停在 `FindPyQt5.cmake 补丁已存在` 之后**直接 exit 1、没有任何错误行** | `30-build-qgis.sh` 补 `libXXX.so` 链接名的循环以 `[[ -n "$_ver" ]] && ln -sf ...` 结尾，sysroot 里没有该库时返回 1，被 `set -e` 静默带走。已改为 `if/else` + 告警；现在所有脚本都有 ERR trap，会打印 `ERR: rc=… @ 文件:行号`。若仍告警“sysroot 缺 libXXX.so”，说明 `reports/logs/dep-sysroot.log` 里对应 RPM（protobuf / protobuf-lite / protoc / expat）没下载解压成功 |

---

## 阶段 4 · RPM 静态校验

**命令**

```bash
bash scripts/40-verify-rpm.sh
cat reports/rpm-verification.json
cat reports/isa-report.json
```

**预期结果**

```
VERIFY RPM PASS
"isa_glibc": "PASS"
avx512_files: []
rpath_leaks: []
glibc_too_new: []
max_glibc_symbol <= KYLIN_GLIBC
```

**常见错误**

| 现象 | 处理 |
|---|---|
| `检出 AVX-512/EVEX 指令` | 有人加了 `-march=native` 或 `-mavx512*`。恢复 `config/build.env` 的 `-march=x86-64 -mtune=generic` |
| `依赖的 GLIBC 符号版本高于目标系统` | 构建镜像 glibc 比目标机新，**这是致命的 ABI 不兼容**。必须换与目标机同版本的基础镜像，不能靠改判定阈值放行 |
| `ldd 有未解析库` | 缺运行期 RPM；用 `dnf repoquery --whatprovides <soname>` 找包名并加入 `QGIS_RUNTIME_REQUIRES` |
| `检测到 Debian/Ubuntu 体系文件` | 混入了 alien/fpm 产物；彻底重建镜像 |

---

## 阶段 5 · 全新麒麟容器安装与运行（STAGE_B2）

**命令**

```bash
docker pull "$KYLIN_TEST_IMAGE"
docker run --rm -v "$PWD:/work" -w /work -e REPO_ROOT=/work "$KYLIN_TEST_IMAGE" \
  bash -lc 'bash /work/scripts/50-test-install.sh'
```

**预期结果**

```
FRESH CONTAINER RUNTIME PASS (STAGE_B2)
out/evidence/render.png  (800x600, 非空白)
out/evidence/pyqgis-smoke.json  {"status":"PASS"}
reports/container-runtime.json  {"verdict":"PASS"}
```

**常见错误**

| 现象 | 处理 |
|---|---|
| `Error: Problem: conflicting requests / nothing provides ...` | 目标容器源里缺运行期依赖。这正是本阶段的价值：补齐 `QGIS_RUNTIME_REQUIRES` 或叠加源 |
| `qt.qpa.plugin: Could not load the Qt platform plugin "xcb"` | 未设 `QT_QPA_PLATFORM=offscreen`；脚本已设置，若手工运行请自行 export |
| `ModuleNotFoundError: No module named 'qgis'` | `PYTHONPATH` 未指向 `KYLIN_PYTHON3_SITEARCH`；检查该值与实际安装目录 |
| `renderedImage() 为空 / 全白` | 图层 CRS/范围或渲染器问题；先看 `pyqgis-smoke.json` 的 `render` 字段 |
| `qgis --version` 卡住 | GUI 探测需要显示；脚本用 `timeout 90` + offscreen，若仍卡住检查 UKUI/Qt 插件 |

> 提醒：容器与构建镜像共享同一套已安装依赖，**不足以证明 RPM 在干净目标机上可解析依赖**，
> 所以 `test-install` 使用 `KYLIN_TEST_IMAGE`（默认等于基础镜像，不是 builder 镜像）。

---

## 阶段 6 · QEMU/KVM 真实麒麟 VM（STAGE_C）

**命令**

```bash
sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils genisoimage sshpass
export KYLIN_QCOW2_URL='...'        # 建议放 GitHub Secrets
export KYLIN_QCOW2_SHA256='...'
export KYLIN_VM_SSH_PASSWORD='...'
bash scripts/60-test-qemu-vm.sh            # 缺镜像时标记 UNVERIFIED 并退出 0
bash scripts/60-test-qemu-vm.sh --require  # 要求必须有结论，否则失败
```

**预期结果（配置了 qcow2 时）**

```
STAGE_C PASS —— 真实麒麟 V10 虚拟机中 RPM 安装 / QGIS 启动 / 地图渲染均通过
out/evidence/vm/verdict.json  {"verdict":"PASS"}
out/evidence/vm/render.png、os-release.txt、lscpu.txt、rpm-qa.txt、serial.log
reports/stages/stage-c.json  {"status":"PASS"}
```

**预期结果（未配置 qcow2 时）**

```
WARN KYLIN_QCOW2_URL 未配置 —— STAGE_C = UNVERIFIED
reports/target-vm-runtime.json  {"status":"UNVERIFIED", ...}
```

**常见错误**

| 现象 | 处理 |
|---|---|
| `/dev/kvm 不存在` | 正常。脚本自动降级 TCG，速度慢但可跑；`-cpu qemu64` 反而能验证 ISA 基线。要 KVM 用自托管 runner |
| VM 超时无 sshd | qcow2 未装 cloud-init / 镜像不是 NoCloud 数据源 / 串口被重定向。看 `work/vm/serial.log` |
| `cloud-localds: command not found` | `apt install cloud-image-utils genisoimage` |
| `sshpass: command not found` | `apt install sshpass`；或改 cloud-init 注入 SSH 公钥 |
| `VM 内 dnf install 失败` | 真实验证出依赖在目标机上不可解；修依赖仓库，不要改成 `--nodeps` |
| `Xvfb 未安装 / UKUI 会话未验证` | 记录为 `UNVERIFIED`，属可接受的云端限制；真机人工验收 |
| TCG 下 `qgis --version` 极慢 | 调大 `VM_RAM_MB`、`VM_BOOT_TIMEOUT_SEC`，或减少 VM_CPUS（TCG 多核反而更慢） |

---

## 阶段 7 · 汇总证据

**命令**

```bash
bash scripts/70-collect-evidence.sh
cat out/verification-status.json
cat out/BUILD_REPORT.md
```

**预期结果**：五个阶段状态表清晰、`STAGE_D_C86_HARDWARE_RUNTIME = UNVERIFIED` 且列出原因与真机人工验收命令。

---

## 阶段 8 · 产物与发布

```bash
# Artifacts: qgis-3.34.12-rpms / -srpms / -final-bundle / -reports
# Release: push tag v* 或手动勾选 publish_release
git tag v3.34.12-kylin10 && git push origin v3.34.12-kylin10
```

**预期结果**：Release 附带二进制 RPM + `verification-status.json`，正文为 `BUILD_REPORT.md`。

---

## 阶段 D · 真机人工验收（云端无法替代）

在**海光 Hygon C86-3G + 银河麒麟 V10 (Halberd) + UKUI** 上执行：

```bash
sudo dnf install -y ./qgis-3.34.12-*.rpm ./python3-qgis-3.34.12-*.rpm
rpm -q qgis python3-qgis qgis-devel
qgis --version
qgis_process --version
python3 -c 'from qgis.core import Qgis; print(Qgis.QGIS_VERSION)'
lscpu | grep -E 'Model name|Flags'
ldd --version | head -n1
# 启动 UKUI 会话：打开 QGIS Desktop → 加载矢量/栅格图层 → 新建 3D Map View
```

**预期结果**：版本输出 `3.34.12`，Desktop 正常显示，2D 与 3D 视图均可渲染，
且无 `Illegal instruction` / `GLIBC_2.xx not found` / Qt 插件错误。
