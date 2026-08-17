#!/bin/bash

set -euo pipefail

RUNTIME_INIT_STATUS_MARKER="__RUNTIME_INIT_STATUS__="
RUNTIME_INIT_MESSAGE_MARKER="__RUNTIME_INIT_MESSAGE__="
RUNTIME_INIT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_INIT_ROOT_DIR="$(cd "${RUNTIME_INIT_SCRIPT_DIR}/.." && pwd)"
RUNTIME_INIT_USER_HOME="/home/user"
RUNTIME_INIT_RUNTIME_PATH="${RUNTIME_INIT_ROOT_DIR}"
RUNTIME_INIT_LEGACY_WORKSPACE="/home/user/.super_doubao/super-doubao-runtime/workspace"
RUNTIME_INIT_WORKSPACE="${MCP_VM_WORKDIR:-/home/user/.super_doubao/super-doubao-runtime/workspace}"
RUNTIME_INIT_WORKSPACE_ROOT="${MCP_VM_WORKSPACE_ROOT:-/sandboxdata/workspace}"
RUNTIME_INIT_WORKSPACE_TARGET="${MCP_VM_WORKSPACE_TARGET:-${RUNTIME_INIT_WORKSPACE_ROOT}/file}"
RUNTIME_INIT_DOWNLOADS_PATH="${MCP_VM_DOWNLOADS_PATH:-${RUNTIME_INIT_WORKSPACE}/Downloads}"
RUNTIME_INIT_AGENT_MODE_DIR="${RUNTIME_INIT_USER_HOME}/.doubao/agent_mode"
RUNTIME_INIT_AGENT_MODE_WORKSPACE="${RUNTIME_INIT_AGENT_MODE_DIR}/workspace"
RUNTIME_INIT_WORKSPACE_CONFIG_DIR="/run/mcp_vm_server"
RUNTIME_INIT_WORKSPACE_CONFIG_PATH="${RUNTIME_INIT_WORKSPACE_CONFIG_DIR}/workspace_config.json"
RUNTIME_INIT_BROWSER_CONFIG_DIR="${RUNTIME_INIT_USER_HOME}/.config/browser"
RUNTIME_INIT_BROWSER_DEFAULT_DIR="${RUNTIME_INIT_BROWSER_CONFIG_DIR}/Default"
RUNTIME_INIT_COOKIE_ROOT="${RUNTIME_INIT_BROWSER_DEFAULT_DIR}/customCookie"

runtime_init_log() {
  echo "[runtime_init][$(basename "$0")] $*"
}

runtime_init_now_ms() {
  date +%s%3N
}

runtime_init_log_duration_ms() {
  local stage_name="$1"
  local start_ms="$2"
  local end_ms
  end_ms="$(runtime_init_now_ms)"
  runtime_init_log "timing, stage=${stage_name}, duration_ms=$((end_ms - start_ms))"
}

runtime_init_emit_status() {
  local status="$1"
  local message="${2:-}"
  echo "${RUNTIME_INIT_STATUS_MARKER}${status}"
  if [ -n "${message}" ]; then
    echo "${RUNTIME_INIT_MESSAGE_MARKER}${message}"
  fi
}

runtime_init_success() {
  runtime_init_emit_status "success" "${1:-}"
  exit 0
}

runtime_init_skipped() {
  runtime_init_emit_status "skipped" "${1:-}"
  exit 0
}

runtime_init_failed() {
  runtime_init_emit_status "failed" "${1:-}" >&2
  exit 1
}

