#!/bin/bash

set -euo pipefail

MODE="${1:-restore}"
CONFIG_B64="${MCP_VM_PERSISTENT_SYNC_CONFIG_B64:-}"
WORK_DIR="${PERSISTENT_SYNC_WORK_DIR:-/tmp/persistent-sync}"
ALLOWED_HOME="${PERSISTENT_SYNC_ALLOWED_HOME:-/home/user}"
SYNC_OWNER="${PERSISTENT_SYNC_OWNER:-user:user}"
PIDFILE="${PERSISTENT_SYNC_PIDFILE:-/run/persistent-sync.pid}"
RUNTIME_INIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="${RUNTIME_INIT_DIR}/persistent_sync.sh"
MIN_RUNTIME_PULL_INTERVAL_SECONDS=10
DEFAULT_INOTIFY_COMPACT_MIN_LINES=10000
INOTIFY_COMPACT_MIN_LINES="${PERSISTENT_SYNC_INOTIFY_COMPACT_MIN_LINES:-${DEFAULT_INOTIFY_COMPACT_MIN_LINES}}"
case "${INOTIFY_COMPACT_MIN_LINES}" in
  ''|*[!0-9]*) INOTIFY_COMPACT_MIN_LINES="${DEFAULT_INOTIFY_COMPACT_MIN_LINES}" ;;
esac
# PERSISTENT_SYNC_MAX_TICKS caps the run-loop iterations for tests; empty means
# run forever in production.
MAX_TICKS="${PERSISTENT_SYNC_MAX_TICKS:-}"

log() {
  echo "[persistent-sync] $*"
}

now_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

# emit_status prints the runtime-init status marker consumed by the Go runner.
# Every terminating path MUST call this exactly once.
emit_status() {
  printf '__RUNTIME_INIT_STATUS__=%s\n' "$1"
}

# fail_hard logs, emits a failed marker and exits nonzero. Used for invalid
# configuration so the caller never mistakes a silent skip for success.
fail_hard() {
  log "$1" >&2
  emit_status failed
  exit 1
}

if [ -z "${CONFIG_B64}" ]; then
  log "configuration is absent; skip ${MODE}"
  emit_status skipped
  exit 0
fi

mkdir -p "${WORK_DIR}"
# WORK_DIR must be a root-private real directory, never a user-planted symlink.
if [ -L "${WORK_DIR}" ]; then
  fail_hard "work dir must not be a symlink: ${WORK_DIR}"
fi
chmod 700 "${WORK_DIR}"
CONFIG_FILE="${WORK_DIR}/config.json"
printf '%s' "${CONFIG_B64}" | base64 -d >"${CONFIG_FILE}" || fail_hard "config base64 decode failed"
chmod 600 "${CONFIG_FILE}"

# config_field <json-key> echoes a scalar config value, or empty on error.
config_field() {
  python3 - "${CONFIG_FILE}" "$1" <<'PY' 2>/dev/null || true
import json, sys
cfg = json.load(open(sys.argv[1]))
val = cfg.get(sys.argv[2])
if isinstance(val, bool):
    print("true" if val else "false")
elif val is not None:
    print(val)
PY
}

runtime_pull_interval() {
  local value
  value="$(config_field runtime_pull_interval_seconds)"
  case "${value}" in
    ''|*[!0-9]*) printf '%s\n' "${MIN_RUNTIME_PULL_INTERVAL_SECONDS}" ;;
    *)
      if [ "${value}" -lt "${MIN_RUNTIME_PULL_INTERVAL_SECONDS}" ]; then
        printf '%s\n' "${MIN_RUNTIME_PULL_INTERVAL_SECONDS}"
      else
        printf '%s\n' "${value}"
      fi
      ;;
  esac
}

# validate_and_emit_units validates the config and prints one TSV line per unit.
# It exits nonzero (and prints nothing usable) on any validation error so the
# caller can hard-fail instead of silently syncing nothing.
validate_and_emit_units() {
  python3 - "${CONFIG_FILE}" "${ALLOWED_HOME}" <<'PY'
import json
import os
import posixpath
import sys

config_path, allowed_home = sys.argv[1:]
with open(config_path, encoding="utf-8") as f:
    config = json.load(f)

root = config.get("persistent_root")
if not isinstance(root, str) or not root.startswith("/"):
    raise ValueError("persistent_root must be absolute")
if os.path.islink(root):
    raise ValueError("persistent_root must not be a symlink")
if not config.get("enabled", False):
    sys.exit(0)

def is_allowed_local_path(value):
    if not isinstance(value, str) or not os.path.isabs(value) or os.path.normpath(value) != value:
        return False
    if value == allowed_home:
        return False
    try:
        return os.path.commonpath((allowed_home, value)) == allowed_home
    except ValueError:
        return False


for unit in config.get("units", []):
    name = unit.get("name")
    remote = unit.get("remote_path")
    local = unit.get("local_path")
    if not isinstance(name, str) or not name or "/" in name or name in (".", ".."):
        raise ValueError("unit name must be plain")
    if not isinstance(remote, str) or not remote or remote.startswith("/") or posixpath.normpath(remote) != remote or remote.startswith("../"):
        raise ValueError("unit remote_path must be clean and relative")
    if not is_allowed_local_path(local):
        raise ValueError("unit local_path is not allowed")
    push_delete_enabled = unit.get("push_delete_enabled", False)
    if not isinstance(push_delete_enabled, bool):
        raise ValueError("unit push_delete_enabled must be a boolean")
    is_file = unit.get("is_file", False)
    if not isinstance(is_file, bool):
        raise ValueError("unit is_file must be a boolean")
    excludes = list(config.get("global_excludes", [])) + list(unit.get("excludes", []))
    print("\t".join((name, root, remote, local, "true" if push_delete_enabled else "false", json.dumps(excludes), "true" if is_file else "false")))
PY
}

