#!/usr/bin/env bash
# 校验 QGIS 自身二进制的指令集与 GLIBC 符号版本是否落在目标机能力范围内。
# 只扫描本工程编译出来的文件，不扫描系统库（系统库由麒麟官方 RPM 提供）。
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_build_env

DIR="${1:-}"
[[ -n "${DIR}" && -d "${DIR}" ]] || die "用法: check-isa.sh <解包后的 RPM 根目录>"
need_cmd objdump "ISA 检查"
need_cmd readelf "ELF 检查"

KYLIN_GLIBC="$(grep -E '^KYLIN_GLIBC=' "${KYLIN_ENV}" | tail -n1 | cut -d= -f2- | tr -d "\"'" || true)"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

info "== ISA / ABI 校验 (目标 ${TARGET_CPU}, ${ISA_POLICY}) =="
: > "${TMP}/records.tsv"

while IFS= read -r -d '' f; do
  rel="${f#"${DIR}"}"
  machine="$(readelf -h "$f" 2>/dev/null | awk -F: '/Machine:/{gsub(/^ +/,"",$2);print $2}' || true)"
  [[ "${machine}" == *"X86-64"* || "${machine}" == *"x86-64"* || "${machine}" == *"AMD"* ]] || {
    warn "非 x86-64 ELF: ${rel} (${machine})"; continue; }
  objdump -d --no-show-raw-insn "$f" > "${TMP}/disasm" 2>/dev/null || continue
  zmm="$(grep -cE '%zmm[0-9]+|%k[0-7]\b' "${TMP}/disasm" || true)"
  ymm="$(grep -cE '%ymm[0-9]+' "${TMP}/disasm" || true)"
  glibc_max="$(objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' \
               | sort -Vu | tail -n1 || true)"
  rpath="$(readelf -d "$f" 2>/dev/null | grep -E 'RPATH|RUNPATH' || true)"
  printf '%s\t%s\t%s\t%s\t%s\n' "${rel}" "${zmm:-0}" "${ymm:-0}" "${glibc_max:-none}" \
    "$(printf '%s' "${rpath}" | tr '\n' ' ')" >> "${TMP}/records.tsv"
done < <(find "${DIR}" -type f \( -name 'libqgis*' -o -name 'qgis' -o -name 'qgis_process' \) -print0)

python3 - "${TMP}/records.tsv" "${KYLIN_GLIBC}" "${ALLOW_AVX512}" "${REPORT_DIR}" <<'PY'
import json, os, re, sys
records, target_glibc, allow_avx512, outdir = sys.argv[1:5]

def vk(s):
    return tuple(int(x) for x in (re.findall(r"\d+", s or "0") + ["0", "0", "0"])[:3])

rows = []
for line in open(records, encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 5:
        continue
    rows.append(dict(path=parts[0], avx512=int(parts[1] or 0), avx2=int(parts[2] or 0),
                     glibc=parts[3], rpath=parts[4]))

avx512 = [r for r in rows if r["avx512"] > 0]
avx2 = [r for r in rows if r["avx2"] > 0]
leaks = [r for r in rows if any(t in r["rpath"] for t in ("/work/", "/rpmbuild/", "BUILDROOT"))]
glibc_too_new = []
if target_glibc and "__UNCONFIRMED__" not in target_glibc:
    for r in rows:
        if r["glibc"] != "none" and vk(r["glibc"].replace("GLIBC_", "")) > vk(target_glibc):
            glibc_too_new.append(r)

report = {
    "policy": "x86-64 baseline (-march=x86-64 -mtune=generic), no AVX/AVX2/AVX-512",
    "target_glibc": target_glibc,
    "scanned_files": len(rows),
    "avx512_files": [r["path"] for r in avx512],
    "avx_or_avx2_files": [r["path"] for r in avx2],
    "rpath_leaks": [r["path"] for r in leaks],
    "glibc_too_new": glibc_too_new,
    "max_glibc_symbol": max((r["glibc"] for r in rows if r["glibc"] != "none"), default="none",
                            key=lambda x: vk(x.replace("GLIBC_", ""))),
    "verdict": "PASS",
}
problems = []
if avx512 and allow_avx512.lower() != "true":
    problems.append("检出 AVX-512/EVEX 指令，海光 C86 不支持")
if leaks:
    problems.append("二进制 RPATH/RUNPATH 泄漏构建机路径")
if glibc_too_new:
    problems.append("依赖的 GLIBC 符号版本高于目标系统 glibc")
if problems:
    report["verdict"] = "FAIL"
    report["problems"] = problems

os.makedirs(outdir, exist_ok=True)
with open(os.path.join(outdir, "isa-report.json"), "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)

print(json.dumps(report, ensure_ascii=False, indent=2))
if problems:
    for p in problems:
        print("[FAIL] " + p, file=sys.stderr)
    sys.exit(1)
if avx2:
    print("[WARN] 检出 ymm 指令（可能来自依赖库的运行时分发），请确认目标 CPU flags",
          file=sys.stderr)
PY
