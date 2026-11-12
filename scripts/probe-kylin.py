#!/usr/bin/env python3
"""在真实银河麒麟 V10 (Halberd) x86_64 容器内探测 QGIS 3.34.12 的原生 RPM 依赖。

本脚本不猜测任何包名/版本：所有结果来自目标系统的 rpm / dnf / yum 数据库、
pkg-config、已安装命令和 Python 解释器。

输出：
  reports/dependency-matrix.json          完整探测证据
  config/kylin.confirmed.env              系统事实（供 preflight / render-spec 用）
  config/deps.confirmed.env               能力 -> 真实 RPM 包名映射
  packaging/generated/buildrequires.inc   rpmbuild 的 BuildRequires 行
  packaging/generated/runtime-requires.inc

用法：
  python3 scripts/probe-kylin.py --write
  python3 scripts/probe-kylin.py --write --allow-unverified
  python3 scripts/probe-kylin.py --no-repoquery --write
"""
from __future__ import annotations

import argparse
import datetime
import glob
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TSV = ROOT / "config" / "capabilities.tsv"
UNCONFIRMED = "__UNCONFIRMED__"

RUNTIME_KEYS = [
    "gdal", "geos", "proj", "qt5core", "qt5_3d", "qca", "qca_ossl",
    "pyqt5", "gdal_python", "qt5_sql_sqlite", "python3", "sqlite3",
    "spatialite", "spatialindex", "libzip", "exiv2", "protobuf",
]

VER_RE = re.compile(r"(\d+\.\d+(?:\.\d+)?)")


def run(argv, timeout=180):
    """Run a command without a shell. Return (rc, stdout+stderr)."""
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout, text=True, errors="replace")
        return p.returncode, (p.stdout or "").strip()
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, str(exc)


def first_version(text):
    m = VER_RE.search(text or "")
    return m.group(1) if m else ""


def vkey(s):
    parts = (re.findall(r"\d+", s or "0") + ["0", "0", "0"])[:3]
    return tuple(int(x) for x in parts)


def version_at_least(found, minimum):
    if not found:
        return False
    return vkey(found) >= vkey(minimum)


# --------------------------------------------------------------------------
# 系统事实
# --------------------------------------------------------------------------
def detect_pm():
    for pm in ("dnf", "yum", "microdnf"):
        if shutil.which(pm):
            return pm
    return ""


def rpm_eval(expr):
    rc, out = run(["rpm", "--eval", expr])
    if rc != 0 or not out or out == expr or "not found" in out.lower():
        return ""
    return out.splitlines()[0].strip()


def os_facts():
    osrel = {}
    p = Path("/etc/os-release")
    if p.exists():
        for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                osrel[k.strip()] = v.strip().strip('"')
    kernel_rc, kernel = run(["uname", "-r"])
    rc, ldd = run(["ldd", "--version"])
    glibc = first_version(ldd)
    rc, gcc = run(["gcc", "-dumpfullversion", "-dumpversion"])
    if rc != 0:
        _, gcc = run(["gcc", "--version"])
        gcc = first_version(gcc)
    rc, rpmver = run(["rpm", "--version"])
    rpm_version = first_version(rpmver)

    pybin = shutil.which("python3") or sys.executable
    rc, pyver = run([pybin, "--version"])
    pyver = first_version(pyver) or platform.python_version()

    sitearch_macro = rpm_eval("%{python3_sitearch}")
    if not sitearch_macro or "{" in sitearch_macro:
        sitearch_macro = rpm_eval("%{python3_sitelib}")
    if not sitearch_macro or "{" in sitearch_macro:
        sitearch_macro = sysconfig.get_path("platlib")
    sitearch_sysconfig = sysconfig.get_path("platlib")

    libdir_macro = rpm_eval("%{_lib}")
    if not libdir_macro or "{" in libdir_macro:
        libdir_macro = os.path.basename(sysconfig.get_config_var("LIBDIR") or "/usr/lib64")
    full_libdir = rpm_eval("%{_libdir}")

    dist_macro = rpm_eval("%{?dist}")
    dist_tag = dist_macro.lstrip(".") if dist_macro and "{" not in dist_macro else ""

    return {
        "KYLIN_OS_ID": osrel.get("ID", UNCONFIRMED),
        "KYLIN_OS_VERSION_ID": osrel.get("VERSION_ID", UNCONFIRMED),
        "KYLIN_OS_PRETTY_NAME": osrel.get("PRETTY_NAME", UNCONFIRMED),
        "KYLIN_KERNEL": kernel if kernel_rc == 0 else UNCONFIRMED,
        "KYLIN_GLIBC": glibc or UNCONFIRMED,
        "KYLIN_GCC": gcc or UNCONFIRMED,
        "KYLIN_RPM_VERSION": rpm_version or UNCONFIRMED,
        "KYLIN_PACKAGE_MANAGER": detect_pm() or UNCONFIRMED,
        "KYLIN_LIBDIR": libdir_macro or UNCONFIRMED,
        "KYLIN_MACRO_LIBDIR": full_libdir or UNCONFIRMED,
        "KYLIN_MACRO_SMP_MFLAGS": rpm_eval("%{_smp_mflags}") or UNCONFIRMED,
        "KYLIN_MACRO_PYTHON3_SITEARCH": sitearch_macro or UNCONFIRMED,
        "KYLIN_PYTHON3_BIN": pybin or UNCONFIRMED,
        "KYLIN_PYTHON3_VERSION": pyver or UNCONFIRMED,
        # 纯 python sysconfig 与 rpm 宏可能不同，SPEC 用 rpm 宏口径
        "KYLIN_PYTHON3_SITEARCH": sitearch_macro or UNCONFIRMED,
        "KYLIN_PYTHON3_SITEARCH_SYSCONFIG": sitearch_sysconfig,
        "KYLIN_RPM_DIST_MACRO": dist_macro or "(empty)",
        # 工程自定义打包 tag，不代表 OS 事实，避免依赖 %{?dist} 是否存在
        "KYLIN_DIST_TAG": dist_tag or "kylin10",
        "KYLIN_ARCH": platform.machine(),
        "KYLIN_HOST_OS_RELEASE": str(Path("/etc/kylin-release")) if Path("/etc/kylin-release").exists() else "",
    }