write_excludes() {
  local name="$1"
  local json="$2"
  python3 - "${WORK_DIR}/excludes.${name}" "${json}" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as f:
    for value in json.loads(sys.argv[2]):
        if not isinstance(value, str) or "\n" in value or "\r" in value:
            raise ValueError("invalid exclude")
        f.write(value + "\n")
PY
  chmod 600 "${WORK_DIR}/excludes.${name}"
  printf '%s' "${WORK_DIR}/excludes.${name}"
}

# symlink_below_base <base> <path> returns 0 (violation) if <path> is not
# strictly under <base>, or if <path> itself or any component BETWEEN <base>
# and <path> is a symlink. Components at or above <base> are root-controlled
# (the allowed HOME or the root-private persistent root) and are intentionally
# not checked, so legitimate system symlinks above the base (e.g. macOS
# /var -> /private/var) do not cause false positives. This defends against a
# warm-sandbox user pre-planting a link like ~/.config -> /etc to redirect a
# privileged rsync/chown.
symlink_below_base() {
  local base="$1" path="$2"
  case "${path}/" in
    "${base}/"*) ;;                 # path is under base: ok, keep checking
    *) return 0 ;;                  # path escaped base: violation
  esac
  local cur="${path}"
  while [ "${cur}" != "${base}" ] && [ "${cur}" != "/" ] && [ -n "${cur}" ]; do
    if [ -L "${cur}" ]; then
      return 0
    fi
    cur="$(dirname "${cur}")"
  done
  # Final containment guard: if the path exists, its resolved location must
  # still live under base (compare physical paths so a base that itself sits
  # under a system symlink, e.g. macOS /var -> /private/var, is not a false
  # positive).
  if [ -e "${path}" ]; then
    local real base_real
    real="$(cd "${path}" 2>/dev/null && pwd -P || true)"
    base_real="$(cd "${base}" 2>/dev/null && pwd -P || true)"
    if [ -n "${real}" ] && [ -n "${base_real}" ]; then
      case "${real}/" in
        "${base_real}/"*) ;;
        *) return 0 ;;
      esac
    fi
  fi
  return 1
}

# UNITS_FILE holds the validated units for the current invocation.
UNITS_FILE="${WORK_DIR}/units.tsv"
INOTIFY_EVENTS_FILE="${WORK_DIR}/inotify.events"
INOTIFY_EVENTS_OFFSET=0
INOTIFY_PID=""
PENDING_PUSH_UNITS=""
PENDING_DELETE_UNITS=""
PENDING_PUSH_RETRY_TICKS=0
LAST_PUSH_SUCCEEDED_UNITS=""

# load_units validates config once and materializes units. Hard-fails on
# invalid config; leaves an empty units file when sync is disabled/empty.
load_units() {
  if ! validate_and_emit_units >"${UNITS_FILE}" 2>"${WORK_DIR}/validate.err"; then
    fail_hard "persistent sync config invalid: $(tr '\n' ' ' <"${WORK_DIR}/validate.err")"
  fi
}

# sync_one <direction> <name> <root> <remote> <local> <push-delete-enabled> <excludes-json> [use-delete]
# Performs a single rsync for one unit after symlink guards. Never fatal on a
# per-unit rsync failure; symlink hits are skipped with a warning.
log_rsync_changes() {
  local direction="$1" name="$2" changes="$3"
  local files_json
  files_json="$(python3 - "${changes}" <<'PY'
import json
import sys

files = []
for raw_line in sys.argv[1].splitlines():
    line = raw_line.strip()
    if not line:
        continue
    if line.startswith("*deleting "):
        path = line[len("*deleting "):].strip()
    else:
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        path = parts[1].strip()
    if path:
        files.append(path)
print(json.dumps(files, ensure_ascii=False, separators=(",", ":")))
PY
)"
  log "${direction} changed files: unit=${name} files=${files_json}"
}

log_sync_start() {
  local direction="$1" name="$2" is_file="$3" use_delete="$4" push_delete_enabled="$5" local="$6" remote="$7"
  log "sync start: direction=${direction} unit=${name} is_file=${is_file} use_delete=${use_delete} push_delete_enabled=${push_delete_enabled} local=${local} remote=${remote}"
}

log_sync_finish() {
  local direction="$1" name="$2" status="$3" start_ms="$4" is_file="$5" use_delete="$6"
  log "sync finish: direction=${direction} unit=${name} status=${status} duration_ms=$(( $(now_ms) - start_ms )) is_file=${is_file} use_delete=${use_delete}"
}

