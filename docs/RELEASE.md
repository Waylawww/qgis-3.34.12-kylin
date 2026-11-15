# QGIS 3.34.12 自包含构建（银河麒麟 V10 / 海光 C86） — 安装与使用说明

本仓库产出的 RPM 将 QGIS 3.34.12 桌面版及其**全部**第三方依赖（Qt5、GDAL 3.5.3、PROJ、GEOS、Python 3.7 运行环境、桌面插件所需的 Python 包等）打包进单一前缀 `/opt/qgis-3.34.12`，**无需在目标机安装系统级 QGIS / Qt / GDAL**。

预编译 RPM 见 GitHub **Releases**（标签 `v3.34.12-kylin-1`）：
https://github.com/Waylawww/qgis-3.34.12-kylin/releases/tag/v3.34.12-kylin-1

## 适用平台
- 银河麒麟 V10（Halberd），x86_64，海光 C86（Hygon C86）等兼容机型。
- 安装需要 root 权限。

## 安装
推荐用 `dnf`（会自动处理极少数系统级依赖）；若提示 `/usr/bin` 等目录冲突，加 `--replacefiles`：

```bash
sudo dnf install -y ./qgis-3.34.12-1.ky10.x86_64.rpm
# 或直接 rpm：
sudo rpm -ivh --replacefiles ./qgis-3.34.12-1.ky10.x86_64.rpm
```

安装后通过桌面启动器或命令 `/usr/bin/qgis` 启动；本体位于 `/opt/qgis-3.34.12`。

## 新设备上的前置依赖
- **图形界面（GUI）**：需要桌面环境（X11 / Wayland）。若为最小化安装（无桌面），请先安装基础 X / GL 运行库，例如：
  ```bash
  sudo dnf install -y xorg-x11-server-Xorg libX11 libxcb fontconfig freetype mesa-libGL mesa-dri-drivers
  ```
  无头 / 服务器场景可用 `QT_QPA_PLATFORM=offscreen` 跑处理脚本，此时无需 X；GUI 渲染与截图需上述库。
- **Python 插件依赖已内置**：`osgeo`（GDAL 绑定）、`psycopg2`、`numpy`、`owslib`、`lxml`、`pygments`、`PyYAML`、`requests`、`jinja2` 等均已随包打包，**无需再 `pip install`**，也**无需装系统 `python3-gdal` / `python3-psycopg2`**。因此 `processing` / `grassprovider` / `MetaSearch` 等插件开箱即用。
- **不需要**单独安装 GDAL / PROJ / GEOS / Qt 等运行或开发包。

## 校验
- 打开 QGIS 后，`processing`、`grassprovider`、`MetaSearch` 三个插件应正常加载，不再报 `ModuleNotFoundError`。
- 本 RPM 由 CI（self-hosted runner，Kylin V10）产出，已通过安装自测（CLI / PyQGIS / 离屏渲染 / xcb GUI 全部 PASS）。

## RPM 指纹
- 文件名：`qgis-3.34.12-1.ky10.x86_64.rpm`
- sha256：`e6db698ff3b8693188e3ab53edb6d8d10ba35aac156c9efed7bd114958b2eeba`
- 构建运行（Actions）：`43682093482`
- 安装门禁：目标机安装由受限 sudo 完成，需在 root 维护的 allowlist（`/etc/qgis-ci/allowed-rpm.sha256`）中加入上述 sha256 后方可安装（仅放行白名单内的 RPM，防止 runner 借安装间接获取 root）。

## 从源码自建（可选）
CI 通过 `build.yml` 的 `workflow_dispatch` 驱动：
- `stage=all`：构建全部依赖 + QGIS 并产出 RPM（耗时最长）。
- `stage=deps` / `stage=qgis`：分别只重建依赖或只重打 QGIS。
- `stage=install`：在已注册的自托管 runner 上安装最新 RPM 并跑完整自测。
- `FORCE_REBUILD_DEPS=true`：忽略依赖缓存，强制重建（含 Qt 启用 xcb 桌面 GUI 插件）。
