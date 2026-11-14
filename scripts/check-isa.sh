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
need_cmd od "ELF 头读取"
: > "${TMP}/records.tsv"
: > "${TMP}/rpath-audit.tsv"

# 直接读 ELF 头原始字节判定 magic / e_machine，不依赖 readelf 的文本输出格式。
# 此前用 `readelf -h | awk -F: '/Machine:/'` 在 runner 的 readelf 上取不到
# Machine，导致 scanned_files=0 —— ISA 与 RPATH 泄漏检查被全部静默跳过。
elf_head() {
  od -An -tx1 -j"$2" -N"$3" "$1" 2>/dev/null | tr -d ' \n' || true
}

while IFS= read -r -d '' f; do
  rel="${f#"${DIR}"}"
  [[ "$(elf_head "$f" 0 4)" == "7f454c46" ]] || continue   # 非 ELF：wrapper / 数据文件
  [[ "$(elf_head "$f" 18 2)" == "3e00" ]] || { warn "非 x86-64 ELF: ${rel}"; continue; }
  objdump -d --no-show-raw-insn "$f" > "${TMP}/disasm" 2>/dev/null || continue
  zmm="$(grep -cE '%zmm[0-9]+|%k[0-7]\b' "${TMP}/disasm" || true)"
  ymm="$(grep -cE '%ymm[0-9]+' "${TMP}/disasm" || true)"
  glibc_max="$(objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' \
               | sort -Vu | tail -n1 || true)"
  rpath="$(readelf -d "$f" 2>/dev/null | grep -E 'RPATH|RUNPATH' || true)"
  printf '%s\t%s\t%s\t%s\t%s\n' "${rel}" "${zmm:-0}" "${ymm:-0}" "${glibc_max:-none}" \
    "$(printf '%s' "${rpath}" | tr '\n' ' ')" >> "${TMP}/records.tsv"
done < <(find "${DIR}" -type f \( -name 'libqgis*' -o -name 'qgis' -o -name 'qgis_process' \) -print0)

# 轻量全量 RPATH 审计：覆盖 deps/ 下的私有依赖（上面的 ISA 扫描只管 QGIS 自身）。
# 依赖阶段用 -Wl,-rpath,$DEPS_PREFIX 会把构建机绝对路径写进 Qt/GEOS/GDAL 等库，
# 30-build-qgis.sh 的 patchelf 统一后不应再残留；这里作为独立第二道门禁。
while IFS= read -r -d '' f; do
  [[ "$(elf_head "$f" 0 4)" == "7f454c46" ]] || continue
  rp="$(readelf -d "$f" 2>/dev/null | grep -E 'RPATH|RUNPATH' || true)"
  [[ -n "${rp}" ]] || continue
  printf '%s\t%s\n' "${f#"${DIR}"}" "$(printf '%s' "${rp}" | tr '\n' ' ')" \
    >> "${TMP}/rpath-audit.tsv"
done < <(find "${DIR}" -type f \
              \( -name '*.so' -o -name '*.so.*' -o -name 'qgis' -o -name 'qgis_*' \) -print0)

python3 - "${TMP}/records.tsv" "${KYLIN_GLIBC}" "${ALLOW_AVX512}" "${REPORT_DIR}" \
        "${TMP}/rpath-audit.tsv" <<'PY'
import json, os, re, sys
records, target_glibc, allow_avx512, outdir, rpath_audit = sys.argv[1:6]

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

# 构建机绝对路径特征：依赖阶段的 -Wl,-rpath,$DEPS_PREFIX 与 rpmbuild 临时目录
BAD = ("/work/", "/rpmbuild/", "BUILDROOT", "actions-runner",
       "_qgis-334-", "qgis-33412-work", "/usr/local/gcc11")
audit_rows = []
for line in open(rpath_audit, encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) == 2:
        audit_rows.append(dict(path=parts[0], rpath=parts[1]))
leaks = sorted({r["path"] for r in rows if any(t in r["rpath"] for t in BAD)}
               | {r["path"] for r in audit_rows if any(t in r["rpath"] for t in BAD)})
glibc_too_new = []
if target_glibc and "__UNCONFIRMED__" not in target_glibc:
    for r in rows:
        if r["glibc"] != "none" and vk(r["glibc"].replace("GLIBC_", "")) > vk(target_glibc):
            glibc_too_new.append(r)

report = {
    "policy": "x86-64 baseline (-march=x86-64 -mtune=generic), no AVX/AVX2/AVX-512",
    "target_glibc": target_glibc,
    "scanned_files": len(rows),
    "rpath_audited_files": len(audit_rows),
    "avx512_files": [r["path"] for r in avx512],
    "avx_or_avx2_files": [r["path"] for r in avx2],
    "rpath_leaks": leaks,
    "glibc_too_new": glibc_too_new,
    "max_glibc_symbol": max((r["glibc"] for r in rows if r["glibc"] != "none"), default="none",
                            key=lambda x: vk(x.replace("GLIBC_", ""))),
    "verdict": "PASS",
}
problems = []
if not rows:
    problems.append("未扫描到任何 QGIS ELF：ISA 校验形同虚设，检查 ELF 头识别逻辑")
if not audit_rows:
    problems.append("RPATH 审计未扫描到任何 ELF，无法证明私有依赖不依赖构建机路径")
if avx512 and allow_avx512.lower() != "true":
    problems.append("检出 AVX-512/EVEX 指令，海光 C86 不支持")
if leaks:
    problems.append("二进制 RPATH/RUNPATH 泄漏构建机路径（%d 个，示例: %s）"
                    % (len(leaks), ", ".join(leaks[:3])))
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