sync_one_file() {
  local direction="$1" name="$2" root="$3" remote="$4" local="$5" push_delete_enabled="$6" excludes="$7" use_delete="${8:-false}"
  local excludes_file remote_file local_parent remote_parent start_ms
  remote_file="${root}/${remote}"
  local_parent="$(dirname "${local}")"
  remote_parent="$(dirname "${remote_file}")"
  start_ms="$(now_ms)"
  log_sync_start "${direction}" "${name}" true "${use_delete}" "${push_delete_enabled}" "${local}" "${remote_file}"

  if symlink_below_base "${ALLOWED_HOME}" "${local}"; then
    log "refuse: local file path escapes home or contains a symlink; skip unit ${name}: ${local}" >&2
    log_sync_finish "${direction}" "${name}" "refused" "${start_ms}" true "${use_delete}"
    return 1
  fi
  if symlink_below_base "${root}" "${remote_file}"; then
    log "refuse: remote file path escapes root or contains a symlink; skip unit ${name}: ${remote_file}" >&2
    log_sync_finish "${direction}" "${name}" "refused" "${start_ms}" true "${use_delete}"
    return 1
  fi

  excludes_file="$(write_excludes "${name}" "${excludes}")"
  mkdir -p "${remote_parent}" "${local_parent}"
  chmod 700 "${root}" "${remote_parent}"

  if [ "${direction}" = "restore" ] || [ "${direction}" = "pull" ]; then
    local rsync_output
    if [ ! -e "${remote_file}" ]; then
      log "${direction} skipped absent file: ${name}"
      log_sync_finish "${direction}" "${name}" "skipped_absent" "${start_ms}" true "${use_delete}"
      return 0
    fi
    if [ ! -f "${remote_file}" ]; then
      log "refuse: remote file path is not a regular file; skip unit ${name}: ${remote_file}" >&2
      log_sync_finish "${direction}" "${name}" "refused" "${start_ms}" true "${use_delete}"
      return 1
    fi
    if [ -e "${local}" ] && [ ! -f "${local}" ]; then
      log "refuse: local file path is not a regular file; skip unit ${name}: ${local}" >&2
      log_sync_finish "${direction}" "${name}" "refused" "${start_ms}" true "${use_delete}"
      return 1
    fi
    if rsync_output="$(rsync -a --itemize-changes --chown="${SYNC_OWNER}" "--exclude-from=${excludes_file}" "${remote_file}" "${local}" 2>&1)"; then
      log_rsync_changes "${direction}" "${name}" "${rsync_output}"
      log "${direction} succeeded: ${name}"
      log_sync_finish "${direction}" "${name}" "success" "${start_ms}" true "${use_delete}"
    else
      log "${direction} failed: ${name}" >&2
      [ -n "${rsync_output}" ] && printf '%s\n' "${rsync_output}" >&2
      log_sync_finish "${direction}" "${name}" "failed" "${start_ms}" true "${use_delete}"
      return 1
    fi
    chown "${SYNC_OWNER}" "${local}" 2>/dev/null || log "ownership repair skipped: ${name}" >&2
  else
    local rsync_output
    if [ ! -e "${local}" ]; then
      log "push skipped absent file: ${name}"
      log_sync_finish "push" "${name}" "skipped_absent" "${start_ms}" true "${use_delete}"
      return 0
    fi
    if [ ! -f "${local}" ]; then
      log "refuse: local file path is not a regular file; skip unit ${name}: ${local}" >&2
      log_sync_finish "push" "${name}" "refused" "${start_ms}" true "${use_delete}"
      return 1
    fi
    if [ -e "${remote_file}" ] && [ ! -f "${remote_file}" ]; then
      log "refuse: remote file path is not a regular file; skip unit ${name}: ${remote_file}" >&2
      log_sync_finish "push" "${name}" "refused" "${start_ms}" true "${use_delete}"
      return 1
    fi
    if rsync_output="$(rsync -a --itemize-changes --chown=root:root "--exclude-from=${excludes_file}" "${local}" "${remote_file}" 2>&1)"; then
      log_rsync_changes "push" "${name}" "${rsync_output}"
      log "push succeeded: ${name}"
      log_sync_finish "push" "${name}" "success" "${start_ms}" true "${use_delete}"
    else
      log "push failed: ${name}" >&2
      [ -n "${rsync_output}" ] && printf '%s\n' "${rsync_output}" >&2
      log_sync_finish "push" "${name}" "failed" "${start_ms}" true "${use_delete}"
      return 1
    fi
  fi
  return 0
}

sync_one() {
  local direction="$1" name="$2" root="$3" remote="$4" local="$5" push_delete_enabled="$6" excludes="$7" is_file="$8" use_delete="${9:-false}"
  local excludes_file remote_dir start_ms
  remote_dir="${root}/${remote}"

  if [ "${is_file}" = "true" ]; then
    sync_one_file "${direction}" "${name}" "${root}" "${remote}" "${local}" "${push_delete_enabled}" "${excludes}" "${use_delete}"
    return $?
  fi
  start_ms="$(now_ms)"
  log_sync_start "${direction}" "${name}" false "${use_delete}" "${push_delete_enabled}" "${local}" "${remote_dir}"

  # Symlink guards: refuse to let root write through user-controllable links.
  # local paths must stay under the allowed HOME; remote paths under root.
  if symlink_below_base "${ALLOWED_HOME}" "${local}"; then
    log "refuse: local path escapes home or contains a symlink; skip unit ${name}: ${local}" >&2
    log_sync_finish "${direction}" "${name}" "refused" "${start_ms}" false "${use_delete}"
    return 1
  fi
  if symlink_below_base "${root}" "${remote_dir}"; then
    log "refuse: remote path escapes root or contains a symlink; skip unit ${name}: ${remote_dir}" >&2
    log_sync_finish "${direction}" "${name}" "refused" "${start_ms}" false "${use_delete}"
    return 1
  fi

  excludes_file="$(write_excludes "${name}" "${excludes}")"
  mkdir -p "${remote_dir}" "${local}"
  chmod 700 "${root}" "${remote_dir}"

  if [ "${direction}" = "restore" ] || [ "${direction}" = "pull" ]; then
    local rsync_output
    if rsync_output="$(rsync -a --itemize-changes --chown="${SYNC_OWNER}" "--exclude-from=${excludes_file}" "${remote_dir}/" "${local}/" 2>&1)"; then
      log_rsync_changes "${direction}" "${name}" "${rsync_output}"
      log "${direction} succeeded: ${name}"
      log_sync_finish "${direction}" "${name}" "success" "${start_ms}" false "${use_delete}"
    else
      log "${direction} failed: ${name}" >&2
      [ -n "${rsync_output}" ] && printf '%s\n' "${rsync_output}" >&2
      log_sync_finish "${direction}" "${name}" "failed" "${start_ms}" false "${use_delete}"
      return 1
    fi
    chown "${SYNC_OWNER}" "${local}" 2>/dev/null || log "ownership repair skipped: ${name}" >&2
  else
    local rsync_output
    if rsync_output="$(rsync -a --itemize-changes --chown=root:root "--exclude-from=${excludes_file}" "${local}/" "${remote_dir}/" 2>&1)"; then
      log_rsync_changes "push" "${name}" "${rsync_output}"
      log "push succeeded: ${name}"
      log_sync_finish "push" "${name}" "success" "${start_ms}" false "${use_delete}"
    else
      log "push failed: ${name}" >&2
      [ -n "${rsync_output}" ] && printf '%s\n' "${rsync_output}" >&2
      log_sync_finish "push" "${name}" "failed" "${start_ms}" false "${use_delete}"
      return 1
    fi
  fi
  return 0
}

