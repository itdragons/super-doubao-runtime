#!/bin/bash

set -uo pipefail

SCRIPT_NAME="official-npm-cli-install"
CONFIG_B64="${MCP_VM_OFFICIAL_NPM_CLI_INSTALL_CONFIG_B64:-}"
GOSU_BIN="${OFFICIAL_NPM_CLI_INSTALL_GOSU:-gosu}"
DEFAULT_ITEM_TIMEOUT_SECONDS=15
DEFAULT_MAX_PARALLELISM=4
WORK_DIR=""

log_info() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$*"
}

log_error() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$*" >&2
}

cleanup() {
  if [ -n "${WORK_DIR}" ]; then
    rm -rf "${WORK_DIR}"
  fi
}

now_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

finish() {
  printf '__RUNTIME_INIT_STATUS__=success\n'
  exit 0
}

if [ -z "${CONFIG_B64}" ]; then
  log_info "config absent; skip"
  finish
fi

WORK_DIR="$(mktemp -d "/tmp/${SCRIPT_NAME}.XXXXXX")"
trap cleanup EXIT
ITEMS_FILE="${WORK_DIR}/items.tsv"
MAX_PARALLELISM_FILE="${WORK_DIR}/max_parallelism.txt"
SUCCESS_FILE="${WORK_DIR}/success.txt"
FAILED_FILE="${WORK_DIR}/failed.txt"

if ! DEFAULT_ITEM_TIMEOUT_SECONDS="${DEFAULT_ITEM_TIMEOUT_SECONDS}" DEFAULT_MAX_PARALLELISM="${DEFAULT_MAX_PARALLELISM}" MAX_PARALLELISM_FILE="${MAX_PARALLELISM_FILE}" python3 - "${CONFIG_B64}" >"${ITEMS_FILE}" <<'PY'
import base64
import json
import os
import sys

def encode(value):
    return base64.b64encode(value.encode("utf-8")).decode("ascii")

try:
    raw = base64.b64decode(sys.argv[1], validate=True).decode("utf-8")
    config = json.loads(raw)
    if not isinstance(config, dict) or not isinstance(config.get("enabled"), bool):
        raise ValueError("config.enabled must be a boolean")
    if not config["enabled"]:
        sys.exit(0)
    items = config.get("items")
    if not isinstance(items, list):
        raise ValueError("config.items must be a list")
    default_timeout = int(os.environ.get("DEFAULT_ITEM_TIMEOUT_SECONDS", "15"))
    item_timeout_seconds = config.get("item_timeout_seconds", default_timeout)
    if not isinstance(item_timeout_seconds, int) or item_timeout_seconds <= 0:
        raise ValueError("config.item_timeout_seconds must be a positive integer")
    default_max_parallelism = int(os.environ.get("DEFAULT_MAX_PARALLELISM", "4"))
    max_parallelism = config.get("max_parallelism", default_max_parallelism)
    if not isinstance(max_parallelism, int) or max_parallelism <= 0:
        raise ValueError("config.max_parallelism must be a positive integer")
    with open(os.environ["MAX_PARALLELISM_FILE"], "w", encoding="utf-8") as f:
        f.write(str(max_parallelism))
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValueError(f"items[{index}] must be an object")
        name = item.get("name")
        command = item.get("command")
        kind = item.get("kind")
        enabled = item.get("enabled", True)
        if not isinstance(name, str) or not name or name in (".", "..") or "/" in name:
            raise ValueError(f"items[{index}].name must be a plain name")
        if kind != "official":
            raise ValueError(f"items[{index}].kind must be official")
        if not isinstance(command, str) or not command.strip().startswith("npm "):
            raise ValueError(f"items[{index}].command must start with npm")
        if not isinstance(enabled, bool):
            raise ValueError(f"items[{index}].enabled must be a boolean")
        if enabled:
            print("\t".join((encode(name), encode(command.strip()), str(item_timeout_seconds))))
except Exception as error:
    print(f"invalid official npm cli config: {error}", file=sys.stderr)
    sys.exit(1)
PY
then
  log_error "configuration invalid; skip installation"
  finish
fi

if [ ! -s "${ITEMS_FILE}" ]; then
  log_info "config has no enabled official items; skip"
  finish
fi
MAX_PARALLELISM="$(cat "${MAX_PARALLELISM_FILE}" 2>/dev/null || printf '%s' "${DEFAULT_MAX_PARALLELISM}")"

declare -a NAMES PIDS LOG_FILES ACTIVE_INDICES
ACTIVE_COUNT=0
# Ensure summary files always exist so the all-failed path never triggers an
# awk "cannot open file" error when joining an empty success list.
: >"${SUCCESS_FILE}"
: >"${FAILED_FILE}"

