#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/persistent_sync.sh"
ENTRYPOINT="${SCRIPT_DIR}/../entrypoint.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

# make_case creates an isolated sandbox dir and echoes its path.
make_case() {
  local root
  root="$(mktemp -d)"
  mkdir -p "${root}/bin" "${root}/persistent/home-config" "${root}/home/.config"
  # fake rsync records its full argument line and can emit deterministic
  # itemized changes for logging assertions.
  cat >"${root}/bin/rsync" <<'EOF'
#!/bin/bash
if [ -n "${PERSISTENT_SYNC_TEST_RSYNC_SLEEP_SECONDS:-}" ]; then
  /bin/sleep "${PERSISTENT_SYNC_TEST_RSYNC_SLEEP_SECONDS}"
fi
printf '%s\n' "$*" >>"${PERSISTENT_SYNC_TEST_LOG}"
if [ -n "${PERSISTENT_SYNC_TEST_FAIL_PUSH_SOURCE:-}" ]; then
  case "$*" in
    *"${PERSISTENT_SYNC_TEST_FAIL_PUSH_SOURCE}/"*) exit 23 ;;
  esac
fi
if [ -n "${PERSISTENT_SYNC_TEST_FAIL_PUSH_ATTEMPTS:-}" ]; then
  case "$*" in
    *"${PERSISTENT_SYNC_TEST_FAIL_PUSH_ATTEMPTS_SOURCE}/"*)
      attempts_file="${PERSISTENT_SYNC_WORK_DIR}/push-attempts"
      attempts=0
      [ -f "${attempts_file}" ] && attempts="$(cat "${attempts_file}")"
      attempts=$((attempts + 1))
      printf '%s' "${attempts}" >"${attempts_file}"
      if [ "${attempts}" -le "${PERSISTENT_SYNC_TEST_FAIL_PUSH_ATTEMPTS}" ]; then
        exit 23
      fi
      ;;
  esac
fi
if [ -n "${PERSISTENT_SYNC_TEST_EMIT_PULL_EVENT:-}" ]; then
  case "$*" in
    *"${PERSISTENT_SYNC_TEST_PULL_SOURCE}/"*"${PERSISTENT_SYNC_TEST_PULL_TARGET}/"*)
      printf '%s\n' "${PERSISTENT_SYNC_TEST_EMIT_PULL_EVENT}" >>"${PERSISTENT_SYNC_WORK_DIR}/inotify.events"
      ;;
  esac
fi
if [ -n "${PERSISTENT_SYNC_TEST_ITEMIZE_OUTPUT:-}" ]; then
  printf '%b\n' "${PERSISTENT_SYNC_TEST_ITEMIZE_OUTPUT}"
fi
EOF
  chmod +x "${root}/bin/rsync"
  cat >"${root}/bin/chown" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${PERSISTENT_SYNC_TEST_CHOWN_LOG}"
exit 0
EOF
  chmod +x "${root}/bin/chown"
  # fake sleep returns immediately so the run loop does not block tests.
  cat >"${root}/bin/sleep" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "0.1" ]; then
  /bin/sleep 0.01
fi
exit 0
EOF
  chmod +x "${root}/bin/sleep"
  # fake inotifywait emits one configured event batch and exits. Production
  # code must call inotifywait for runtime push; tests inspect this log.
  cat >"${root}/bin/inotifywait" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${PERSISTENT_SYNC_TEST_INOTIFY_LOG}"
previous=""
for argument in "$@"; do
  if [ "${previous}" = "--exclude" ]; then
    printf '%s\n' "${argument}" >>"${PERSISTENT_SYNC_TEST_INOTIFY_EXCLUDE_LOG}"
    previous=""
    continue
  fi
  previous="${argument}"
done
if [ -n "${PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT:-}" ]; then
  printf '%b\n' "${PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT}" >>"${PERSISTENT_SYNC_WORK_DIR}/inotify.events"
fi
printf '%s\n' "Watches established." >&2
exit "${PERSISTENT_SYNC_TEST_INOTIFY_RC:-0}"
EOF
  chmod +x "${root}/bin/inotifywait"
  printf '%s' "${root}"
}

# encode_config <remote_root> <local_root> [json-overrides-python]
# Builds a base64 config; extra python can mutate the `cfg` dict.
encode_config() {
  local remote="$1" local_root="$2" mutate="${3:-}"
  python3 - "${remote}" "${local_root}" "${mutate}" <<'PY'
import base64, json, sys
remote, local_root, mutate = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = {
    "enabled": True,
    "persistent_root": remote,
    "startup_restore_enabled": True,
    "runtime_push_enabled": True,
    "runtime_pull_enabled": True,
    "runtime_push_debounce_seconds": 0,
    "runtime_pull_interval_seconds": 10,
    "units": [{
        "name": "home-config",
        "local_path": local_root + "/.config",
        "remote_path": "home-config",
        "push_delete_enabled": True,
        "excludes": ["browser/", "*.log"],
    }],
    "global_excludes": ["**/*.tmp"],
}
if mutate:
    exec(mutate)
print(base64.b64encode(json.dumps(cfg).encode()).decode())
PY
}

# run_script <case_root> <config_b64> <mode> [extra env assignments...]
# Echoes combined stdout+stderr; writes exit code to <case_root>/rc so the
# caller can read it after the command substitution subshell returns.
run_script() {
  local root="$1" cfg="$2" mode="$3"; shift 3
  local out rc
  set +e
  out="$(env \
    PATH="${root}/bin:${PATH}" \
    PERSISTENT_SYNC_TEST_LOG="${root}/rsync.log" \
    PERSISTENT_SYNC_TEST_CHOWN_LOG="${root}/chown.log" \
    PERSISTENT_SYNC_TEST_INOTIFY_LOG="${root}/inotify.log" \
    PERSISTENT_SYNC_TEST_INOTIFY_EXCLUDE_LOG="${root}/inotify.exclude.log" \
    PERSISTENT_SYNC_WORK_DIR="${root}/work" \
    PERSISTENT_SYNC_ALLOWED_HOME="${root}/home" \
    PERSISTENT_SYNC_OWNER="$(id -u):$(id -g)" \
    PERSISTENT_SYNC_PIDFILE="${root}/runner.pid" \
    MCP_VM_PERSISTENT_SYNC_CONFIG_B64="${cfg}" \
    "$@" \
    bash "${SCRIPT}" "${mode}" 2>&1)"
  rc=$?
  set -e
  printf '%s' "${rc}" >"${root}/rc"
  printf '%s' "${out}"
}