# sync_units <direction> iterates the validated units. Returns 1 if any unit
# was skipped/failed so callers can surface a non-success status.
sync_units() {
  local direction="$1" target_unit="${2:-}" use_delete="${3:-false}"
  local had_error=0
  local name root remote local push_delete_enabled excludes is_file
  if [ ! -s "${UNITS_FILE}" ]; then
    return 0
  fi
  while IFS=$'\t' read -r name root remote local push_delete_enabled excludes is_file; do
    [ -n "${name}" ] || continue
    if [ -n "${target_unit}" ] && [ "${name}" != "${target_unit}" ]; then
      continue
    fi
    if ! sync_one "${direction}" "${name}" "${root}" "${remote}" "${local}" "${push_delete_enabled}" "${excludes}" "${is_file}" "${use_delete}"; then
      had_error=1
    fi
  done <"${UNITS_FILE}"
  return "${had_error}"
}

event_is_delete() {
  local events="$1"
  case ",${events}," in
    *",DELETE,"*|*",MOVED_FROM,"*|*",MOVE_SELF,"*|*",DELETE_SELF,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# resolve_inotify_events <events-file> emits:
#   <unit-name>\t<push-delete-enabled>\t<is-delete>
# It assigns nested paths to the most specific unit, then drops events matched
# by that unit's rsync excludes. Filtering a whole debounce batch in one Python
# process avoids per-event process overhead on noisy browser/config trees.
resolve_inotify_events() {
  local events_file="$1"
  python3 - "${UNITS_FILE}" "${events_file}" <<'PY'
import json
import os
import re
import sys

units_file, events_file = sys.argv[1:]


def glob_regex(pattern):
    result = []
    index = 0
    while index < len(pattern):
        char = pattern[index]
        if char == "*":
            if index + 1 < len(pattern) and pattern[index + 1] == "*":
                index += 2
                if index < len(pattern) and pattern[index] == "/":
                    result.append("(?:.*/)?")
                    index += 1
                else:
                    result.append(".*")
                continue
            result.append("[^/]*")
        elif char == "?":
            result.append("[^/]")
        else:
            result.append(re.escape(char))
        index += 1
    return "".join(result)


def compile_exclude(pattern):
    pattern = pattern.replace("\\", "/")
    anchored = pattern.startswith("/")
    pattern = pattern.lstrip("/")
    directory = pattern.endswith("/")
    pattern = pattern.rstrip("/")
    if pattern.endswith("/**"):
        directory = True
        pattern = pattern[:-3].rstrip("/")
    if not pattern:
        return None
    if "/" not in pattern:
        body = glob_regex(pattern)
        return re.compile(r"(?:^|/)" + body + (r"(?:/.*)?$" if directory else r"$"))
    body = glob_regex(pattern)
    prefix = "^" if anchored else r"(?:^|.*/)"
    suffix = r"(?:/.*)?$" if directory else "$"
    return re.compile(prefix + body + suffix)


units = []
with open(units_file, encoding="utf-8") as stream:
    for raw in stream:
        fields = raw.rstrip("\n").split("\t", 6)
        if len(fields) != 7:
            continue
        name, _root, _remote, local, push_delete_enabled, excludes_json, is_file = fields
        excludes = [
            compiled
            for value in json.loads(excludes_json)
            if (compiled := compile_exclude(value)) is not None
        ]
        units.append((name, os.path.normpath(local), push_delete_enabled, excludes, is_file == "true"))

delete_events = {"DELETE", "MOVED_FROM", "MOVE_SELF", "DELETE_SELF"}
with open(events_file, encoding="utf-8", errors="replace") as stream:
    for raw in stream:
        raw = raw.rstrip("\n")
        if not raw:
            continue
        if "\t" in raw:
            fields = raw.split("\t", 2)
        else:
            fields = raw.split(" ", 2)
        if len(fields) != 3:
            continue
        event_dir, event_names, event_file = fields
        event_path = os.path.normpath(os.path.join(event_dir, event_file))
        candidates = []
        for unit in units:
            local = unit[1]
            try:
                if os.path.commonpath((event_path, local)) == local:
                    candidates.append(unit)
            except ValueError:
                continue
        if not candidates:
            continue
        name, local, push_delete_enabled, excludes, _is_file = max(
            candidates, key=lambda unit: len(unit[1])
        )
        relative = os.path.relpath(event_path, local).replace(os.sep, "/")
        if relative == ".":
            relative = ""
        if any(pattern.search(relative) for pattern in excludes):
            continue
        is_delete = any(value in delete_events for value in event_names.split(","))
        print("\t".join((name, push_delete_enabled, "true" if is_delete else "false")))
PY
}

build_native_inotify_exclude_regex() {
  python3 - "${UNITS_FILE}" <<'PY'
import json
import os
import posixpath
import sys

units = []
with open(sys.argv[1], encoding="utf-8") as stream:
    for raw in stream:
        fields = raw.rstrip("\n").split("\t", 6)
        if len(fields) != 7:
            continue
        name, _root, _remote, local, _push_delete_enabled, excludes_json, _is_file = fields
        units.append({
            "name": name,
            "local": posixpath.normpath(local),
            "excludes": list(json.loads(excludes_json)),
        })

if not units:
    sys.exit(0)


def ere_escape(value):
    result = []
    for char in value:
        if char in r"\.^$+(){}|[]":
            result.append("\\" + char)
        else:
            result.append(char)
    return "".join(result)


def glob_to_ere(pattern):
    pattern = pattern.replace("\\", "/")
    anchored = pattern.startswith("/")
    pattern = pattern.lstrip("/")
    directory = pattern.endswith("/")
    pattern = pattern.rstrip("/")
    if pattern.endswith("/**"):
        directory = True
        pattern = pattern[:-3].rstrip("/")
    any_prefix = pattern.startswith("**/")
    if any_prefix:
        pattern = pattern[3:]
    if not pattern:
        return None
    result = []
    index = 0
    while index < len(pattern):
        char = pattern[index]
        if char == "*":
            if index + 1 < len(pattern) and pattern[index + 1] == "*":
                index += 2
                if index < len(pattern) and pattern[index] == "/":
                    result.append("(.*/)?")
                    index += 1
                else:
                    result.append(".*")
                continue
            result.append("[^/]*")
        elif char == "?":
            result.append("[^/]")
        else:
            result.append(ere_escape(char))
        index += 1
    prefix = "^" if anchored else "(^|.*/)"
    suffix = "(/.*)?$" if directory else "$"
    return prefix + "".join(result) + suffix


def paths_overlap(left, right):
    return (
        left == right
        or left.startswith(right + "/")
        or right.startswith(left + "/")
    )


common = set(units[0]["excludes"])
for unit in units[1:]:
    common.intersection_update(unit["excludes"])

patterns = []
for pattern in sorted(common):
    compiled = glob_to_ere(pattern)
    if compiled:
        patterns.append(compiled)

for unit in units:
    for pattern in unit["excludes"]:
        if pattern in common:
            continue
        normalized = pattern.replace("\\", "/")
        if not normalized.endswith("/") or any(char in normalized for char in "*?["):
            continue
        excluded_path = posixpath.normpath(
            posixpath.join(unit["local"], normalized.lstrip("/"))
        )
        overlaps_child = any(
            other["local"] != unit["local"]
            and other["local"].startswith(unit["local"] + "/")
            and paths_overlap(excluded_path, other["local"])
            for other in units
        )
        if not overlaps_child:
            patterns.append("^" + ere_escape(excluded_path) + "(/|$)")

patterns = list(dict.fromkeys(patterns))
if patterns:
    print("(" + "|".join(patterns) + ")")
PY
}

start_inotify_watcher() {
  local events waited native_exclude_regex watched_units dir_watch_paths file_watch_paths watcher_count=0 pid ready_count
  events="close_write,create,delete,move,attrib,move_self,delete_self,unmount"
  : >"${INOTIFY_EVENTS_FILE}"
  INOTIFY_EVENTS_OFFSET=0
  : >"${WORK_DIR}/inotify.err"
  watched_units="$(awk -F '\t' 'BEGIN { ORS="" } { printf "%s%s", (NR == 1 ? "" : ","), $1 }' "${UNITS_FILE}")"
  native_exclude_regex="$(build_native_inotify_exclude_regex)"
  dir_watch_paths="$(awk -F '\t' '$7 != "true" { print $4 }' "${UNITS_FILE}" | sort -u)"
  file_watch_paths="$(awk -F '\t' '$7 == "true" { path=$4; sub("/[^/]*$", "", path); print path }' "${UNITS_FILE}" | sort -u)"
  INOTIFY_PID=""
  if [ -n "${dir_watch_paths}" ] && [ -n "${native_exclude_regex}" ]; then
    inotifywait -r -m -e "${events}" --exclude "${native_exclude_regex}" --format $'%w\t%e\t%f' ${dir_watch_paths} \
      >>"${INOTIFY_EVENTS_FILE}" 2>>"${WORK_DIR}/inotify.err" &
    pid=$!
    INOTIFY_PID="${INOTIFY_PID} ${pid}"
    watcher_count=$((watcher_count + 1))
  elif [ -n "${dir_watch_paths}" ]; then
    inotifywait -r -m -e "${events}" --format $'%w\t%e\t%f' ${dir_watch_paths} \
      >>"${INOTIFY_EVENTS_FILE}" 2>>"${WORK_DIR}/inotify.err" &
    pid=$!
    INOTIFY_PID="${INOTIFY_PID} ${pid}"
    watcher_count=$((watcher_count + 1))
  fi
  if [ -n "${file_watch_paths}" ] && [ -n "${native_exclude_regex}" ]; then
    inotifywait -m -e "${events}" --exclude "${native_exclude_regex}" --format $'%w\t%e\t%f' ${file_watch_paths} \
      >>"${INOTIFY_EVENTS_FILE}" 2>>"${WORK_DIR}/inotify.err" &
    pid=$!
    INOTIFY_PID="${INOTIFY_PID} ${pid}"
    watcher_count=$((watcher_count + 1))
  elif [ -n "${file_watch_paths}" ]; then
    inotifywait -m -e "${events}" --format $'%w\t%e\t%f' ${file_watch_paths} \
      >>"${INOTIFY_EVENTS_FILE}" 2>>"${WORK_DIR}/inotify.err" &
    pid=$!
    INOTIFY_PID="${INOTIFY_PID} ${pid}"
    watcher_count=$((watcher_count + 1))
  fi
  log "inotify watcher started: units=${watched_units}"
  waited=0
  while [ "${waited}" -lt 20 ]; do
    ready_count="$(grep -c "Watches established" "${WORK_DIR}/inotify.err" 2>/dev/null || true)"
    if [ "${ready_count}" -ge "${watcher_count}" ]; then
      return 0
    fi
    local any_running=false
    for pid in ${INOTIFY_PID}; do
      if kill -0 "${pid}" 2>/dev/null; then
        any_running=true
      fi
    done
    if [ "${any_running}" != "true" ]; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
}

stop_inotify_watcher() {
  local pid
  for pid in ${INOTIFY_PID}; do
    if kill -0 "${pid}" 2>/dev/null; then
      kill -CONT "${pid}" 2>/dev/null || true
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
  INOTIFY_PID=""
}

# drain_inotify_events <batch-file> copies unread events into batch-file and
# advances the offset in the current shell. Do not call this through command
# substitution: assignments made in a command-substitution subshell are lost.
drain_inotify_events() {
  local batch_file="$1" total start count
  : >"${batch_file}"
  if [ ! -s "${INOTIFY_EVENTS_FILE}" ]; then
    return 0
  fi
  total="$(wc -l <"${INOTIFY_EVENTS_FILE}" | tr -d ' ')"
  if [ "${total}" -le "${INOTIFY_EVENTS_OFFSET}" ]; then
    return 0
  fi
  start=$((INOTIFY_EVENTS_OFFSET + 1))
  count=$((total - INOTIFY_EVENTS_OFFSET))
  INOTIFY_EVENTS_OFFSET="${total}"
  tail -n +"${start}" "${INOTIFY_EVENTS_FILE}" | head -n "${count}" >"${batch_file}"
}

discard_inotify_events() {
  local total
  if [ ! -s "${INOTIFY_EVENTS_FILE}" ]; then
    return 0
  fi
  total="$(wc -l <"${INOTIFY_EVENTS_FILE}" | tr -d ' ')"
  INOTIFY_EVENTS_OFFSET="${total}"
}

compact_inotify_events() {
  local total start unread_file watcher_stopped=false waited=0 state="" compact_status=0 pid all_stopped
  [ "${INOTIFY_COMPACT_MIN_LINES}" -gt 0 ] || return 0
  [ "${INOTIFY_EVENTS_OFFSET}" -gt 0 ] || return 0
  if [ ! -s "${INOTIFY_EVENTS_FILE}" ]; then
    INOTIFY_EVENTS_OFFSET=0
    return 0
  fi
  total="$(wc -l <"${INOTIFY_EVENTS_FILE}" | tr -d ' ')"
  [ "${total}" -ge "${INOTIFY_COMPACT_MIN_LINES}" ] || return 0

  if [ -n "${INOTIFY_PID}" ]; then
    for pid in ${INOTIFY_PID}; do
      kill -0 "${pid}" 2>/dev/null || continue
      kill -STOP "${pid}" 2>/dev/null || return 0
    done
    while [ "${waited}" -lt 50 ]; do
      all_stopped=true
      for pid in ${INOTIFY_PID}; do
        kill -0 "${pid}" 2>/dev/null || continue
        state="$(awk '/^State:/ { print $2 }' "/proc/${pid}/status" 2>/dev/null || true)"
        [ "${state}" = "T" ] || all_stopped=false
      done
      [ "${all_stopped}" = "true" ] && break
      sleep 0.01
      waited=$((waited + 1))
    done
    if [ "${all_stopped}" != "true" ]; then
      for pid in ${INOTIFY_PID}; do
        kill -CONT "${pid}" 2>/dev/null || true
      done
      return 0
    fi
    watcher_stopped=true
  fi

  # Recount after the writer is stopped. Keep the same inode because the
  # watcher holds an append fd to it; replacing the file would orphan writes.
  total="$(wc -l <"${INOTIFY_EVENTS_FILE}" | tr -d ' ')"
  if [ "${INOTIFY_EVENTS_OFFSET}" -gt "${total}" ]; then
    INOTIFY_EVENTS_OFFSET="${total}"
  fi
  unread_file="${WORK_DIR}/inotify.unread"
  if [ "${total}" -gt "${INOTIFY_EVENTS_OFFSET}" ]; then
    start=$((INOTIFY_EVENTS_OFFSET + 1))
    tail -n +"${start}" "${INOTIFY_EVENTS_FILE}" >"${unread_file}" || compact_status=$?
  else
    : >"${unread_file}"
  fi
  if [ "${compact_status}" -eq 0 ]; then
    : >"${INOTIFY_EVENTS_FILE}" || compact_status=$?
  fi
  if [ "${compact_status}" -eq 0 ]; then
    cat "${unread_file}" >>"${INOTIFY_EVENTS_FILE}" || compact_status=$?
  fi
  rm -f "${unread_file}"
  if [ "${compact_status}" -eq 0 ]; then
    INOTIFY_EVENTS_OFFSET=0
  fi
  if [ "${watcher_stopped}" = "true" ]; then
    for pid in ${INOTIFY_PID}; do
      kill -CONT "${pid}" 2>/dev/null || true
    done
  fi
  return "${compact_status}"
}

unit_list_contains() {
  local units="$1" unit="$2"
  case " ${units} " in
    *" ${unit} "*) return 0 ;;
    *) return 1 ;;
  esac
}