run_install_command() {
  local timeout_seconds="$1"
  local log_file="$2"
  local command="$3"
  GOSU_BIN="${GOSU_BIN}" timeout_seconds="${timeout_seconds}" log_file="${log_file}" command="${command}" python3 <<'PY'
import os
import signal
import subprocess
import sys

timeout_seconds = int(os.environ["timeout_seconds"])
log_file = os.environ["log_file"]
command = os.environ["command"]
gosu_bin = os.environ["GOSU_BIN"]

env = os.environ.copy()
env["HOME"] = "/home/user"
env["NPM_CONFIG_PREFIX"] = "/home/user/.npm-global"
env["npm_config_prefix"] = "/home/user/.npm-global"
env["PATH"] = f"/home/user/.npm-global/bin:{env.get('PATH', '')}"
argv = [
    gosu_bin,
    "user",
    "env",
    "HOME=/home/user",
    "NPM_CONFIG_PREFIX=/home/user/.npm-global",
    "npm_config_prefix=/home/user/.npm-global",
    f"PATH=/home/user/.npm-global/bin:{env.get('PATH', '')}",
    "bash",
    "-lc",
    'export PATH="${NPM_CONFIG_PREFIX}/bin:${PATH}"; eval "$1"',
    "_",
    command,
]

preexec_fn = os.setsid if hasattr(os, "setsid") else None
with open(log_file, "wb") as log:
    proc = subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=subprocess.STDOUT,
        env=env,
        preexec_fn=preexec_fn,
    )
    try:
        sys.exit(proc.wait(timeout=timeout_seconds))
    except subprocess.TimeoutExpired:
        log.write(f"\n[official-npm-cli-install] timed out after {timeout_seconds}s\n".encode())
        log.flush()
        if preexec_fn is not None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        else:
            proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            if preexec_fn is not None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            else:
                proc.kill()
            proc.wait()
        sys.exit(124)
PY
}

record_install_result() {
  local index="$1"
  local name="${NAMES[${index}]}"
  local log_file="${LOG_FILES[${index}]}"
  local code
  wait "${PIDS[${index}]}"
  code=$?
  if [ "${code}" -eq 0 ]; then
    log_info "SUCCESS ${name}"
    printf '%s\n' "${name}" >>"${SUCCESS_FILE}"
    return 0
  fi
  {
    printf '\n========== [OFFICIAL NPM CLI INSTALL FAILED] %s (install exit=%s) ==========\n' "${name}" "${code}"
    printf '%s\n' '--- captured output ---'
    cat "${log_file}"
    printf '========== [OFFICIAL NPM CLI INSTALL FAILED END] %s ==========\n\n' "${name}"
  } >&2
  printf '%s\n' "${name}" >>"${FAILED_FILE}"
  return 0
}

# Install items in parallel to keep startup fast. Official items are
# independent packages, so their payloads (lib/node_modules/<pkg>, bin/<pkg>)
# do not collide; each runs as `user` writing the same global prefix, which is
# safe for distinct packages. Each install is best-effort and captured to its
# own log so a single failure is isolated and reported without blocking others.
while IFS=$'\t' read -r name_b64 command_b64 timeout_seconds; do
  while [ "${ACTIVE_COUNT}" -ge "${MAX_PARALLELISM}" ]; do
    record_install_result "${ACTIVE_INDICES[0]}"
    ACTIVE_INDICES=("${ACTIVE_INDICES[@]:1}")
    ACTIVE_COUNT=$((ACTIVE_COUNT - 1))
  done
  name="$(printf '%s' "${name_b64}" | base64 -d)"
  command="$(printf '%s' "${command_b64}" | base64 -d)"
  log_file="${WORK_DIR}/${name}.log"
  log_info "START ${name} timeout=${timeout_seconds}s"
  (
    start_ms="$(now_ms)"
    run_install_command "${timeout_seconds}" "${log_file}" "${command}"
    code=$?
    end_ms="$(now_ms)"
    duration_ms=$((end_ms - start_ms))
    log_info "FINISH ${name} status=${code} duration_ms=${duration_ms}"
    exit "${code}"
  ) &
  NAMES+=("${name}")
  PIDS+=("$!")
  LOG_FILES+=("${log_file}")
  ACTIVE_INDICES+=("$((${#PIDS[@]} - 1))")
  ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
done <"${ITEMS_FILE}"

if [ "${ACTIVE_COUNT}" -gt 0 ]; then
  for index in "${ACTIVE_INDICES[@]}"; do
    record_install_result "${index}"
  done
fi

join_file() {
  awk 'NF { if (out == "") out = $0; else out = out ", " $0 } END { if (out == "") print "none"; else print out }' "$1"
}

log_info "SUCCEEDED: $(join_file "${SUCCESS_FILE}")"
log_info "FAILED: $(join_file "${FAILED_FILE}")"
log_info "completed in $((SECONDS * 1000))ms"
finish