# rc_of <case_root> -> echoes the last run_script exit code for that case.
rc_of() { cat "$1/rc" 2>/dev/null || echo 127; }

# ---------------------------------------------------------------------------
# Task 1: every exit path emits a __RUNTIME_INIT_STATUS__ marker.
# ---------------------------------------------------------------------------
test_absent_config_emits_skipped() {
  local root out
  root="$(make_case)"
  out="$(run_script "${root}" "" restore)"
  if echo "${out}" | grep -q '__RUNTIME_INIT_STATUS__=skipped'; then
    pass "absent config emits skipped marker"
  else
    fail "absent config emits skipped marker (got: ${out}, rc=$(rc_of "${root}"))"
  fi
  rm -rf "${root}"
}

test_restore_happy_emits_success() {
  local root cfg out
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home")"
  out="$(run_script "${root}" "${cfg}" restore)"
  if echo "${out}" | grep -q '__RUNTIME_INIT_STATUS__=success' && [ "$(rc_of "${root}")" -eq 0 ]; then
    pass "restore happy path emits success marker"
  else
    fail "restore happy path emits success marker (got: ${out}, rc=$(rc_of "${root}"))"
  fi
  if grep -q -- "--exclude-from=" "${root}/rsync.log" \
     && grep -q -- "${root}/persistent/home-config/" "${root}/rsync.log"; then
    pass "restore invokes rsync with exclude-from and remote source"
  else
    fail "restore rsync invocation ($(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  if grep -q -- "--delete" "${root}/rsync.log"; then
    fail "restore must not use --delete"
  else
    pass "restore does not use --delete"
  fi
  if echo "${out}" | grep -Eq '\[persistent-sync\] restore timing: status=success duration_ms=[0-9]+ units=1'; then
    pass "restore logs startup duration"
  else
    fail "restore logs startup duration (got: ${out})"
  fi
  rm -rf "${root}"
}