unit_list_add() {
  local units="$1" unit="$2"
  if unit_list_contains "${units}" "${unit}"; then
    printf '%s' "${units}"
  else
    printf '%s %s' "${units}" "${unit}"
  fi
}

unit_list_remove() {
  local units="$1" unit="$2" result="" candidate
  for candidate in ${units}; do
    [ "${candidate}" = "${unit}" ] || result="${result} ${candidate}"
  done
  printf '%s' "${result}"
}

queue_push_unit() {
  local unit="$1" use_delete="$2"
  PENDING_PUSH_UNITS="$(unit_list_add "${PENDING_PUSH_UNITS}" "${unit}")"
  if [ "${use_delete}" = "true" ]; then
    PENDING_DELETE_UNITS="$(unit_list_add "${PENDING_DELETE_UNITS}" "${unit}")"
  fi
}

queue_all_units_for_push() {
  local name
  while IFS=$'\t' read -r name _; do
    [ -n "${name}" ] && queue_push_unit "${name}" false
  done <"${UNITS_FILE}"
}

attempt_pending_pushes() {
  local units="$1" is_retry="$2"
  local unit use_delete failed=false dropped_units=""
  LAST_PUSH_SUCCEEDED_UNITS=""
  for unit in ${units}; do
    unit_list_contains "${PENDING_PUSH_UNITS}" "${unit}" || continue
    use_delete=false
    if unit_list_contains "${PENDING_DELETE_UNITS}" "${unit}"; then
      use_delete=true
    fi
    if sync_units push "${unit}" "${use_delete}"; then
      PENDING_PUSH_UNITS="$(unit_list_remove "${PENDING_PUSH_UNITS}" "${unit}")"
      PENDING_DELETE_UNITS="$(unit_list_remove "${PENDING_DELETE_UNITS}" "${unit}")"
      LAST_PUSH_SUCCEEDED_UNITS="$(unit_list_add "${LAST_PUSH_SUCCEEDED_UNITS}" "${unit}")"
    else
      failed=true
      if [ "${is_retry}" = "true" ]; then
        PENDING_PUSH_UNITS="$(unit_list_remove "${PENDING_PUSH_UNITS}" "${unit}")"
        PENDING_DELETE_UNITS="$(unit_list_remove "${PENDING_DELETE_UNITS}" "${unit}")"
        dropped_units="$(unit_list_add "${dropped_units}" "${unit}")"
      fi
    fi
  done
  if [ -n "${dropped_units}" ]; then
    log "drop pending push after retry failure: units=${dropped_units# }"
  fi
  if [ "${failed}" = "true" ]; then
    PENDING_PUSH_RETRY_TICKS=0
    return 1
  fi
  PENDING_PUSH_RETRY_TICKS=0
  return 0
}

