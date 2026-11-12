#!/usr/bin/env bash
# ============================================================================
# 阶段 6：QEMU/KVM 启动真实麒麟 V10 虚拟机，安装 RPM、启动 QGIS、渲染地图。
# 这是唯一可声称「目标系统实际运行」的阶段（STAGE_C）。
#
# 重要限制（不做虚假承诺）：
#   * GitHub 托管 runner 常常没有 /dev/kvm；本脚本自动降级为 TCG 软件模拟，
#     并在报告中记录 ACCEL=TCG。TCG 很慢，但 -cpu qemu64 恰好能验证
#     x86-64 基线 ISA（若二进制含 AVX/AVX2 指令会直接非法指令崩溃）。
#   * 没有 KYLIN_QCOW2_URL 时，STAGE_C 明确写 UNVERIFIED 并正常退出，
#     绝不把容器运行结果冒充目标系统运行结果。
#   * UKUI 图形会话/3D OpenGL 视图需要 GPU，云端 VM 一般无法验证，单独标注。
# ============================================================================
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# 这些值在 CI 中来自 Secrets/Variables；load_env 的 source 不能覆盖它们
_QCOW_URL="${KYLIN_QCOW2_URL:-}"
_QCOW_SHA="${KYLIN_QCOW2_SHA256:-}"
_VM_PASS="${KYLIN_VM_SSH_PASSWORD:-}"
_VM_USER_IN="${KYLIN_VM_SSH_USER:-}"
load_build_env
load_env "${KYLIN_ENV}"
load_env "${DEPS_ENV}"
export KYLIN_QCOW2_URL="${_QCOW_URL}"
export KYLIN_QCOW2_SHA256="${_QCOW_SHA}"
export KYLIN_VM_SSH_PASSWORD="${_VM_PASS}"
export KYLIN_VM_SSH_USER="${_VM_USER_IN}"

STAGES="${REPORT_DIR}/stages"
EVID="${OUT_DIR}/evidence/vm"
VMWORK="${WORK_DIR}/vm"
CI_LOCAL="${VMWORK}/ci-payload"
QCOW2="${VMWORK}/kylin.qcow2"
SEED="${VMWORK}/seed.iso"
DISK="${VMWORK}/disk.qcow2"
PIDFILE="${VMWORK}/qemu.pid"
SERIAL="${VMWORK}/serial.log"
mkdir -p "${STAGES}" "${EVID}" "${VMWORK}" "${CI_LOCAL}/rpms"

stage_marker STAGE_C_TARGET_VM_RUNTIME UNVERIFIED "${STAGES}/stage-c.json"
REQUIRE_VM=0
[[ "${1:-}" == "--require" ]] && REQUIRE_VM=1

if [[ -z "${KYLIN_QCOW2_URL:-}" ]]; then
  if (( REQUIRE_VM )); then
    die "--require 已指定但 KYLIN_QCOW2_URL 未配置：拒绝在没有目标系统验证的情况下宣称成功"
  fi
  warn "KYLIN_QCOW2_URL 未配置 —— STAGE_C = UNVERIFIED"
  warn "请提供与目标机同版本、且已装 cloud-init + sshd 的 Kylin V10 qcow2（见 docs/CONFIRM.md 第 6 节）"
  cat > "${REPORT_DIR}/target-vm-runtime.json" <<'JSON'
{"stage":"STAGE_C_TARGET_VM_RUNTIME","status":"UNVERIFIED",
 "reason":"KYLIN_QCOW2_URL 未提供；不得宣称目标系统运行成功"}
JSON
  exit 0
fi

need_cmd qemu-system-x86_64 "QEMU 虚拟机"
need_cmd qemu-img "磁盘处理"
need_cmd ssh "连接 VM"
need_cmd scp "传输 RPM"
need_cmd sshpass "cloud-init 密码登录（sudo apt install sshpass）"
need_cmd python3 "渲染 cloud-init 模板"

# --- 1. 获取并校验目标系统镜像 -----------------------------------------------
info "== 阶段 6 / QEMU TARGET VM (STAGE_C) =="
if [[ -f "${KYLIN_QCOW2_URL}" ]]; then
  cp -f "${KYLIN_QCOW2_URL}" "${QCOW2}"