test_push_never_uses_delete_even_when_delete_enabled() {
  local root cfg out
  root="$(make_case)"
  mkdir -p "${root}/home/.config"
  printf 'token\n' >"${root}/home/.config/token"
  cfg="$(encode_config "${root}/persistent" "${root}/home" 'cfg["units"][0]["push_delete_enabled"]=True')"
  out="$(run_script "${root}" "${cfg}" push)"
  if echo "${out}" | grep -q '__RUNTIME_INIT_STATUS__=success' \
     && ! grep -q -- "--delete" "${root}/rsync.log" 2>/dev/null; then
    pass "push never uses --delete"
  else
    fail "push must not use --delete (out: ${out}; rsync: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_async_restore_run_restores_once_without_runtime_loop() {
  local root cfg out
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" 'cfg["runtime_push_enabled"]=True; cfg["runtime_pull_enabled"]=True')"
  out="$(run_script "${root}" "${cfg}" async_restore_run PERSISTENT_SYNC_MAX_TICKS=2)"
  if echo "${out}" | grep -q '__RUNTIME_INIT_STATUS__=success' \
     && grep -q -- "${root}/persistent/home-config/ ${root}/home/.config/" "${root}/rsync.log" 2>/dev/null \
     && ! grep -q "inotify watcher started" "${root}/persistent_sync.log" "${root}/work/persistent_sync.log" "${root}/work/runner.log" 2>/dev/null \
     && [ ! -s "${root}/inotify.log" ]; then
    pass "async_restore_run restores once without runtime loop"
  else
    fail "async_restore_run should restore once without runtime loop (out: ${out}; rsync: $(cat "${root}/rsync.log" 2>/dev/null); inotify: $(cat "${root}/inotify.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_restore_chowns_directory_root_non_recursively() {
  local root cfg out
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home")"
  out="$(run_script "${root}" "${cfg}" restore)"
  if [ "$(rc_of "${root}")" -eq 0 ] && echo "${out}" | grep -q '__RUNTIME_INIT_STATUS__=success'; then
    :
  else
    fail "restore for chown assertion should succeed (got: ${out}, rc=$(rc_of "${root}"))"
    rm -rf "${root}"
    return
  fi
  if grep -q -- '-R' "${root}/chown.log" 2>/dev/null; then
    fail "directory restore must not call recursive chown (chown: $(cat "${root}/chown.log"))"
  elif grep -qx -- "$(id -u):$(id -g) ${root}/home/.config" "${root}/chown.log" 2>/dev/null; then
    pass "directory restore chowns only unit root"
  else
    fail "directory restore should chown unit root non-recursively (chown: $(cat "${root}/chown.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_file_unit_restore_uses_file_paths() {
  local root cfg out
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" '
cfg["units"] = [{
  "name": "git-credentials",
  "local_path": local_root + "/.git-credentials",
  "remote_path": "git-credentials",
  "push_delete_enabled": True,
  "is_file": True,
}]
')"
  printf 'https://token@example.com\n' >"${root}/persistent/git-credentials"
  out="$(run_script "${root}" "${cfg}" restore)"
  if [ "$(rc_of "${root}")" -eq 0 ] && echo "${out}" | grep -q '__RUNTIME_INIT_STATUS__=success'; then
    pass "file unit restore emits success marker"
  else
    fail "file unit restore emits success marker (got: ${out}, rc=$(rc_of "${root}"))"
  fi
  if [ -d "${root}/home/.git-credentials" ]; then
    fail "file unit restore must not create local file path as directory"
  elif grep -q -- "${root}/persistent/git-credentials ${root}/home/.git-credentials" "${root}/rsync.log" 2>/dev/null; then
    pass "file unit restore uses file source and file destination"
  else
    fail "file unit restore rsync invocation (log: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_file_unit_restore_refuses_dirty_remote_directory() {
  local root cfg out
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" '
cfg["units"] = [{
  "name": "git-credentials",
  "local_path": local_root + "/.git-credentials",
  "remote_path": "git-credentials",
  "push_delete_enabled": True,
  "is_file": True,
}]
')"
  mkdir -p "${root}/persistent/git-credentials/.git-credentials/git-credentials"
  out="$(run_script "${root}" "${cfg}" restore)"
  if echo "${out}" | grep -q 'refuse: remote file path is not a regular file; skip unit git-credentials' \
     && echo "${out}" | grep -q '\[persistent-sync\] restore timing: status=partial_failed' \
     && ! grep -q -- "${root}/persistent/git-credentials ${root}/home/.git-credentials" "${root}/rsync.log" 2>/dev/null \
     && [ ! -d "${root}/home/.git-credentials" ]; then
    pass "file unit restore refuses dirty remote directory"
  else
    fail "file unit restore should refuse dirty remote directory (out: ${out}; rsync: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_file_unit_push_refuses_local_or_remote_directory() {
  local root cfg out
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" '
cfg["units"] = [{
  "name": "git-credentials",
  "local_path": local_root + "/.git-credentials",
  "remote_path": "git-credentials",
  "push_delete_enabled": True,
  "is_file": True,
}]
')"
  mkdir -p "${root}/home/.git-credentials"
  out="$(run_script "${root}" "${cfg}" push)"
  if echo "${out}" | grep -q 'refuse: local file path is not a regular file; skip unit git-credentials' \
     && ! grep -q -- "${root}/home/.git-credentials ${root}/persistent/git-credentials" "${root}/rsync.log" 2>/dev/null; then
    pass "file unit push refuses local directory"
  else
    fail "file unit push should refuse local directory (out: ${out}; rsync: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi

  rm -rf "${root}/home/.git-credentials" "${root}/persistent/git-credentials" "${root}/rsync.log"
  printf 'https://token@example.com\n' >"${root}/home/.git-credentials"
  mkdir -p "${root}/persistent/git-credentials"
  out="$(run_script "${root}" "${cfg}" push)"
  if echo "${out}" | grep -q 'refuse: remote file path is not a regular file; skip unit git-credentials' \
     && ! grep -q -- "${root}/home/.git-credentials ${root}/persistent/git-credentials" "${root}/rsync.log" 2>/dev/null; then
    pass "file unit push refuses dirty remote directory"
  else
    fail "file unit push should refuse dirty remote directory (out: ${out}; rsync: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_file_unit_write_event_pushes_file_path() {
  local root cfg event push_lines
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" '
cfg["units"] = [{
  "name": "git-credentials",
  "local_path": local_root + "/.git-credentials",
  "remote_path": "git-credentials",
  "push_delete_enabled": True,
  "is_file": True,
}]
')"
  printf 'https://token@example.com\n' >"${root}/home/.git-credentials"
  event="${root}/home/ CLOSE_WRITE .git-credentials"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=1 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${event}" >/dev/null
  push_lines="$(grep -- "${root}/home/.git-credentials ${root}/persistent/git-credentials" "${root}/rsync.log" 2>/dev/null || true)"
  if [ -n "${push_lines}" ]; then
    pass "file unit write event pushes file source and file destination"
  else
    fail "file unit write event should push file path (log: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  if grep -q -- "-r -m" "${root}/inotify.log" 2>/dev/null; then
    fail "file unit watcher must not recursively watch home parent (inotify: $(cat "${root}/inotify.log" 2>/dev/null))"
  else
    pass "file unit watcher uses non-recursive parent watch"
  fi
  rm -rf "${root}"
}

# ---------------------------------------------------------------------------
# Task 2: invalid config hard-fails (nonzero + failed marker), never silent 0.
# ---------------------------------------------------------------------------
test_invalid_config_symlink_root_fails() {
  local root cfg out
  root="$(make_case)"
  ln -s /etc "${root}/link_root"
  cfg="$(encode_config "${root}/link_root" "${root}/home" 'cfg["persistent_root"]=remote; cfg["units"]=[]')"
  out="$(run_script "${root}" "${cfg}" restore)"
  if [ "$(rc_of "${root}")" -ne 0 ] && echo "${out}" | grep -q '__RUNTIME_INIT_STATUS__=failed'; then
    pass "symlink persistent_root hard-fails with failed marker"
  else
    fail "symlink persistent_root hard-fails (got: ${out}, rc=$(rc_of "${root}"))"
  fi
  rm -rf "${root}"
}

test_invalid_config_bad_local_fails() {
  local root cfg out
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" 'cfg["units"][0]["local_path"]="/etc/evil"')"
  out="$(run_script "${root}" "${cfg}" restore)"
  if [ "$(rc_of "${root}")" -ne 0 ] && echo "${out}" | grep -q '__RUNTIME_INIT_STATUS__=failed'; then
    pass "out-of-allowlist local_path hard-fails"
  else
    fail "out-of-allowlist local_path hard-fails (got: ${out}, rc=$(rc_of "${root}"))"
  fi
  rm -rf "${root}"
}

test_credential_local_dirs_allowed() {
  local root cfg out
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" '
cfg["units"] = [
  {"name": "wecom-config", "local_path": local_root + "/.config/wecom", "remote_path": "wecom-config"},
  {"name": "dws-cli-data", "local_path": local_root + "/.local/share/dws-cli", "remote_path": "dws-cli-data"},
  {"name": "qcc-config", "local_path": local_root + "/.qcc", "remote_path": "qcc-config"},
  {"name": "pkulaw-config", "local_path": local_root + "/.pkulaw", "remote_path": "pkulaw-config"},
  {"name": "new-cli", "local_path": local_root + "/.new-cli/state", "remote_path": "new-cli"},
]
')"
  out="$(run_script "${root}" "${cfg}" restore)"
  if [ "$(rc_of "${root}")" -eq 0 ] && echo "${out}" | grep -q '__RUNTIME_INIT_STATUS__=success'; then
    pass "credential and arbitrary home child dirs are allowed"
  else
    fail "credential and arbitrary home child dirs are allowed (got: ${out}, rc=$(rc_of "${root}"))"
  fi
  rm -rf "${root}"
}

# ---------------------------------------------------------------------------
# Task 3: reject symlinks before any root write.
# ---------------------------------------------------------------------------
test_symlink_local_dir_rejected() {
  local root cfg out
  root="$(make_case)"
  # local_path itself is a symlink to an out-of-home target.
  rm -rf "${root}/home/.config"
  mkdir -p "${root}/escape"
  ln -s "${root}/escape" "${root}/home/.config"
  cfg="$(encode_config "${root}/persistent" "${root}/home")"
  out="$(run_script "${root}" "${cfg}" restore)"
  if grep -q "home-config" "${root}/rsync.log" 2>/dev/null; then
    fail "rsync ran on symlinked local_path (log: $(cat "${root}/rsync.log"))"
  else
    pass "symlinked local_path is not synced"
  fi
  if echo "${out}" | grep -qi "symlink"; then
    pass "symlink rejection is logged"
  else
    fail "symlink rejection is logged (got: ${out})"
  fi
  rm -rf "${root}"
}

# ---------------------------------------------------------------------------
# Task 4: run mode uses inotify-driven push and per-unit delete semantics.
# ---------------------------------------------------------------------------
test_run_uses_inotify_delete_event_with_delete_enabled() {
  local root cfg event
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home")"
  event="${root}/home/.config/ DELETE token.json"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=1 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${event}" >/dev/null
  if grep -q -- "-r" "${root}/inotify.log" 2>/dev/null \
     && grep -q -- "--delete" "${root}/rsync.log" 2>/dev/null \
     && grep -q -- "${root}/home/.config/ ${root}/persistent/home-config/" "${root}/rsync.log" 2>/dev/null; then
    pass "delete event on delete-enabled unit triggers inotify push with --delete"
  else
    fail "delete event push with --delete (inotify: $(cat "${root}/inotify.log" 2>/dev/null); rsync: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_run_write_event_pushes_without_delete() {
  local root cfg event push_lines
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home")"
  event="${root}/home/.config/ CLOSE_WRITE token.json"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=1 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${event}" >/dev/null
  push_lines="$(grep -- "${root}/home/.config/ ${root}/persistent/home-config/" "${root}/rsync.log" 2>/dev/null || true)"
  if [ -n "${push_lines}" ] && ! echo "${push_lines}" | grep -q -- "--delete"; then
    pass "write event triggers push without --delete"
  else
    fail "write event push without --delete (rsync: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_run_nested_unit_event_pushes_child_unit() {
  local root cfg event wecom_push_count home_push_count dws_cli_push_count home_local_push_count rsync_log
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" '
cfg["units"] = [
  {
    "name": "home-config",
    "local_path": local_root + "/.config",
    "remote_path": "home-config",
    "push_delete_enabled": True,
    "excludes": ["wecom/"],
  },
  {
    "name": "wecom-config",
    "local_path": local_root + "/.config/wecom",
    "remote_path": "wecom-config",
    "push_delete_enabled": True,
    "excludes": [],
  },
  {
    "name": "home-local",
    "local_path": local_root + "/.local",
    "remote_path": "home-local",
    "push_delete_enabled": True,
    "excludes": ["share/dws-cli/"],
  },
  {
    "name": "dws-cli-data",
    "local_path": local_root + "/.local/share/dws-cli",
    "remote_path": "dws-cli-data",
    "push_delete_enabled": True,
    "excludes": [],
  },
]
')"
  event="${root}/home/.config/wecom/ CLOSE_WRITE token.json\n${root}/home/.local/share/dws-cli/ CLOSE_WRITE auth.enc"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=1 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${event}" >/dev/null
  wecom_push_count="$(grep -c -- "${root}/home/.config/wecom/ ${root}/persistent/wecom-config/" "${root}/rsync.log" 2>/dev/null || true)"
  home_push_count="$(grep -c -- "${root}/home/.config/ ${root}/persistent/home-config/" "${root}/rsync.log" 2>/dev/null || true)"
  dws_cli_push_count="$(grep -c -- "${root}/home/.local/share/dws-cli/ ${root}/persistent/dws-cli-data/" "${root}/rsync.log" 2>/dev/null || true)"
  home_local_push_count="$(grep -c -- "${root}/home/.local/ ${root}/persistent/home-local/" "${root}/rsync.log" 2>/dev/null || true)"
  if [ "${wecom_push_count}" -eq 2 ] && [ "${home_push_count}" -eq 1 ] \
     && [ "${dws_cli_push_count}" -eq 2 ] && [ "${home_local_push_count}" -eq 1 ]; then
    pass "nested credential events push child units, not excluded parent units"
  else
    rsync_log="$(cat "${root}/rsync.log" 2>/dev/null || true)"
    fail "nested credential events should resolve to child units: wecom=${wecom_push_count}, home=${home_push_count}, dws_cli=${dws_cli_push_count}, home_local=${home_local_push_count}; log: ${rsync_log}"
  fi
  rm -rf "${root}"
}

test_run_logs_resolved_credential_unit_without_event_path() {
  local root cfg event out
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" '
cfg["units"].append({
  "name": "dws-config",
  "local_path": local_root + "/.dws",
  "remote_path": "dws-config",
  "push_delete_enabled": True,
  "excludes": [],
})
')"
  event="${root}/home/.dws/audit/ CLOSE_WRITE credential.json"
  out="$(run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=1 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${event}")"
  if echo "${out}" | grep -q '\[persistent-sync\] inotify batch: received=1 sync_units=dws-config' \
     && ! echo "${out}" | grep -q 'credential.json'; then
    pass "credential event diagnostics identify the owning unit without file paths"
  else
    fail "credential event diagnostics should identify dws-config without file paths (got: ${out})"
  fi
  rm -rf "${root}"
}

test_watcher_uses_only_safe_native_excludes() {
  local root cfg regex
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" '
cfg["global_excludes"] = ["**/*.lock", "**/*.log"]
cfg["units"] = [
  {
    "name": "home-config",
    "local_path": local_root + "/.config",
    "remote_path": "home-config",
    "push_delete_enabled": True,
    "excludes": ["wecom/", "browser/"],
  },
  {
    "name": "home-local",
    "local_path": local_root + "/.local",
    "remote_path": "home-local",
    "push_delete_enabled": True,
    "excludes": ["share/dws-cli/", "share/code-server/"],
  },
  {
    "name": "wecom-config",
    "local_path": local_root + "/.config/wecom",
    "remote_path": "wecom-config",
    "push_delete_enabled": True,
    "excludes": [],
  },
  {
    "name": "dws-cli-data",
    "local_path": local_root + "/.local/share/dws-cli",
    "remote_path": "dws-cli-data",
    "push_delete_enabled": True,
    "excludes": [],
  },
]
')"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=1 >/dev/null
  regex="$(cat "${root}/inotify.exclude.log" 2>/dev/null || true)"
  if echo "${regex}" | grep -q "browser" \
     && echo "${regex}" | grep -q "code-server" \
     && echo "${regex}" | grep -q "lock" \
     && echo "${regex}" | grep -q "log" \
     && ! echo "${regex}" | grep -q "wecom" \
     && ! echo "${regex}" | grep -q "dws-cli"; then
    pass "watcher native exclude contains only safe non-child patterns"
  else
    fail "watcher native exclude should include browser/code-server/lock/log but not child units (got: ${regex})"
  fi
  rm -rf "${root}"
}

test_run_ignores_event_below_excluded_directory() {
  local root cfg event push_count
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" 'cfg["units"][0]["excludes"]=["browser/"]')"
  event="${root}/home/.config/browser/ DELETE BrowserMetrics.pma"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=1 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${event}" >/dev/null
  push_count="$(grep -c -- "${root}/home/.config/ ${root}/persistent/home-config/" "${root}/rsync.log" 2>/dev/null || true)"
  if [ "${push_count}" -eq 1 ] && ! grep -q -- "--delete" "${root}/rsync.log" 2>/dev/null; then
    pass "events below excluded directories do not trigger parent unit pushes"
  else
    fail "excluded directory event should be ignored (push_count=${push_count}; rsync: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_run_delete_event_without_delete_enabled_pushes_without_delete() {
  local root cfg event
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" 'cfg["units"][0]["push_delete_enabled"]=False')"
  event="${root}/home/.config/ DELETE token.json"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=1 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${event}" >/dev/null
  if grep -q -- "${root}/home/.config/ ${root}/persistent/home-config/" "${root}/rsync.log" 2>/dev/null \
     && ! grep -q -- "--delete" "${root}/rsync.log" 2>/dev/null; then
    pass "delete event on delete-disabled unit pushes without --delete"
  else
    fail "delete-disabled push without --delete (rsync: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_run_keeps_single_watcher_across_idle_ticks() {
  local root cfg watch_count
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home")"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=3 >/dev/null
  watch_count="$(wc -l <"${root}/inotify.log" 2>/dev/null || echo 0)"
  if [ "${watch_count}" -eq 1 ]; then
    pass "run mode keeps one continuous inotify watcher across idle ticks"
  else
    fail "run mode should keep one continuous watcher, got ${watch_count} invocations ($(cat "${root}/inotify.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_run_does_not_replay_drained_events() {
  local root cfg event push_count
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home")"
  event="${root}/home/.config/ CLOSE_WRITE token.json"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=3 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${event}" \
    PERSISTENT_SYNC_INOTIFY_COMPACT_MIN_LINES=1000 >/dev/null
  push_count="$(grep -c -- "${root}/home/.config/ ${root}/persistent/home-config/" "${root}/rsync.log" 2>/dev/null || true)"
  if [ "${push_count}" -eq 2 ]; then
    pass "drained inotify events are not replayed on later ticks"
  else
    fail "one event should cause exactly one event push after initial push, got ${push_count}"
  fi
  rm -rf "${root}"
}

test_run_compacts_consumed_inotify_queue() {
  local root cfg event remaining
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home")"
  event="${root}/home/.config/ CLOSE_WRITE token.json"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=1 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${event}" \
    PERSISTENT_SYNC_INOTIFY_COMPACT_MIN_LINES=1 >/dev/null
  remaining="$(wc -l <"${root}/work/inotify.events" 2>/dev/null | tr -d ' ' || echo 0)"
  if [ "${remaining}" -eq 0 ]; then
    pass "consumed inotify queue is compacted at configured threshold"
  else
    fail "consumed inotify queue should be empty after compaction, got ${remaining} lines"
  fi
  rm -rf "${root}"
}

test_run_clamps_short_pull_interval_to_default_10s() {
  local root cfg
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" 'cfg["runtime_pull_interval_seconds"]=1')"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=9 >/dev/null
  if grep -q -- "${root}/persistent/home-config/ ${root}/home/.config/" "${root}/rsync.log" 2>/dev/null; then
    fail "pull interval below 10s should not run pull before tick 10 (log: $(cat "${root}/rsync.log" 2>/dev/null))"
  else
    pass "pull interval below 10s is clamped before tick 10"
  fi
  rm -rf "${root}"

  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" 'cfg["runtime_pull_interval_seconds"]=1')"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=10 >/dev/null
  if grep -q -- "${root}/persistent/home-config/ ${root}/home/.config/" "${root}/rsync.log" 2>/dev/null; then
    pass "clamped 10s pull runs at tick 10"
  else
    fail "clamped 10s pull should run at tick 10 (log: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_run_pushes_before_due_pull() {
  local root cfg event first_push_line first_pull_line
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" 'cfg["runtime_pull_interval_seconds"]=1')"
  event="${root}/home/.config/ CLOSE_WRITE token.json"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=10 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${event}" >/dev/null
  first_push_line="$(grep -n -- "${root}/home/.config/ ${root}/persistent/home-config/" "${root}/rsync.log" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
  first_pull_line="$(grep -n -- "${root}/persistent/home-config/ ${root}/home/.config/" "${root}/rsync.log" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
  if [ -n "${first_push_line}" ] && [ -n "${first_pull_line}" ] && [ "${first_push_line}" -lt "${first_pull_line}" ]; then
    pass "due pull runs only after pending push completes"
  else
    fail "due pull waits for push first (log: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_run_pulls_same_unit_after_successful_event_push() {
  local root cfg event first_event_push_line immediate_pull_line scheduled_pull_line
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" 'cfg["runtime_pull_interval_seconds"]=10')"
  event="${root}/home/.config/ CLOSE_WRITE token.json"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=3 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${event}" >/dev/null
  first_event_push_line="$(grep -n -- "${root}/home/.config/ ${root}/persistent/home-config/" "${root}/rsync.log" 2>/dev/null | sed -n '2p' | cut -d: -f1 || true)"
  immediate_pull_line="$(grep -n -- "${root}/persistent/home-config/ ${root}/home/.config/" "${root}/rsync.log" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
  scheduled_pull_line="$(grep -n -- "${root}/persistent/home-config/ ${root}/home/.config/" "${root}/rsync.log" 2>/dev/null | sed -n '2p' | cut -d: -f1 || true)"
  if [ -n "${first_event_push_line}" ] && [ -n "${immediate_pull_line}" ] \
     && [ "${first_event_push_line}" -lt "${immediate_pull_line}" ] \
     && [ -z "${scheduled_pull_line}" ]; then
    pass "successful event push immediately pulls the same unit"
  else
    fail "successful event push should immediately pull same unit before scheduled pull (push=${first_event_push_line}, immediate_pull=${immediate_pull_line}, scheduled_pull=${scheduled_pull_line}; log: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_run_does_not_immediately_pull_after_failed_event_push() {
  local root cfg event pull_count
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" 'cfg["runtime_pull_interval_seconds"]=10')"
  event="${root}/home/.config/ CLOSE_WRITE token.json"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=3 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${event}" \
    PERSISTENT_SYNC_TEST_FAIL_PUSH_SOURCE="${root}/home/.config" >/dev/null
  pull_count="$(grep -c -- "${root}/persistent/home-config/ ${root}/home/.config/" "${root}/rsync.log" 2>/dev/null || true)"
  if [ "${pull_count}" -eq 0 ]; then
    pass "failed event push does not trigger immediate pull"
  else
    fail "failed event push should not immediately pull (pull_count=${pull_count}; log: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_run_pulls_same_unit_after_successful_retry_push() {
  local root cfg event pull_count
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" '
cfg["runtime_pull_interval_seconds"] = 10
cfg["runtime_push_debounce_seconds"] = 2
')"
  event="${root}/home/.config/ CLOSE_WRITE token.json"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=5 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${event}" \
    PERSISTENT_SYNC_TEST_FAIL_PUSH_ATTEMPTS=2 \
    PERSISTENT_SYNC_TEST_FAIL_PUSH_ATTEMPTS_SOURCE="${root}/home/.config" >/dev/null
  pull_count="$(grep -c -- "${root}/persistent/home-config/ ${root}/home/.config/" "${root}/rsync.log" 2>/dev/null || true)"
  if [ "${pull_count}" -eq 1 ]; then
    pass "successful retry push immediately pulls the same unit"
  else
    fail "successful retry push should immediately pull same unit (pull_count=${pull_count}; log: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_rsync_change_logs_include_direction_unit_and_files() {
  local root cfg out
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home")"
  out="$(run_script "${root}" "${cfg}" push \
    PERSISTENT_SYNC_TEST_ITEMIZE_OUTPUT='>f+++++++++ token.json\n*deleting stale.json')"
  if echo "${out}" | grep -q '\[persistent-sync\] push changed files: unit=home-config files=\["token.json","stale.json"\]'; then
    pass "push logs changed files from rsync itemized output"
  else
    fail "push should log changed files (out: ${out})"
  fi
  out="$(run_script "${root}" "${cfg}" pull \
    PERSISTENT_SYNC_TEST_ITEMIZE_OUTPUT='>f+++++++++ pulled.json')"
  if echo "${out}" | grep -q '\[persistent-sync\] restore changed files: unit=home-config files=\["pulled.json"\]'; then
    pass "pull compatibility mode logs restore changed files from rsync itemized output"
  else
    fail "pull compatibility mode should log restore changed files (out: ${out})"
  fi
  rm -rf "${root}"
}

test_rsync_observability_logs_paths_flags_status_and_duration() {
  local root cfg out
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" '
cfg["units"] = [{
  "name": "git-credentials",
  "local_path": local_root + "/.git-credentials",
  "remote_path": "git-credentials",
  "push_delete_enabled": True,
  "is_file": True,
}]
')"
  printf 'https://token@example.com\n' >"${root}/home/.git-credentials"
  out="$(run_script "${root}" "${cfg}" push \
    PERSISTENT_SYNC_TEST_ITEMIZE_OUTPUT='>f+++++++++ .git-credentials')"
  if echo "${out}" | grep -Eq "\\[persistent-sync\\] sync start: direction=push unit=git-credentials is_file=true use_delete=false push_delete_enabled=true local=${root}/home/\\.git-credentials remote=${root}/persistent/git-credentials"; then
    pass "sync start log includes paths and flags"
  else
    fail "sync start log should include paths and flags (out: ${out})"
  fi
  if echo "${out}" | grep -Eq '\[persistent-sync\] sync finish: direction=push unit=git-credentials status=success duration_ms=[0-9]+ is_file=true use_delete=false'; then
    pass "sync finish log includes status and duration"
  else
    fail "sync finish log should include status and duration (out: ${out})"
  fi
  rm -rf "${root}"
}

test_run_defers_due_pull_when_delete_push_fails() {
  local root cfg event
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" 'cfg["runtime_pull_interval_seconds"]=1')"
  event="${root}/home/.config/ DELETE token.json"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=2 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${event}" \
    PERSISTENT_SYNC_TEST_FAIL_PUSH_SOURCE="${root}/home/.config" >/dev/null
  if grep -q -- "${root}/home/.config/ ${root}/persistent/home-config/" "${root}/rsync.log" 2>/dev/null \
     && ! grep -q -- "${root}/persistent/home-config/ ${root}/home/.config/" "${root}/rsync.log" 2>/dev/null; then
    pass "delete push failure defers pull until retry"
  else
    fail "delete push failure should defer pull until retry (log: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_run_retries_write_push_and_blocks_pull_until_success() {
  local root cfg event push_count pull_count final_push_line first_pull_line
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" '
cfg["runtime_pull_interval_seconds"] = 1
cfg["runtime_push_debounce_seconds"] = 2
')"
  event="${root}/home/.config/ CLOSE_WRITE token.json"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=10 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${event}" \
    PERSISTENT_SYNC_TEST_FAIL_PUSH_ATTEMPTS=2 \
    PERSISTENT_SYNC_TEST_FAIL_PUSH_ATTEMPTS_SOURCE="${root}/home/.config" >/dev/null
  push_count="$(grep -c -- "${root}/home/.config/ ${root}/persistent/home-config/" "${root}/rsync.log" 2>/dev/null || true)"
  pull_count="$(grep -c -- "${root}/persistent/home-config/ ${root}/home/.config/" "${root}/rsync.log" 2>/dev/null || true)"
  final_push_line="$(grep -n -- "${root}/home/.config/ ${root}/persistent/home-config/" "${root}/rsync.log" 2>/dev/null | sed -n '3p' | cut -d: -f1 || true)"
  first_pull_line="$(grep -n -- "${root}/persistent/home-config/ ${root}/home/.config/" "${root}/rsync.log" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
  if [ "${push_count}" -ge 3 ] && [ "${pull_count}" -ge 1 ] \
     && [ -n "${final_push_line}" ] && [ -n "${first_pull_line}" ] \
     && [ "${final_push_line}" -lt "${first_pull_line}" ]; then
    pass "write push retries and only then allows pull"
  else
    fail "write push should retry and block pull until success (pushes=${push_count}, pulls=${pull_count}, final_push=${final_push_line}, first_pull=${first_pull_line}; log: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_run_drops_pending_push_after_one_retry_failure() {
  local root cfg event push_count pull_count out
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" '
cfg["runtime_pull_interval_seconds"] = 1
cfg["runtime_push_debounce_seconds"] = 2
')"
  event="${root}/home/.config/ CLOSE_WRITE token.json"
  out="$(run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=10 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${event}" \
    PERSISTENT_SYNC_TEST_FAIL_PUSH_ATTEMPTS=99 \
    PERSISTENT_SYNC_TEST_FAIL_PUSH_ATTEMPTS_SOURCE="${root}/home/.config")"
  push_count="$(grep -c -- "${root}/home/.config/ ${root}/persistent/home-config/" "${root}/rsync.log" 2>/dev/null || true)"
  pull_count="$(grep -c -- "${root}/persistent/home-config/ ${root}/home/.config/" "${root}/rsync.log" 2>/dev/null || true)"
  if [ "${push_count}" -eq 3 ] && [ "${pull_count}" -eq 1 ] \
     && echo "${out}" | grep -q 'drop pending push after retry failure: units=home-config'; then
    pass "failed push retries once then unblocks pull"
  else
    fail "failed push should retry once then unblock pull (pushes=${push_count}, pulls=${pull_count}; out: ${out}; log: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_run_pull_uses_delete_when_delete_enabled() {
  local root cfg
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" 'cfg["runtime_pull_interval_seconds"]=1')"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=10 >/dev/null
  if grep -q -- "--delete" "${root}/rsync.log" 2>/dev/null \
     && grep -q -- "${root}/persistent/home-config/ ${root}/home/.config/" "${root}/rsync.log" 2>/dev/null; then
    pass "pull on delete-enabled unit uses --delete"
  else
    fail "pull on delete-enabled unit should use --delete (log: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_run_pull_events_do_not_trigger_push() {
  local root cfg push_count
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" 'cfg["runtime_pull_interval_seconds"]=1')"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=11 \
    PERSISTENT_SYNC_TEST_PULL_SOURCE="${root}/persistent/home-config" \
    PERSISTENT_SYNC_TEST_PULL_TARGET="${root}/home/.config" \
    PERSISTENT_SYNC_TEST_EMIT_PULL_EVENT="${root}/home/.config/ CREATE pulled-from-remote.txt" >/dev/null
  push_count="$(grep -c -- "${root}/home/.config/ ${root}/persistent/home-config/" "${root}/rsync.log" 2>/dev/null || true)"
  if [ "${push_count}" = "1" ]; then
    pass "pull-generated local events do not trigger reverse push"
  else
    fail "pull-generated event triggered reverse push, push_count=${push_count} (log: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_run_push_disabled() {
  local root cfg
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" \
    'cfg["runtime_push_enabled"]=False; cfg["runtime_pull_interval_seconds"]=1')"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=1 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="${root}/home/.config/ CLOSE_WRITE token.json" >/dev/null
  if grep -q -- "${root}/home/.config/ ${root}/persistent/home-config/" "${root}/rsync.log" 2>/dev/null; then
    fail "push ran while runtime_push_enabled=false"
  else
    pass "runtime_push_enabled=false disables push"
  fi
  rm -rf "${root}"
}

test_run_pull_disabled() {
  local root cfg
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" \
    'cfg["runtime_pull_enabled"]=False; cfg["runtime_pull_interval_seconds"]=1')"
  run_script "${root}" "${cfg}" run PERSISTENT_SYNC_MAX_TICKS=10 \
    PERSISTENT_SYNC_TEST_INOTIFY_OUTPUT="" >/dev/null
  if grep -q -- "${root}/persistent/home-config/ ${root}/home/.config/" "${root}/rsync.log" 2>/dev/null; then
    fail "pull ran while runtime_pull_enabled=false"
  else
    pass "runtime_pull_enabled=false disables pull"
  fi
  rm -rf "${root}"
}

test_startup_restore_disabled_skips() {
  local root cfg out
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" 'cfg["startup_restore_enabled"]=False')"
  out="$(run_script "${root}" "${cfg}" restore)"
  if grep -q "home-config" "${root}/rsync.log" 2>/dev/null; then
    fail "restore ran while startup_restore_enabled=false"
  else
    pass "startup_restore_enabled=false skips restore"
  fi
  if echo "${out}" | grep -q '__RUNTIME_INIT_STATUS__=skipped'; then
    pass "disabled restore still emits skipped marker"
  else
    fail "disabled restore emits skipped marker (got: ${out})"
  fi
  if echo "${out}" | grep -Eq '\[persistent-sync\] restore timing: status=skipped duration_ms=[0-9]+ units=1'; then
    pass "skipped restore logs startup duration"
  else
    fail "skipped restore logs startup duration (got: ${out})"
  fi
  rm -rf "${root}"
}

# ---------------------------------------------------------------------------
# Task 5 support: post_hook restores once without a background runner.
# ---------------------------------------------------------------------------
test_post_hook_restores_once_without_runner() {
  local root cfg out
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home" \
    'cfg["runtime_pull_interval_seconds"]=2')"
  out="$(run_script "${root}" "${cfg}" post_hook PERSISTENT_SYNC_MAX_TICKS=2)"
  if echo "${out}" | grep -q '__RUNTIME_INIT_STATUS__=success'; then
    pass "post_hook emits success marker"
  else
    fail "post_hook emits success marker (got: ${out})"
  fi
  if [ -f "${root}/runner.pid" ]; then
    fail "post_hook must not write runner pidfile"
  else
    pass "post_hook does not write runner pidfile"
  fi
  if grep -q -- "${root}/persistent/home-config/ ${root}/home/.config/" "${root}/rsync.log" 2>/dev/null; then
    pass "post_hook performs restore"
  else
    fail "post_hook performs restore (log: $(cat "${root}/rsync.log" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_post_hook_waits_for_slow_restore() {
  local root cfg out start elapsed
  root="$(make_case)"
  cfg="$(encode_config "${root}/persistent" "${root}/home")"
  start="$(date +%s)"
  out="$(run_script "${root}" "${cfg}" post_hook \
    PERSISTENT_SYNC_TEST_RSYNC_SLEEP_SECONDS=2)"
  elapsed=$(( $(date +%s) - start ))
  if echo "${out}" | grep -q '__RUNTIME_INIT_STATUS__=success' \
     && [ "${elapsed}" -ge 1 ] \
     && [ ! -f "${root}/runner.pid" ]; then
    pass "post_hook waits for one-shot restore"
  else
    fail "post_hook should wait for restore and avoid runner (out: ${out}; elapsed=${elapsed}; pidfile: $(cat "${root}/runner.pid" 2>/dev/null))"
  fi
  rm -rf "${root}"
}

test_entrypoint_submits_restore_without_async_runner() {
  local function_body
  function_body="$(awk '
    /^start_persistent_sync\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}/ { exit }
  ' "${ENTRYPOINT}")"
  if echo "${function_body}" | grep -q 'persistent_sync.sh" async_restore_run'; then
    fail "entrypoint must not submit async_restore_run"
  elif echo "${function_body}" | grep -q 'persistent_sync.sh" restore'; then
    pass "entrypoint submits one-shot restore"
  else
    fail "entrypoint should call persistent_sync.sh restore (body: ${function_body})"
  fi
}

test_absent_config_emits_skipped
test_restore_happy_emits_success
test_push_never_uses_delete_even_when_delete_enabled
test_async_restore_run_restores_once_without_runtime_loop
test_restore_chowns_directory_root_non_recursively
test_file_unit_restore_uses_file_paths
test_file_unit_restore_refuses_dirty_remote_directory
test_file_unit_push_refuses_local_or_remote_directory
test_invalid_config_symlink_root_fails
test_invalid_config_bad_local_fails
test_credential_local_dirs_allowed
test_symlink_local_dir_rejected
test_rsync_change_logs_include_direction_unit_and_files
test_rsync_observability_logs_paths_flags_status_and_duration
test_startup_restore_disabled_skips
test_post_hook_restores_once_without_runner
test_post_hook_waits_for_slow_restore
test_entrypoint_submits_restore_without_async_runner

printf '\n== persistent_sync tests: %d passed, %d failed ==\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