# --------------------------------------------------------------------------
# 能力探测
# --------------------------------------------------------------------------
def read_capabilities():
    rows = []
    for raw in TSV.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        cols = raw.split("\t")
        if len(cols) != 8:
            raise SystemExit(f"capabilities.tsv 列数错误(应为 8，实际 {len(cols)}): {raw!r}")
        rows.append(dict(zip(
            ["key", "min_version", "probe", "probe_arg", "provides",
             "candidates", "required", "note"], [c.strip() for c in cols])))
    return rows


def detect_version(row):
    typ, arg = row["probe"], row["probe_arg"]
    if typ == "cmd":
        exe = shutil.which(arg)
        if not exe:
            return "", "missing-command"
        rc, out = run([exe, "--version"])
        if rc != 0 and arg == "python3":
            rc, out = run([exe, "-V"])
        v = first_version(out)
        return (v, "ok") if v else ("present", "unknown-version")
    if typ == "pkgconfig":
        if not shutil.which("pkg-config"):
            return "", "missing-pkg-config"
        rc, out = run(["pkg-config", "--modversion", arg])
        return (first_version(out), "ok") if rc == 0 else ("", "pkgconfig-not-found")
    if typ == "rpm":
        rc, out = run(["rpm", "-q", "--qf", "%{VERSION}", arg])
        return (first_version(out), "ok") if rc == 0 else ("", "not-installed")
    if typ == "python_module":
        code = ("import importlib,sys\n"
                "m=importlib.import_module(%r)\n"
                "print(getattr(m,'__version__', getattr(m,'VERSION','present')))\n" % arg)
        rc, out = run([shutil.which("python3") or sys.executable, "-c", code])
        if rc != 0:
            return "", "python-module-missing"
        return (first_version(out) or "present", "ok")
    if typ == "header":
        base = os.path.basename(arg)
        # 只扫描 /usr/include（Qt private headers 位于 /usr/include/qt5/...），
        # 避免对整个 /usr 做递归 glob 导致探测阶段耗时不可控
        patterns = [
            "/usr/include/" + arg,
            "/usr/include/*/" + arg,
            "/usr/include/**/" + base,
        ]
        for pat in patterns:
            if glob.glob(pat, recursive=True):
                return "present", "ok"
        return "", "header-not-found"
    if typ == "qmake":
        for exe in ("qmake-qt5", "qmake"):
            if shutil.which(exe):
                rc, out = run([exe, "-query", "QT_VERSION"])
                if rc == 0:
                    return first_version(out), "ok"
        return "", "qmake-not-found"
    return "", "unknown-probe-type"