else
  log "下载目标系统镜像"
  curl -fL "${KYLIN_QCOW2_URL}" -o "${QCOW2}"
fi
if [[ -n "${KYLIN_QCOW2_SHA256:-}" ]]; then
  echo "${KYLIN_QCOW2_SHA256}  ${QCOW2}" | sha256sum -c - || die "qcow2 SHA256 校验失败"
else
  warn "未提供 KYLIN_QCOW2_SHA256，无法确认镜像完整性"
fi
qemu-img info "${QCOW2}" | tee "${EVID}/qemu-img-info.txt"
cp -f "${QCOW2}" "${DISK}"
qemu-img resize "${DISK}" +8G >/dev/null 2>&1 || true

# --- 2. cloud-init seed ------------------------------------------------------
VM_USER="${KYLIN_VM_SSH_USER:-qgis-ci}"
VM_PASS="${KYLIN_VM_SSH_PASSWORD:-}"
[[ -n "${VM_PASS}" && "${VM_PASS}" != "__UNCONFIRMED__" ]] || die "KYLIN_VM_SSH_PASSWORD 未确认"
python3 - "${REPO_ROOT}" "${VMWORK}" "${VM_USER}" "${VM_PASS}" <<'PY'
import os, sys
root, out, user, pw = sys.argv[1:5]
pairs = {"@VM_USER@": user, "@VM_PASSWORD@": pw, "@INSTANCE_ID@": os.urandom(4).hex()}
for name in ("user-data", "meta-data"):
    src = os.path.join(root, "tests", "cloud-init", name + ".tpl")
    text = open(src, encoding="utf-8").read()
    for k, v in pairs.items():
        text = text.replace(k, v)
    open(os.path.join(out, name), "w", encoding="utf-8").write(text)
PY
if command -v cloud-localds >/dev/null 2>&1; then
  cloud-localds "${SEED}" "${VMWORK}/user-data" "${VMWORK}/meta-data"
elif command -v genisoimage >/dev/null 2>&1; then
  ( cd "${VMWORK}" && genisoimage -output "${SEED}" -volid cidata -joliet -rock user-data meta-data )
elif command -v mkisofs >/dev/null 2>&1; then
  ( cd "${VMWORK}" && mkisofs -output "${SEED}" -volid cidata -joliet -rock user-data meta-data )
else
  die "缺少 cloud-localds/genisoimage/mkisofs；Ubuntu runner 请 apt install cloud-image-utils genisoimage"
fi

# --- 3. 启动 QEMU ------------------------------------------------------------
ACCEL=""
KVM_MODE="TCG(qemu64 软件模拟)"
if [[ -e /dev/kvm && -r /dev/kvm ]]; then
  ACCEL="-enable-kvm"
  KVM_MODE="KVM(qemu64 基线 CPU 模型)"
elif [[ "${VM_REQUIRE_KVM:-false}" == "true" ]]; then
  die "VM_REQUIRE_KVM=true 但 /dev/kvm 不可用；请改用自托管/大规格 runner"
fi
log "加速模式: ${KVM_MODE}"

PORT="${VM_SSH_PORT:-2222}"
RAM="${VM_RAM_MB:-4096}"
CPUS="${VM_CPUS:-2}"
# 统一 -cpu qemu64：强制基线 ISA，避免宿主 CPU 特性掩盖 RPM 的 ISA 问题
# shellcheck disable=SC2086
qemu-system-x86_64 \
  -name qgis-kylin-ci \
  -m "${RAM}" -smp "${CPUS}" \
  ${ACCEL} -cpu qemu64 \
  -drive file="${DISK}",format=qcow2,if=virtio,cache=unsafe \
  -drive file="${SEED}",format=raw,if=virtio,media=cdrom,readonly=on \
  -netdev "user,id=net0,hostfwd=tcp::${PORT}-:22" \
  -device virtio-net-pci,netdev=net0 \
  -display none -serial "file:${SERIAL}" \
  -pidfile "${PIDFILE}" -daemonize
