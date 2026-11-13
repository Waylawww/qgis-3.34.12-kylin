#!/usr/bin/env bash
# Native Kylin V10 build entry point. Runs as the dedicated actionsrunner user.
# It never changes system packages or escalates privileges.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT="$ROOT"
export WORK_DIR="${WORK_DIR:-${RUNNER_TEMP:-$ROOT}/qgis-33412-work}"
export OUT_DIR="${OUT_DIR:-${RUNNER_TEMP:-$ROOT}/qgis-33412-out}"
export REPORT_DIR="${REPORT_DIR:-${RUNNER_TEMP:-$ROOT}/qgis-33412-reports}"
export LOG_DIR="$REPORT_DIR/logs"
mkdir -p "$WORK_DIR" "$OUT_DIR" "$REPORT_DIR" "$LOG_DIR"

fail() { echo "[native-build] ERROR: $*" >&2; exit 1; }
trap 'rc=$?; echo "[native-build] failed rc=$rc at line $LINENO" >&2; exit "$rc"' ERR

echo "== Native QGIS 3.34.12 build on target Kylin =="
echo "user=$(id -un), root=$ROOT"
[[ "$(uname -m)" == "x86_64" ]] || fail "Runner architecture is not x86_64"
grep -qE '^ID="?kylin"?$' /etc/os-release || fail "Runner is not Kylin; refusing non-native RPM build"
grep -qE '^VERSION_ID="?V?10"?$' /etc/os-release || fail "Runner is not Kylin V10"

# Generate truthful host facts and package mapping from the actual target host.
python3 "$ROOT/scripts/probe-kylin.py" --write --allow-unverified 2>&1 | tee "$LOG_DIR/dependency-probe.log"
cp "$ROOT/reports/dependency-matrix.json" "$REPORT_DIR/dependency-matrix.json"

# No fabricated package names, no Docker, no Ubuntu packages, no silent version downgrades.
python3 "$ROOT/scripts/check-deps.py" 2>&1 | tee "$LOG_DIR/dependency-gate.log" || {
  echo "Required QGIS build dependencies are missing or too old on this Kylin host." >&2
  echo "See dependency-matrix.json and dependency-gate.log in the uploaded artifact." >&2
  exit 20
}

bash "$ROOT/scripts/10-fetch-source.sh"
bash "$ROOT/scripts/20-render-spec.sh"
bash "$ROOT/scripts/30-rpmbuild.sh"
bash "$ROOT/scripts/40-verify-rpm.sh"

find "$OUT_DIR/rpms" -maxdepth 1 -type f -name '*.rpm' -printf '%f %s bytes\n'