pull_units_after_successful_push() {
  local units="$1" unit pulled=false
  [ "$(config_field runtime_pull_enabled)" = "false" ] && return 0
  for unit in ${units}; do
    unit_list_contains "${PENDING_PUSH_UNITS}" "${unit}" && continue
    log "pull after successful push: unit=${unit}"
    sync_units pull "${unit}" "true" || true
    pulled=true
  done
  if [ "${pulled}" = "true" ]; then
    discard_inotify_events
  fi
}

run_inotify_push_once() {
  local debounce="$1"
  local events_batch_file unit_name push_delete_enabled event_delete use_delete received_events
  local units_to_push="" units_delete=""
  LAST_PUSH_HAD_EVENT=false
  LAST_PUSH_FAILED=false
  LAST_PUSH_DELETE_FAILED=false
  events_batch_file="${WORK_DIR}/inotify.batch"
  drain_inotify_events "${events_batch_file}"
  if [ ! -s "${events_batch_file}" ]; then
    if [ -n "${PENDING_PUSH_UNITS}" ]; then
      PENDING_PUSH_RETRY_TICKS=$((PENDING_PUSH_RETRY_TICKS + 1))
      if [ "${PENDING_PUSH_RETRY_TICKS}" -ge "${debounce}" ]; then
        log "retry pending push: units=${PENDING_PUSH_UNITS# }"
        attempt_pending_pushes "${PENDING_PUSH_UNITS}" true || true
        if [ -n "${LAST_PUSH_SUCCEEDED_UNITS}" ]; then
          pull_units_after_successful_push "${LAST_PUSH_SUCCEEDED_UNITS}"
        fi
      fi
    fi
    compact_inotify_events || true
    return 0
  fi
  LAST_PUSH_HAD_EVENT=true
  received_events="$(wc -l <"${events_batch_file}" | tr -d ' ')"
  [ "${debounce}" -gt 0 ] && sleep "${debounce}"

  while IFS=$'\t' read -r unit_name push_delete_enabled event_delete; do
    [ -n "${unit_name}" ] || continue
    case " ${units_to_push} " in
      *" ${unit_name} "*) ;;
      *) units_to_push="${units_to_push} ${unit_name}" ;;
    esac
    if [ "${push_delete_enabled}" = "true" ] && [ "${event_delete}" = "true" ]; then
      case " ${units_delete} " in
        *" ${unit_name} "*) ;;
        *) units_delete="${units_delete} ${unit_name}" ;;
      esac
    fi
  done < <(resolve_inotify_events "${events_batch_file}")

  if [ -n "${units_to_push}" ]; then
    log "inotify batch: received=${received_events} sync_units=${units_to_push# }"
  else
    log "inotify batch: received=${received_events} no_syncable_units"
  fi

  for unit_name in ${units_to_push}; do
    use_delete="false"
    case " ${units_delete} " in
      *" ${unit_name} "*) use_delete="true" ;;
    esac
    queue_push_unit "${unit_name}" "${use_delete}"
  done
  if ! attempt_pending_pushes "${units_to_push}" false; then
    LAST_PUSH_FAILED=true
    if [ -n "${PENDING_DELETE_UNITS}" ]; then
      LAST_PUSH_DELETE_FAILED=true
    fi
  fi
  if [ -n "${LAST_PUSH_SUCCEEDED_UNITS}" ]; then
    pull_units_after_successful_push "${LAST_PUSH_SUCCEEDED_UNITS}"
  fi
  compact_inotify_events || true
}