cleanup() {
  if [[ -f "${PIDFILE}" ]]; then kill "$(cat "${PIDFILE}")" 2>/dev/null || true; fi
  cp -f "${SERIAL}" "${EVID}/serial.log" 2>/dev/null || true
}
trap cleanup EXIT

sshx() {
  sshpass -p "${VM_PASS}" ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=8 -p "${PORT}" \
    "${VM_USER}@127.0.0.1" "$@"
}
scpx() {
  sshpass -p "${VM_PASS}" scp \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -P "${PORT}" "$@"
}

log "等待 cloud-init / sshd（超时 ${VM_BOOT_TIMEOUT_SEC:-900}s）"
ready=0
for ((i=0; i<${VM_BOOT_TIMEOUT_SEC:-900}/10; i++)); do
  if sshx true >/dev/null 2>&1; then ready=1; break; fi
  sleep 10
done
if (( ! ready )); then
  tail -n 120 "${SERIAL}" >&2 || true
  die "VM 未能在超时内启动 sshd。检查 cloud-init 是否安装、qcow2 是否支持 NoCloud、串口日志见 ${SERIAL}"
fi
sshx 'cat /etc/os-release; uname -r' | tee "${EVID}/vm-os.txt"

# --- 4. 传输并执行 -----------------------------------------------------------
cp -f "${OUT_DIR}/rpms/"*.rpm "${CI_LOCAL}/rpms/"
cp -f "${REPO_ROOT}/tests/pyqgis_smoke.py" "${CI_LOCAL}/"
cp -f "${REPO_ROOT}/tests/vm/run-in-vm.sh" "${CI_LOCAL}/"
printf '%s\n' ${QGIS_RUNTIME_REQUIRES} > "${CI_LOCAL}/runtime-requires.txt"

sshx 'rm -rf /tmp/qgis-ci && mkdir -p /tmp/qgis-ci'
scpx -r "${CI_LOCAL}/." "${VM_USER}@127.0.0.1:/tmp/qgis-ci/" >/dev/null

log "在目标 VM 内执行安装与渲染验证"
set +e
sshx 'chmod +x /tmp/qgis-ci/run-in-vm.sh && bash /tmp/qgis-ci/run-in-vm.sh' \
  2>&1 | tee "${EVID}/in-vm.log"
vm_rc=${PIPESTATUS[0]}
set -e

scpx -r "${VM_USER}@127.0.0.1:/tmp/qgis-ci/evidence/." "${EVID}/" >/dev/null 2>&1 || true
cp -f "${SERIAL}" "${EVID}/serial.log" || true

python3 - "${EVID}" "${REPORT_DIR}" "${STAGES}" "${KVM_MODE}" "${vm_rc}" <<'PY'
import json, os, sys
evid, rep, stages, accel, rc = sys.argv[1:6]
vp = os.path.join(evid, "verdict.json")
verdict = json.load(open(vp, encoding="utf-8")) if os.path.exists(vp) else {
    "verdict": "FAIL", "reason": "VM 内未生成 verdict.json"}
status = "PASS" if rc == "0" and verdict.get("verdict") == "PASS" else "FAIL"
out = {"stage": "STAGE_C_TARGET_VM_RUNTIME", "status": status,
       "accel": accel, "in_vm_rc": int(rc), "details": verdict}
with open(os.path.join(rep, "target-vm-runtime.json"), "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
with open(os.path.join(stages, "stage-c.json"), "w", encoding="utf-8") as f:
    json.dump({"stage": "STAGE_C_TARGET_VM_RUNTIME", "status": status},
              f, ensure_ascii=False, indent=2)
print(json.dumps(out, ensure_ascii=False, indent=2))
sys.exit(0 if status == "PASS" else 1)
PY

info "STAGE_C PASS —— 真实麒麟 V10 虚拟机中 RPM 安装 / QGIS 启动 / 地图渲染均通过"
info "仍未验证：海光 C86 物理 CPU、UKUI GPU 图形会话、3D OpenGL 视图（STAGE_D）"