def resolve_package(row, pm, allow_repoquery):
    """返回 (包名, 证据)。只接受目标系统 rpm/dnf 数据库给出的真实名字。"""
    # 1) 已安装：rpm --whatprovides
    for prov in [p.strip() for p in row["provides"].split(";") if p.strip()]:
        rc, out = run(["rpm", "-q", "--whatprovides", "--qf", "%{NAME}", prov])
        if rc == 0 and out and "no package provides" not in out.lower():
            return out.splitlines()[0].strip(), f"rpm --whatprovides {prov} (installed)"

    # 2) 仓库：repoquery --whatprovides
    if allow_repoquery and pm:
        for prov in [p.strip() for p in row["provides"].split(";") if p.strip()]:
            name = repoquery_whatprovides(pm, prov)
            if name:
                return name, f"{pm} repoquery --whatprovides {prov}"

    # 3) 候选包名精确查询
    for cand in [c.strip() for c in row["candidates"].split(",") if c.strip()]:
        rc, out = run(["rpm", "-q", "--qf", "%{NAME}", cand])
        if rc == 0 and out:
            return out.splitlines()[0].strip(), f"rpm -q {cand} (installed)"
        if allow_repoquery and pm:
            name = repoquery_name(pm, cand)
            if name:
                return name, f"{pm} repoquery {cand}"
    return "", "unresolved"


def repoquery_whatprovides(pm, what):
    if pm in ("dnf", "microdnf"):
        rc, out = run([pm, "-q", "repoquery", "--whatprovides", what,
                       "--queryformat", "%{name}", "--latest-limit", "1"])
    else:
        rc, out = run(["repoquery", "--whatprovides", what, "--qf", "%{name}"])
        if rc != 0:
            rc, out = run(["yum", "-q", "whatprovides", what])
    if rc != 0 or not out:
        return ""
    for line in out.splitlines():
        line = line.strip()
        if not line or ":" in line and line.startswith(("Last metadata", "更新", "Loaded")):
            continue
        if re.fullmatch(r"[A-Za-z0-9_.+\-]+", line):
            return line
    return ""


def repoquery_name(pm, name):
    if pm in ("dnf", "microdnf"):
        rc, out = run([pm, "-q", "repoquery", "--queryformat", "%{name}", name])
    else:
        rc, out = run(["repoquery", "--qf", "%{name}", name])
    if rc != 0 or not out:
        return ""
    for line in out.splitlines():
        if line.strip() == name:
            return name
    return ""


def chunked_requires(keyword, names, per_line=6):
    names = [n for n in dict.fromkeys(names) if n]
    if not names:
        return f"# WARNING: no {keyword} resolved; see reports/dependency-matrix.json\n"
    return "".join(
        f"{keyword}:  " + "  ".join(names[i:i + per_line]) + "\n"
        for i in range(0, len(names), per_line)
    )


def shell_value(v):
    if v is None:
        return UNCONFIRMED
    v = str(v).replace("\n", " ").replace("\r", " ")
    return v if v else UNCONFIRMED


