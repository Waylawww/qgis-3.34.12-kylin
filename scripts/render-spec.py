#!/usr/bin/env python3
"""把 packaging/qgis-kylin.spec.in 渲染成可直接 rpmbuild 的 SPEC。

所有值来自：
  config/build.env                （已核验的 QGIS 官方事实）
  config/kylin.confirmed.env      （麒麟 V10 实测系统事实）
  config/deps.confirmed.env       （麒麟 V10 实测 RPM 包名映射）
  packaging/generated/*.inc       （probe 生成的 BuildRequires / Requires 行）

任何未替换的 @TOKEN@ 都会导致失败——绝不把占位符带进 RPM。
"""
from __future__ import annotations

import datetime
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_env(path: Path) -> dict:
    out = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        out[k.strip()] = v
    return out


def chunked(keyword: str, blob: str, per_line: int = 6) -> str:
    names = list(dict.fromkeys(blob.split()))
    names = [n for n in names if n and "__UNCONFIRMED__" not in n]
    if not names:
        raise SystemExit(f"无法生成 {keyword}：依赖映射为空，请先运行 probe-kylin.py --write")
    return "".join(
        f"{keyword}:  " + "  ".join(names[i:i + per_line]) + "\n"
        for i in range(0, len(names), per_line)
    )


def main() -> int:
    build = read_env(ROOT / "config" / "build.env")
    kylin = read_env(ROOT / "config" / "kylin.confirmed.env")
    deps = read_env(ROOT / "config" / "deps.confirmed.env")

    gen = ROOT / "packaging" / "generated"
    br_file, rr_file = gen / "buildrequires.inc", gen / "runtime-requires.inc"
    buildrequires = br_file.read_text(encoding="utf-8") if br_file.exists() else \
        chunked("BuildRequires", deps.get("QGIS_BUILDREQUIRES", ""))
    runtimerequires = rr_file.read_text(encoding="utf-8") if rr_file.exists() else \
        chunked("Requires", deps.get("QGIS_RUNTIME_REQUIRES", ""))

    for label, text in (("BuildRequires", buildrequires), ("Requires", runtimerequires)):
        if "__UNCONFIRMED__" in text or not text.strip():
            raise SystemExit(f"{label} 含未确认参数，拒绝渲染 SPEC")

    dist_tag = kylin.get("KYLIN_DIST_TAG", "")
    if not dist_tag or "__UNCONFIRMED__" in dist_tag:
        raise SystemExit("KYLIN_DIST_TAG 未确认")

    values = {
        "QGIS_VERSION": build["QGIS_VERSION"],
        "QGIS_RELEASE": "1." + dist_tag,
        "QGIS_DIST_TAG": dist_tag,
        "QGIS_SOURCE_DIR_NAME": build["QGIS_SOURCE_DIR_NAME"],
        "QGIS_SOURCE_TARBALL": build["QGIS_SOURCE_TARBALL"],
        "BUILDREQUIRES_LINES": buildrequires.rstrip("\n"),
        "RUNTIME_REQUIRES_LINES": runtimerequires.rstrip("\n"),
        "ISA_CFLAGS": build["ISA_CFLAGS"],
        "ISA_CXXFLAGS": build["ISA_CXXFLAGS"],
        "BUILD_JOBS": os.environ.get("QGIS_BUILD_JOBS", build.get("QGIS_BUILD_JOBS", "4")),
        "QGIS_LIBDIR": kylin["KYLIN_LIBDIR"],
        "QGIS_MACRO_LIBDIR": kylin["KYLIN_MACRO_LIBDIR"],
        "QGIS_PYTHON3_SITEARCH": kylin["KYLIN_PYTHON3_SITEARCH"],
        "QGIS_PYTHON3_BIN": kylin["KYLIN_PYTHON3_BIN"],
        "KYLIN_GLIBC": kylin["KYLIN_GLIBC"],
        "KYLIN_PACKAGE_MANAGER": kylin["KYLIN_PACKAGE_MANAGER"],
        "KYLIN_OS": kylin["KYLIN_OS_PRETTY_NAME"],
        "GENERATED_AT": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    for k, v in values.items():
        if not v or "__UNCONFIRMED__" in str(v):
            raise SystemExit(f"SPEC 渲染参数 {k} 未确认: {v!r}")

    template = (ROOT / "packaging" / "qgis-kylin.spec.in").read_text(encoding="utf-8")
    spec = template
    for k, v in values.items():
        spec = spec.replace("@" + k + "@", str(v))

    leftover = sorted(set(re.findall(r"@[A-Z0-9_]+@", spec)))
    if leftover:
        raise SystemExit(f"SPEC 中仍有未替换占位符: {leftover}")

    out = ROOT / "packaging" / "qgis-kylin.spec"
    out.write_text(spec, encoding="utf-8")
    print(f"[OK] 已渲染 {out.relative_to(ROOT)}  "
          f"(Version={values['QGIS_VERSION']}, Release={values['QGIS_RELEASE']}, "
          f"libdir={values['QGIS_LIBDIR']}, sitearch={values['QGIS_PYTHON3_SITEARCH']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