# runner_start_or_refresh launches the background run loop, replacing any live
# runner so post_hook is idempotent (no duplicate loops stack up).
runner_start_or_refresh() {
  local runner_mode="${1:-run}"
  if [ -f "${PIDFILE}" ]; then
    local old
    old="$(cat "${PIDFILE}" 2>/dev/null || true)"
    if [ -n "${old}" ] && kill -0 "${old}" 2>/dev/null; then
      kill "${old}" 2>/dev/null || true
    fi
  fi
  MCP_VM_PERSISTENT_SYNC_CONFIG_B64="${CONFIG_B64}" \
  PERSISTENT_SYNC_WORK_DIR="${WORK_DIR}" \
  PERSISTENT_SYNC_ALLOWED_HOME="${ALLOWED_HOME}" \
  PERSISTENT_SYNC_OWNER="${SYNC_OWNER}" \
  PERSISTENT_SYNC_PIDFILE="${PIDFILE}" \
  PERSISTENT_SYNC_MAX_TICKS="${MAX_TICKS}" \
    bash "${SELF}" "${runner_mode}" >>"${WORK_DIR}/runner.log" 2>&1 < /dev/null &
  local pid=$!
  mkdir -p "$(dirname "${PIDFILE}")" 2>/dev/null || true
  printf '%s' "${pid}" >"${PIDFILE}" 2>/dev/null || true
  log "runner started, pid=${pid}"
}