def write_env(path: Path, values: dict, header: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [header, ""]
    for k, v in values.items():
        # OS PRETTY_NAME 等值可能含空格与括号，必须可安全被 `source`
        lines.append(f"{k}={shlex.quote(shell_value(v))}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="写出 confirmed.env 与 .inc 文件")
    ap.add_argument("--allow-unverified", action="store_true",
                    help="即使存在未解析/不达标项也返回 0（仅供人工审阅，CI 禁止）")
    ap.add_argument("--no-repoquery", action="store_true", help="离线模式，只查已安装包")
    args = ap.parse_args()

    if platform.machine() != "x86_64":
        print(f"[WARN] 当前架构 {platform.machine()}，目标为 x86_64；探测结果仅作参考",
              file=sys.stderr)

    facts = os_facts()
    pm = facts["KYLIN_PACKAGE_MANAGER"]
    if pm == UNCONFIRMED:
        pm = ""
    rows = read_capabilities()

    results = []
    unresolved, version_failures = [], []
    for row in rows:
        found, detect_note = detect_version(row)
        name, resolve_note = resolve_package(row, pm, not args.no_repoquery)
        minv = row["min_version"]
        version_ok = True
        if minv != "0.0.0":
            version_ok = version_at_least(found, minv)
        required = row["required"].lower() == "yes"
        if not name:
            status = "UNRESOLVED" if required else "OPTIONAL-UNRESOLVED"
            if required:
                unresolved.append(row["key"])
        elif not version_ok:
            status = "VERSION-TOO-OLD"
            version_failures.append(row["key"])
        elif detect_note in ("missing-command", "pkgconfig-not-found", "header-not-found",
                            "python-module-missing", "not-installed"):
            # 包能在仓库里解析出来即可（构建镜像稍后会安装它）
            status = "RESOLVABLE-NOT-YET-INSTALLED"
        else:
            status = "OK"
        results.append({
            "key": row["key"], "min_version": minv, "required": required,
            "probe": row["probe"], "probe_arg": row["probe_arg"],
            "detected_version": found or "", "detect_note": detect_note,
            "rpm_package": name or "", "resolve_evidence": resolve_note,
            "status": status, "note": row["note"],
        })

    by_key = {r["key"]: r for r in results}
    build_names = [r["rpm_package"] for r in results if r["rpm_package"]]
    runtime_names = [by_key[k]["rpm_package"] for k in RUNTIME_KEYS
                     if k in by_key and by_key[k]["rpm_package"]]

    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    matrix = {
        "generated_at": now,
        "generator": "scripts/probe-kylin.py",
        "qgis_version": "3.34.12",
        "system": facts,
        "capabilities": results,
        "qgis_buildrequires": sorted(set(build_names)),
        "qgis_runtime_requires": sorted(set(runtime_names)),
        "unresolved_required": unresolved,
        "version_failures": version_failures,
        "verdict": "PASS" if not unresolved and not version_failures else "FAIL",
    }

    reports = ROOT / "reports"
    reports.mkdir(parents=True, exist_ok=True)
    (reports / "dependency-matrix.json").write_text(
        json.dumps(matrix, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print("=" * 100)
    print(f"Kylin 探测: {facts['KYLIN_OS_PRETTY_NAME']} / kernel {facts['KYLIN_KERNEL']} "
          f"/ glibc {facts['KYLIN_GLIBC']} / gcc {facts['KYLIN_GCC']} / PM={pm or 'NONE'}")
    print(f"rpm 宏: _libdir={facts['KYLIN_MACRO_LIBDIR']}  "
          f"python3_sitearch={facts['KYLIN_PYTHON3_SITEARCH']}  dist={facts['KYLIN_RPM_DIST_MACRO']}")
    print("-" * 100)
    print(f"{'KEY':<22}{'MIN':<10}{'FOUND':<12}{'RPM PACKAGE':<34}STATUS")
    for r in results:
        print(f"{r['key']:<22}{r['min_version']:<10}{(r['detected_version'] or '-'):<12}"
              f"{(r['rpm_package'] or '-'):<34}{r['status']}")
    print("-" * 100)
    print(f"verdict={matrix['verdict']}  unresolved={unresolved}  version_failures={version_failures}")
    print("=" * 100)

    if args.write:
        write_env(ROOT / "config" / "kylin.confirmed.env", facts,
                  "# 由 scripts/probe-kylin.py 在真实麒麟 V10 容器中生成，勿手工伪造")
        dep_env = {
            "DEPS_PROBED_AT": now,
            "DEPS_PROBE_OS": facts["KYLIN_OS_PRETTY_NAME"],
            "DEPS_PROBE_PM": pm or UNCONFIRMED,
        }
        for r in results:
            dep_env["DEP_" + r["key"].upper()] = r["rpm_package"] or UNCONFIRMED
        dep_env["QGIS_BUILDREQUIRES"] = " ".join(sorted(set(build_names))) or UNCONFIRMED
        dep_env["QGIS_RUNTIME_REQUIRES"] = " ".join(sorted(set(runtime_names))) or UNCONFIRMED
        dep_env["UNRESOLVED_DEPS"] = ",".join(unresolved) or "none"
        dep_env["DEPS_VERSION_FAILURES"] = ",".join(version_failures) or "none"
        write_env(ROOT / "config" / "deps.confirmed.env", dep_env,
                  "# 由 scripts/probe-kylin.py 依据目标系统 rpm/dnf 数据库生成")

        gen = ROOT / "packaging" / "generated"
        gen.mkdir(parents=True, exist_ok=True)
        (gen / "buildrequires.inc").write_text(
            chunked_requires("BuildRequires", sorted(set(build_names))), encoding="utf-8")
        (gen / "runtime-requires.inc").write_text(
            chunked_requires("Requires", sorted(set(runtime_names))), encoding="utf-8")
        print(f"[OK] 已写出 config/*.confirmed.env、packaging/generated/*.inc、"
              f"reports/dependency-matrix.json")

    if (unresolved or version_failures) and not args.allow_unverified:
        print("[FAIL] 存在未解析或版本不达标的必需依赖。", file=sys.stderr)
        print("       请核对 docs/CONFIRM.md 第 4/5 节；若麒麟源确实缺少 Qt>=5.14 / "
              "PROJ>=7.2 / GEOS>=3.9 / GDAL>=3.2，必须自建「依赖叠加 RPM 仓库」"
              "并通过 KYLIN_EXTRA_REPO_URLS 注入，不得改用 Ubuntu 产物。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
