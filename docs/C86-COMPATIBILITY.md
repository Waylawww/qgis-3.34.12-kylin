# 海光 Hygon C86-3G 兼容性与云端不可验证项

## 1. 本工程采取的 CPU 策略

`config/build.env` 固定：

```
ISA_CFLAGS   = -march=x86-64 -mtune=generic -O2 -pipe
ISA_CXXFLAGS = -march=x86-64 -mtune=generic -O2 -pipe
ALLOW_AVX512 = false
```

SPEC 把它们传入 `CMAKE_C_FLAGS` / `CMAKE_CXX_FLAGS`，并显式设置
`BUILD_WITH_QT6=OFF`、`USE_OPENCL=OFF`（不引入 GPU/异构计算依赖）。

- **不使用** `-march=native`、`-march=znver*`、`-mavx*`、`-mavx512*`；
- `scripts/check-isa.sh` 反汇编解包后的 `libqgis*`、`qgis`、`qgis_process`，
  统计 `%ymm`（AVX/AVX2）与 `%zmm/%k`（AVX-512/EVEX）指令；
  出现 AVX-512 直接判 `FAIL`，出现 ymm 会告警；
- 同时校验 `readelf -h` 的 Machine 为 x86-64、RPATH 不含构建机路径、
  `objdump -T` 得到的最高 `GLIBC_x.y` 不高于目标系统 glibc。

QEMU 阶段统一使用 `-cpu qemu64`（x86-64 基线）。即使宿主 runner 有 AVX-512，
VM 也不会暴露这些指令；若二进制里混入了越界指令，会直接 `Illegal instruction`，
因此这一步是**额外的 ISA 基线实测**，而不只是形式检查。

## 2. 仍然无法在云端验证、必须标注的限制

| 项目 | 为什么云端验证不了 | 真机确认方式 |
|---|---|---|
| Hygon C86-3G 微架构特性 | GitHub runner 是 Azure 的 Intel/AMD VM；QEMU `-cpu qemu64` 只暴露基线 | `lscpu`、`cat /proc/cpuinfo` |
| C86 特有固件 / 内核补丁 | 目标内核 `4.19.90-89.11.v2401.ky10` 的驱动与加固模块无法在通用 runner 复现 | 真机 `uname -r`、`dmesg` |
| 麒麟官方 Qt/GDAL/PROJ RPM 的运行时 SIMD 分发 | 这些库不在本工程编译范围，可能按 CPUID 选择 AVX2 路径 | 真机运行 QGIS 并观察有无 `Illegal instruction` |
| glibc 与内核版本一致性 | 构建镜像 glibc 可能与目标机不同（脚本已做符号上限校验，但不能替代真机） | `ldd --version`、`rpm -q glibc` |
| UKUI 桌面会话 | 无真实 UKUI 会话、无显示服务器、无中文字体/主题完整环境 | UKUI 登录并启动 QGIS Desktop |
| 3D OpenGL 视图 | 云端 VM 通常只有 llvmpipe/无 GPU；本工程只验证 `libqgis_3d.so` 与 Python `qgis._3d` 存在 | 真机新建 3D Map View 并加载 DEM/3D Tiles |
| 硬件加速驱动（显卡、国产 GPU） | 驱动与固件闭源、需真机 | `glxinfo -B`、`rpm -qa \| grep -i driver` |
| 商业软件源授权与离线部署 | 需客户环境网络/授权 | 现场 `dnf install` 验证 |

因此 `out/verification-status.json` 里 `STAGE_D_C86_HARDWARE_RUNTIME` **恒为
`UNVERIFIED`**，并附真机人工验收命令。任何把"RPM 构建成功"表述成"可在海光 C86
麒麟上正常运行"的说法都是不成立的。

## 3. 已知的平台适配差异

- 3D 需要 Qt5 的 `3DCore/3DRender/3DInput/3DLogic/3DExtras`。若麒麟源的 Qt 版本被裁剪，
  `WITH_3D` 会静默失效；SPEC 在 `%install` 里对 `libqgis_3d.so.*` 做了硬检查。
- QGIS 3.34 默认 `WITH_QTWEBKIT=TRUE`，而多数国产 RPM 发行版不再提供 Qt5WebKit；
  本工程显式关闭，属于官方 INSTALL.md 允许的编译开关。
- `WITH_PDAL / WITH_DRACO / WITH_EPT / WITH_COPC / WITH_GRASS* / WITH_SERVER` 默认或官方
  spec 为开，但它们在麒麟上通常缺依赖且不是交付目标，本工程关闭；不影响
  Desktop / PyQGIS / 3D 三项核心要求。
- `%files` 由 `%install` 阶段按真实安装树动态生成，避免把 Fedora 的文件清单硬套到麒麟上。