# do_restore runs one restore pass honoring startup_restore_enabled.
do_restore() {
  local start_ms units_count restore_status
  start_ms="$(now_ms)"
  load_units
  units_count="$(wc -l <"${UNITS_FILE}" | tr -d ' ')"
  if [ "$(config_field startup_restore_enabled)" = "false" ]; then
    log "startup_restore_enabled=false; skip restore"
    log "restore timing: status=skipped duration_ms=$(( $(now_ms) - start_ms )) units=${units_count}"
    emit_status skipped
    return 0
  fi
  if sync_units restore; then
    restore_status="success"
  else
    restore_status="partial_failed"
  fi
  log "restore timing: status=${restore_status} duration_ms=$(( $(now_ms) - start_ms )) units=${units_count}"
  emit_status success
}

# run_loop drives push from inotify events and keeps pull as a low-frequency
# compensation loop. Bounded by MAX_TICKS in tests.
run_loop() {
  load_units
  local push_enabled pull_enabled push_debounce pull_iv
  push_enabled="$(config_field runtime_push_enabled)"
  pull_enabled="$(config_field runtime_pull_enabled)"
  push_debounce="$(config_field runtime_push_debounce_seconds)"; push_debounce="${push_debounce:-2}"
  pull_iv="$(runtime_pull_interval)"
  if [ "${push_enabled}" != "false" ] && ! command -v inotifywait >/dev/null 2>&1; then
    fail_hard "inotifywait is required for runtime push"
  fi
  if [ "${push_enabled}" != "false" ]; then
    queue_all_units_for_push
    attempt_pending_pushes "${PENDING_PUSH_UNITS}" false || true
    start_inotify_watcher
  fi

  # Elapsed virtual time; tests use fake sleep/inotify and MAX_TICKS to bound.
  local elapsed=0 ticks=0
  local next_pull="${pull_iv}"
  while true; do
    elapsed=$((elapsed + 1))
    if [ "${push_enabled}" != "false" ]; then
      run_inotify_push_once "${push_debounce}"
    fi
    if [ "${pull_enabled}" != "false" ] && [ "${elapsed}" -ge "${next_pull}" ]; then
      if [ -n "${PENDING_PUSH_UNITS}" ]; then
        log "defer pull while push retry is pending: units=${PENDING_PUSH_UNITS# }"
      else
        sync_units pull "" "true" || true
        discard_inotify_events
      fi
      next_pull=$((next_pull + pull_iv))
    fi
    ticks=$((ticks + 1))
    if [ -n "${MAX_TICKS}" ] && [ "${ticks}" -ge "${MAX_TICKS}" ]; then
      break
    fi
    sleep 1
  done
  stop_inotify_watcher
}

case "${MODE}" in
  restore)
    do_restore
    ;;
  pull)
    do_restore
    ;;
  push)
    load_units
    if sync_units push "" "false"; then
      emit_status success
    else
      emit_status success
    fi
    ;;
  run)
    log "runtime runner disabled; skip continuous sync"
    emit_status skipped
    ;;
  async_restore_run)
    log "async_restore_run compatibility mode: restore once without runtime runner"
    do_restore
    ;;
  post_hook)
    log "post_hook compatibility mode: restore once without runtime runner"
    do_restore
    ;;
  *)
    echo "usage: $0 {restore|push|pull|run|async_restore_run|post_hook}" >&2
    emit_status failed
    exit 2
    ;;
esac
