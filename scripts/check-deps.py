#!/usr/bin/env python3
"""构建镜像内安装完依赖后，复核 config/capabilities.tsv 的最低版本门槛。

复用 scripts/probe-kylin.py 的版本探测逻辑，但不写文件、不查仓库。
任何 required=yes 且 min_version>0.0.0 的能力不达标就直接失败。
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("probe_kylin", ROOT / "scripts" / "probe-kylin.py")
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

rows = mod.read_capabilities()
failures, warnings = [], []
print("=" * 92)
print(f"{'KEY':<22}{'REQUIRED':<12}{'FOUND':<14}STATUS")
print("-" * 92)
for row in rows:
    if row["min_version"] == "0.0.0":
        continue
    found, note = mod.detect_version(row)
    ok = mod.version_at_least(found, row["min_version"])
    status = "OK" if ok else "TOO-OLD/MISSING"
    print(f"{row['key']:<22}{row['min_version']:<12}{(found or '-'):<14}{status}  ({note})")
    if not ok:
        if row["required"].lower() == "yes":
            failures.append((row["key"], row["min_version"], found or "missing"))
        else:
            warnings.append(row["key"])
print("-" * 92)

if warnings:
    print("[WARN] 可选依赖版本不足: " + ", ".join(warnings))
if failures:
    print("[FAIL] 以下必需依赖不满足 QGIS 3.34.12 官方最低版本:", file=sys.stderr)
    for key, need, got in failures:
        print(f"       {key}: 需要 >= {need}, 实际 {got}", file=sys.stderr)
    print("       处理方式：在 KYLIN_EXTRA_REPO_URLS 中注入「依赖叠加 RPM 仓库」"
          "（用麒麟原生工具链把这些依赖打成 RPM），不得改用 Ubuntu 二进制。", file=sys.stderr)
    sys.exit(1)
print("[OK] 依赖版本门槛全部满足（依据 QGIS 官方 INSTALL.md / CMakeLists.txt）")
