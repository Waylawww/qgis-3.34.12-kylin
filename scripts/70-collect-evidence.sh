#!/usr/bin/env bash
# 阶段 7：汇总「三层验证」证据。严格区分：
#   STAGE_A   源码编译成功
#   STAGE_B   RPM 软件包构建 + 静态校验成功
#   STAGE_B2  全新容器内安装/启动/渲染成功（同一用户态，但不是 VM）
#   STAGE_C   真实麒麟 V10 虚拟机内运行成功
#   STAGE_D   海光 C86 物理机 / UKUI GPU / 3D OpenGL —— 云端无法验证，必须标注
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env

info "== 阶段 7 / COLLECT EVIDENCE =="
python3 - "${REPO_ROOT}" "${REPORT_DIR}" "${OUT_DIR}" <<'PY'
import datetime, hashlib, json, os, sys
from pathlib import Path
root, rep, out = map(Path, sys.argv[1:4])

def jload(p, default):
    try:
        return json.loads(Path(p).read_text(encoding="utf-8"))
    except Exception:
        return default

def stage(name, path):
    d = jload(rep / "stages" / path, {"status": "UNVERIFIED"})
    return {"status": d.get("status", "UNVERIFIED"), "evidence": str(rep / "stages" / path)}

stages = {
    "STAGE_A_SOURCE_BUILD":            stage("A", "stage-a.json"),
    "STAGE_B_RPM_BUILD":               stage("B", "stage-b.json"),
    "STAGE_B_STATIC_VERIFY":           stage("B-static", "stage-b-static.json"),
    "STAGE_B2_CONTAINER_RUNTIME":      stage("B2", "stage-b2.json"),
    "STAGE_C_TARGET_VM_RUNTIME":       stage("C", "stage-c.json"),
    # 云端永远无法验证真机特性，硬编码 UNVERIFIED 并给出原因
    "STAGE_D_C86_HARDWARE_RUNTIME": {
        "status": "UNVERIFIED",
        "reasons": [
            "GitHub Actions/Codespaces 不提供海光 Hygon C86-3G 物理 CPU",
            "QEMU 虚拟 CPU 无法复现 C86 的微架构特性、固件与内核补丁差异",
            "UKUI 图形会话与 3D OpenGL 视图需要真机 GPU 驱动，云端 VM 一般不具备",
            "麒麟 V10 内核 4.19.90-89.11.v2401.ky10 的特定驱动/加固模块无法在通用 runner 中复现",
        ],
        "required_manual_check": [
            "rpm -q qgis python3-qgis qgis-devel",
            "qgis --version && qgis_process --version",
            "python3 -c 'from qgis.core import Qgis; print(Qgis.QGIS_VERSION)'",
            "启动 UKUI 会话，打开 QGIS Desktop，加载矢量/栅格图层并新建 3D Map View",
            "lscpu / cat /proc/cpuinfo 确认 CPU flags 与 -march=x86-64 基线一致",
        ],
    },
}

rpms = []
for p in sorted((out / "rpms").glob("*.rpm")) if (out / "rpms").exists() else []:
    rpms.append({"file": p.name, "bytes": p.stat().st_size,
                 "sha256": hashlib.sha256(p.read_bytes()).hexdigest()})

status = {
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "qgis_version": "3.34.12",
    "qgis_tag": "final-3_34_12",
    "qgis_commit": "eeb6af363865e463b8f058b7d79fd5378c4bf065",
    "target": "Kylin Server V10 (Halberd) / x86_64 / Hygon C86-3G / UKUI",
    "isa_policy": "x86-64 baseline (-march=x86-64 -mtune=generic)",
    "stages": stages,
    "rpms": rpms,
    "isa_report": jload(rep / "isa-report.json", {}),
    "rpm_verification": jload(rep / "rpm-verification.json", {}),
    "container_runtime": jload(rep / "container-runtime.json", {}),
    "target_vm_runtime": jload(rep / "target-vm-runtime.json", {}),
    "honesty_note": "STAGE_A/B/B2/C 互不冒充；C 未跑时不得宣称目标系统运行成功；D 云端不可验证。",
}
(out / "verification-status.json").write_text(
    json.dumps(status, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

order = ["STAGE_A_SOURCE_BUILD", "STAGE_B_RPM_BUILD", "STAGE_B_STATIC_VERIFY",
         "STAGE_B2_CONTAINER_RUNTIME", "STAGE_C_TARGET_VM_RUNTIME",
         "STAGE_D_C86_HARDWARE_RUNTIME"]
lines = [
    "# QGIS 3.34.12 / 银河麒麟 V10 / 海光 C86 构建验证报告", "",
    f"- 生成时间：{status['generated_at']}",
    f"- 源码：QGIS tag `{status['qgis_tag']}` @ `{status['qgis_commit']}`（严格锁定 3.34.12）",
    f"- 目标：{status['target']}",
    f"- 指令集：{status['isa_policy']}", "",
    "## 分层验证状态", "",
    "| 阶段 | 含义 | 状态 |", "|---|---|---|",
]
meaning = {
    "STAGE_A_SOURCE_BUILD": "源码在麒麟原生工具链上完整编译",
    "STAGE_B_RPM_BUILD": "原生 rpmbuild 产出 RPM 分包",
    "STAGE_B_STATIC_VERIFY": "RPM 元数据/3D/PyQGIS/ldd/ISA/GLIBC 静态校验",
    "STAGE_B2_CONTAINER_RUNTIME": "全新麒麟容器中安装、启动、离屏渲染",
    "STAGE_C_TARGET_VM_RUNTIME": "QEMU/KVM 真实麒麟 V10 虚拟机中安装、启动、渲染",
    "STAGE_D_C86_HARDWARE_RUNTIME": "海光 C86 物理机 / UKUI GPU / 3D 视图",
}
for k in order:
    lines.append(f"| `{k}` | {meaning[k]} | **{stages[k]['status']}** |")
lines += ["", "## 产物", ""]
for r in rpms:
    lines.append(f"- `{r['file']}` — {r['bytes']} bytes — sha256 `{r['sha256']}`")
lines += ["", "## 云端不可验证项（必须人工在真机确认）", ""]
for r in stages["STAGE_D_C86_HARDWARE_RUNTIME"]["reasons"]:
    lines.append(f"- {r}")
lines += ["", "## 真机人工验收命令", "", "```bash"]
for c in stages["STAGE_D_C86_HARDWARE_RUNTIME"]["required_manual_check"]:
    lines.append(c)
lines += ["```", "", "> 未跑 STAGE_C 时，只允许说「RPM 构建成功」，不允许说「可在麒麟上运行」。", ""]
(out / "BUILD_REPORT.md").write_text("\n".join(lines), encoding="utf-8")

summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a", encoding="utf-8") as f:
        f.write("\n## QGIS 3.34.12 分层验证\n\n")
        f.write("| 阶段 | 状态 |\n|---|---|\n")
        for k in order:
            f.write(f"| {k} | {stages[k]['status']} |\n")
        f.write("\n" + status["honesty_note"] + "\n")

print(json.dumps({k: stages[k]["status"] for k in order}, ensure_ascii=False, indent=2))
PY

info "报告: ${OUT_DIR}/BUILD_REPORT.md"
info "状态: ${OUT_DIR}/verification-status.json"