runtime_init_replace_symlink() {
  local target_path="$1"
  local link_path="$2"
  local parent_dir
  local stage_start_ms
  parent_dir="$(dirname "${link_path}")"

  runtime_init_log "ensure symlink, link=${link_path}, target=${target_path}"
  stage_start_ms="$(runtime_init_now_ms)"
  mkdir -p "${parent_dir}"
  runtime_init_log_duration_ms "replace_symlink_prepare_parent" "${stage_start_ms}"

  if [ -L "${link_path}" ]; then
    stage_start_ms="$(runtime_init_now_ms)"
    if [ "$(readlink "${link_path}")" = "${target_path}" ]; then
      runtime_init_log_duration_ms "replace_symlink_readlink" "${stage_start_ms}"
      runtime_init_log "symlink already points to target: ${link_path}"
      return 0
    fi
    runtime_init_log_duration_ms "replace_symlink_readlink" "${stage_start_ms}"
    runtime_init_log "replace existing symlink: ${link_path}"
    stage_start_ms="$(runtime_init_now_ms)"
    ln -sfnT "${target_path}" "${link_path}"
    runtime_init_log_duration_ms "replace_symlink_replace_existing" "${stage_start_ms}"
    return 0
  fi

  if [ -e "${link_path}" ]; then
    stage_start_ms="$(runtime_init_now_ms)"
    if [ -d "${link_path}" ] && [ -z "$(find "${link_path}" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
      runtime_init_log_duration_ms "replace_symlink_check_existing_path" "${stage_start_ms}"
      stage_start_ms="$(runtime_init_now_ms)"
      rmdir "${link_path}"
      runtime_init_log_duration_ms "replace_symlink_remove_empty_dir" "${stage_start_ms}"
    else
      runtime_init_log_duration_ms "replace_symlink_check_existing_path" "${stage_start_ms}"
      runtime_init_log "refuse to replace non-empty path: ${link_path}"
      return 1
    fi
  fi

  stage_start_ms="$(runtime_init_now_ms)"
  ln -sfnT "${target_path}" "${link_path}"
  runtime_init_log_duration_ms "replace_symlink_create_new" "${stage_start_ms}"
}

runtime_init_replace_managed_block() {
  local file_path="$1"
  local start_marker="$2"
  local end_marker="$3"
  local block_content="$4"
  local parent_dir tmp_file target_uid target_gid target_mode file_exists

  runtime_init_log "replace managed block in file: ${file_path}"
  parent_dir="$(dirname "${file_path}")"
  mkdir -p "${parent_dir}"
  runtime_init_assert_not_symlink "${file_path}" "managed block target must not be symlink"

  file_exists=0
  if [ -e "${file_path}" ]; then
    file_exists=1
    target_uid="$(stat -c '%u' "${file_path}")"
    target_gid="$(stat -c '%g' "${file_path}")"
    target_mode="$(stat -c '%a' "${file_path}")"
  else
    target_uid="$(stat -c '%u' "${parent_dir}")"
    target_gid="$(stat -c '%g' "${parent_dir}")"
    target_mode="0644"
  fi

  tmp_file="$(mktemp "${parent_dir}/.runtime-init-managed-block.XXXXXX")"

  if [ "${file_exists}" = "1" ]; then
    awk -v start="${start_marker}" -v end="${end_marker}" '
      $0 == start { skip = 1; next }
      $0 == end { skip = 0; next }
      skip != 1 { print }
    ' "${file_path}" > "${tmp_file}"
  fi
  {
    echo "${start_marker}"
    printf "%s\n" "${block_content}"
    echo "${end_marker}"
  } >> "${tmp_file}"

  chown "${target_uid}:${target_gid}" "${tmp_file}"
  chmod "${target_mode}" "${tmp_file}"
  mv "${tmp_file}" "${file_path}"
}

runtime_init_path_owner() {
  local path="$1"
  stat -c '%U:%G' "${path}" 2>/dev/null
}

runtime_init_path_is_healthy() {
  local path="$1"
  ls -la "${path}" >/dev/null 2>&1
}

runtime_init_path_mode() {
  local path="$1"
  stat -c '%a' "${path}" 2>/dev/null
}

runtime_init_assert_not_symlink() {
  local path="$1"
  local message="${2:-path must not be symlink}"
  if [ -L "${path}" ]; then
    runtime_init_failed "${message}: ${path}"
  fi
}

runtime_init_assert_dir() {
  local path="$1"
  local message="${2:-path must be directory}"
  if [ ! -d "${path}" ]; then
    runtime_init_failed "${message}: ${path}"
  fi
}

runtime_init_assert_owner() {
  local path="$1"
  local expected_owner="$2"
  local message="${3:-unexpected path owner}"
  local owner

  owner="$(runtime_init_path_owner "${path}")" || runtime_init_failed "${message}: stat owner failed: ${path}"
  if [ "${owner}" != "${expected_owner}" ]; then
    runtime_init_failed "${message}: path=${path}, expected=${expected_owner}, actual=${owner}"
  fi
}

runtime_init_assert_mode() {
  local path="$1"
  local expected_mode="$2"
  local message="${3:-unexpected path mode}"
  local mode

  mode="$(runtime_init_path_mode "${path}")" || runtime_init_failed "${message}: stat mode failed: ${path}"
  if [ "${mode}" != "${expected_mode}" ]; then
    runtime_init_failed "${message}: path=${path}, expected=${expected_mode}, actual=${mode}"
  fi
}

runtime_init_realpath() {
  local path="$1"
  realpath -m "${path}" 2>/dev/null
}

runtime_init_assert_realpath_eq() {
  local path="$1"
  local expected="$2"
  local message="${3:-unexpected realpath}"
  local actual expected_real

  actual="$(runtime_init_realpath "${path}")" || runtime_init_failed "${message}: resolve path failed: ${path}"
  expected_real="$(runtime_init_realpath "${expected}")" || runtime_init_failed "${message}: resolve expected failed: ${expected}"
  if [ "${actual}" != "${expected_real}" ]; then
    runtime_init_failed "${message}: path=${path}, expected=${expected_real}, actual=${actual}"
  fi
}

runtime_init_assert_realpath_under() {
  local path="$1"
  local root="$2"
  local message="${3:-path is outside expected root}"
  local actual root_real

  actual="$(runtime_init_realpath "${path}")" || runtime_init_failed "${message}: resolve path failed: ${path}"
  root_real="$(runtime_init_realpath "${root}")" || runtime_init_failed "${message}: resolve root failed: ${root}"
  case "${actual}" in
    "${root_real}"|"${root_real}"/*)
      ;;
    *)
      runtime_init_failed "${message}: path=${path}, root=${root_real}, actual=${actual}"
      ;;
  esac
}

runtime_init_path_is_mountpoint() {
  local path="$1"
  if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "${path}"
    return $?
  fi
  return 1
}

runtime_init_validate_no_control_chars() {
  local value="$1"
  local name="$2"
  if printf '%s' "${value}" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    runtime_init_failed "${name} contains control characters"
  fi
}

runtime_init_validate_proxy_url() {
  local value="$1"
  local without_scheme host_port authority host port port_num userinfo ipv6_host

  runtime_init_validate_no_control_chars "${value}" "PROXY"
  if [[ ! "${value}" =~ ^(https?://)?[^/[:space:]]+:[0-9]{1,5}$ ]]; then
    runtime_init_failed "PROXY must be host:port or http(s)://host:port"
  fi
  without_scheme="${value#http://}"
  without_scheme="${without_scheme#https://}"
  host_port="${without_scheme}"
  authority="${host_port%:*}"
  port="${host_port##*:}"
  if [[ "${authority}" == *"@"* ]]; then
    userinfo="${authority%@*}"
    host="${authority##*@}"
    if [ -z "${userinfo}" ] || [[ ! "${userinfo}" =~ ^[A-Za-z0-9._~%:+-]+$ ]]; then
      runtime_init_failed "PROXY userinfo contains invalid characters"
    fi
  else
    host="${authority}"
  fi
  if [ -z "${host}" ]; then
    runtime_init_failed "PROXY host contains invalid characters: ${host}"
  fi
  # Brackets are URL syntax for IPv6 literals, not part of the address itself.
  if [[ "${host}" == \[*\] ]]; then
    ipv6_host="${host#[}"
    ipv6_host="${ipv6_host%]}"
    if [ -z "${ipv6_host}" ] || [[ "${ipv6_host}" != *":"* ]] || [[ ! "${ipv6_host}" =~ ^[0-9A-Fa-f:.]+$ ]]; then
      runtime_init_failed "PROXY IPv6 host contains invalid characters: ${host}"
    fi
  elif [[ "${host}" == *"["* || "${host}" == *"]"* || ! "${host}" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    runtime_init_failed "PROXY host contains invalid characters: ${host}"
  fi
  port_num=$((10#${port}))
  if [ "${port_num}" -lt 1 ] || [ "${port_num}" -gt 65535 ]; then
    runtime_init_failed "PROXY port out of range: ${port}"
  fi
}

runtime_init_validate_no_proxy_list() {
  local value="$1"
  local entry
  local -a entries

  runtime_init_validate_no_control_chars "${value}" "NO_PROXY_DOMAINS"
  IFS=',' read -r -a entries <<< "${value}"
  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    if [ -z "${entry}" ]; then
      runtime_init_failed "NO_PROXY_DOMAINS contains empty entry"
    fi
    if [[ "${entry}" == *"://"* ]]; then
      runtime_init_failed "NO_PROXY_DOMAINS entry must not contain scheme: ${entry}"
    fi
    if [[ "${entry}" == *"*"* ]] && [[ ! "${entry}" =~ ^\*\.[A-Za-z0-9._-]+$ ]]; then
      runtime_init_failed "NO_PROXY_DOMAINS wildcard entry must be leading '*.' only: ${entry}"
    fi
    if [[ ! "${entry}" =~ ^(\*\.)?[A-Za-z0-9._:/-]+$ ]]; then
      runtime_init_failed "NO_PROXY_DOMAINS entry contains invalid characters: ${entry}"
    fi
  done
}

runtime_init_shell_export_line() {
  local key="$1"
  local value="$2"
  printf 'export %s=%q\n' "${key}" "${value}"
}

runtime_init_need_validate_chmod() {
  case "${VM_VALIDATE_MOUNT_CHMOD:-true}" in
    true|1|yes|on|"")
      return 0
      ;;
    false|0|no|off)
      return 1
      ;;
    *)
      runtime_init_log "invalid VM_VALIDATE_MOUNT_CHMOD=${VM_VALIDATE_MOUNT_CHMOD}, fallback true"
      return 0
      ;;
  esac
}

runtime_init_workspace_root_is_healthy() {
  runtime_init_path_is_healthy "${RUNTIME_INIT_WORKSPACE_ROOT}"
}

runtime_init_chown_user_if_needed() {
  local path="$1"
  local recursive="${2:-false}"
  local owner

  owner="$(runtime_init_path_owner "${path}")" || {
    runtime_init_log "skip chown because path is not healthy: ${path}"
    return 0
  }

  if [ "${owner}" = "user:user" ]; then
    runtime_init_log "owner already user:user, skip chown: ${path}"
    return 0
  fi

  if [ "${recursive}" = "true" ]; then
    runtime_init_log "change owner recursively to user:user, path=${path}, current_owner=${owner}"
    runtime_init_run_privileged chown -R user:user "${path}"
  else
    runtime_init_log "change owner to user:user, path=${path}, current_owner=${owner}"
    runtime_init_run_privileged chown user:user "${path}"
  fi
}

runtime_init_ensure_cookie_root() {
  # Browser profile parent directories must be user-owned even when the cookie
  # mount itself is absent or unhealthy; otherwise Chromium cannot create locks.
  runtime_init_log "ensure browser profile parent directories, browser_default_dir=${RUNTIME_INIT_BROWSER_DEFAULT_DIR}"
  runtime_init_assert_not_symlink "${RUNTIME_INIT_USER_HOME}/.config" "browser config parent must not be symlink"
  runtime_init_run_privileged mkdir -p "${RUNTIME_INIT_USER_HOME}/.config"
  runtime_init_assert_not_symlink "${RUNTIME_INIT_BROWSER_CONFIG_DIR}" "browser config dir must not be symlink"
  runtime_init_run_privileged mkdir -p "${RUNTIME_INIT_BROWSER_CONFIG_DIR}"
  runtime_init_assert_not_symlink "${RUNTIME_INIT_BROWSER_DEFAULT_DIR}" "browser default dir must not be symlink"
  runtime_init_run_privileged mkdir -p "${RUNTIME_INIT_BROWSER_DEFAULT_DIR}"
  runtime_init_chown_user_if_needed "${RUNTIME_INIT_USER_HOME}/.config"
  runtime_init_chown_user_if_needed "${RUNTIME_INIT_BROWSER_CONFIG_DIR}"
  runtime_init_chown_user_if_needed "${RUNTIME_INIT_BROWSER_DEFAULT_DIR}"
  runtime_init_assert_owner "${RUNTIME_INIT_BROWSER_DEFAULT_DIR}" "user:user" "browser profile default dir owner mismatch"

  # Cookie root may be a VEFAAS/TOS mount. Touch it only after its directory
  # entries can be listed to avoid errors such as "Transport endpoint is not connected".
  if runtime_init_path_is_healthy "${RUNTIME_INIT_COOKIE_ROOT}"; then
    runtime_init_log "cookie root is healthy, ensure owner: ${RUNTIME_INIT_COOKIE_ROOT}"
    runtime_init_assert_not_symlink "${RUNTIME_INIT_COOKIE_ROOT}" "cookie root must not be symlink"
    runtime_init_assert_dir "${RUNTIME_INIT_COOKIE_ROOT}" "cookie root must be directory"
    runtime_init_assert_realpath_under "${RUNTIME_INIT_COOKIE_ROOT}" "${RUNTIME_INIT_BROWSER_DEFAULT_DIR}" "cookie root must stay under browser default dir"
    runtime_init_chown_user_if_needed "${RUNTIME_INIT_COOKIE_ROOT}" true
    runtime_init_assert_owner "${RUNTIME_INIT_COOKIE_ROOT}" "user:user" "cookie root owner mismatch after chown"
    return 0
  fi

  runtime_init_log "skip cookie root owner ensure because cookie root is not healthy: ${RUNTIME_INIT_COOKIE_ROOT}"
}

runtime_init_workspace_is_ready() {
  runtime_init_workspace_root_is_healthy &&
    [ -L "${RUNTIME_INIT_WORKSPACE}" ] &&
    [ "$(readlink "${RUNTIME_INIT_WORKSPACE}")" = "${RUNTIME_INIT_WORKSPACE_TARGET}" ]
}

runtime_init_run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return $?
  fi
  sudo "$@"
}

runtime_init_write_workspace_config() {
  local tmp_path
  runtime_init_log "write workspace config, path=${RUNTIME_INIT_WORKSPACE_CONFIG_PATH}, work_dir=${RUNTIME_INIT_WORKSPACE}"
  runtime_init_run_privileged mkdir -p "${RUNTIME_INIT_WORKSPACE_CONFIG_DIR}" || runtime_init_failed "create workspace config dir failed"
  tmp_path="${RUNTIME_INIT_WORKSPACE_CONFIG_PATH}.tmp.$$"
  runtime_init_validate_no_control_chars "${RUNTIME_INIT_WORKSPACE}" "RUNTIME_INIT_WORKSPACE"
  printf '{\n  "work_dir": "%s"\n}\n' "${RUNTIME_INIT_WORKSPACE}" > "${tmp_path}" || runtime_init_failed "write workspace config temp failed"
  runtime_init_run_privileged mv -f "${tmp_path}" "${RUNTIME_INIT_WORKSPACE_CONFIG_PATH}" || runtime_init_failed "commit workspace config failed"
  runtime_init_run_privileged chown user:user "${RUNTIME_INIT_WORKSPACE_CONFIG_PATH}" || runtime_init_failed "chown workspace config failed"
  runtime_init_run_privileged chmod 644 "${RUNTIME_INIT_WORKSPACE_CONFIG_PATH}" || runtime_init_failed "chmod workspace config failed"
}
