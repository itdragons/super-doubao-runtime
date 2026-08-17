#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

runtime_init_validate_workspace_placeholder_before_remove() {
  local path="$1"
  local entry
  local entry_name
  local skills_link_target="${RUNTIME_INIT_RUNTIME_PATH}/skills"

  if [ "${path}" != "${RUNTIME_INIT_WORKSPACE}" ] &&
    [ "${path}" != "${RUNTIME_INIT_AGENT_MODE_WORKSPACE}" ] &&
    [ "${path}" != "${RUNTIME_INIT_LEGACY_WORKSPACE}" ]; then
    runtime_init_failed "refuse to remove unexpected workspace placeholder path: ${path}"
  fi
  if [ "${path}" = "${RUNTIME_INIT_AGENT_MODE_WORKSPACE}" ]; then
    runtime_init_assert_realpath_under "${path}" "${RUNTIME_INIT_AGENT_MODE_DIR}" "agent mode workspace placeholder outside agent mode dir"
  else
    runtime_init_assert_realpath_under "${path}" "${RUNTIME_INIT_RUNTIME_PATH}" "workspace placeholder outside runtime path"
  fi
  runtime_init_assert_not_symlink "${path}" "workspace placeholder must not be symlink"
  runtime_init_assert_dir "${path}" "workspace placeholder must be directory"
  if runtime_init_path_is_mountpoint "${path}"; then
    runtime_init_failed "workspace placeholder must not be mountpoint: ${path}"
  fi
  while IFS= read -r entry; do
    entry_name="${entry##*/}"
    if runtime_init_is_managed_workspace_skills_link "${entry}" "${entry_name}"; then
      continue
    fi
    runtime_init_failed "workspace placeholder contains unexpected entry, refuse to remove: ${entry}"
  done < <(find "${path}" -mindepth 1 -maxdepth 1 -print)
}

runtime_init_ensure_workspace_symlink() {
  local workspace_path="$1"
  local label="$2"
  local stage_start_ms
  local workspace_backup

  if [ -z "${workspace_path}" ]; then
    return 0
  fi

  runtime_init_log "ensure ${label} symlink, workspace=${workspace_path}, target=${RUNTIME_INIT_WORKSPACE_TARGET}"
  if [ -e "${workspace_path}" ] && [ ! -L "${workspace_path}" ]; then
    # Standby cold start may create a plain directory placeholder before the
    # workspace mount is ready. Once the mount is ready, replace only managed
    # placeholder directories with the session workspace symlink.
    runtime_init_validate_workspace_placeholder_before_remove "${workspace_path}"
    if [ "${RUNTIME_INIT_BACKUP_WORKSPACE_PLACEHOLDER:-}" = "1" ]; then
      workspace_backup="${workspace_path}.placeholder.$(runtime_init_now_ms)"
      runtime_init_log "backup existing non-symlink workspace placeholder before binding, path=${workspace_path}, backup=${workspace_backup}"
      runtime_init_run_privileged mv "${workspace_path}" "${workspace_backup}" || runtime_init_failed "backup ${label} placeholder failed"
    else
      runtime_init_log "remove existing non-symlink workspace placeholder before binding, path=${workspace_path}"
      runtime_init_run_privileged rm -rf "${workspace_path}" || runtime_init_failed "remove ${label} placeholder failed"
    fi
  fi

  stage_start_ms="$(runtime_init_now_ms)"
  runtime_init_replace_symlink "${RUNTIME_INIT_WORKSPACE_TARGET}" "${workspace_path}" || runtime_init_failed "replace ${label} symlink failed"
  runtime_init_log_duration_ms "workspace_bind_${label}_symlink" "${stage_start_ms}"

  stage_start_ms="$(runtime_init_now_ms)"
  runtime_init_run_privileged chown -h user:user "${workspace_path}" || runtime_init_failed "chown ${label} symlink failed"
  runtime_init_log_duration_ms "workspace_chown_${label}_symlink" "${stage_start_ms}"
}

runtime_init_is_managed_workspace_skills_link() {
  local entry="$1"
  local entry_name="$2"
  local skills_link_target="${RUNTIME_INIT_RUNTIME_PATH}/skills"

  if [ "${entry_name}" != "skills" ] || [ ! -L "${entry}" ]; then
    return 1
  fi
  if [ "$(readlink "${entry}")" != "${skills_link_target}" ]; then
    return 1
  fi
  runtime_init_log "allow managed skills symlink in workspace placeholder: ${entry} -> ${skills_link_target}"
  return 0
}

# Workspace root is a VEFAAS/TOS mount. Check health before touching it to avoid
# transport endpoint errors on standby warm containers.
runtime_init_log "start init workspace, workspace=${RUNTIME_INIT_WORKSPACE}, workspace_root=${RUNTIME_INIT_WORKSPACE_ROOT}, target=${RUNTIME_INIT_WORKSPACE_TARGET}"
stage_start_ms="$(runtime_init_now_ms)"
runtime_init_ensure_cookie_root
runtime_init_log_duration_ms "workspace_prepare_browser_profile" "${stage_start_ms}"

stage_start_ms="$(runtime_init_now_ms)"
mkdir -p "$(dirname "${RUNTIME_INIT_WORKSPACE}")"
runtime_init_log_duration_ms "workspace_prepare_runtime_parent" "${stage_start_ms}"

stage_start_ms="$(runtime_init_now_ms)"
if ! runtime_init_workspace_root_is_healthy || [ ! -d "${RUNTIME_INIT_WORKSPACE_ROOT}" ]; then
  runtime_init_log_duration_ms "workspace_check_root_health" "${stage_start_ms}"
  if [ -L "${RUNTIME_INIT_WORKSPACE}" ]; then
    runtime_init_log "workspace root is not healthy or not ready, keep existing workspace symlink untouched: ${RUNTIME_INIT_WORKSPACE}"
    runtime_init_skipped "workspace root is not ready"
  fi
  stage_start_ms="$(runtime_init_now_ms)"
  runtime_init_run_privileged mkdir -p "${RUNTIME_INIT_WORKSPACE}"
  runtime_init_run_privileged chmod 777 "${RUNTIME_INIT_WORKSPACE}"
  runtime_init_log_duration_ms "workspace_prepare_placeholder" "${stage_start_ms}"
  runtime_init_log "workspace root is not healthy or not ready, keep placeholder workspace: ${RUNTIME_INIT_WORKSPACE}"
  runtime_init_skipped "workspace root is not ready"
fi
runtime_init_log_duration_ms "workspace_check_root_health" "${stage_start_ms}"

runtime_init_log "workspace root is healthy, prepare target: ${RUNTIME_INIT_WORKSPACE_TARGET}"
stage_start_ms="$(runtime_init_now_ms)"
runtime_init_run_privileged mkdir -p "${RUNTIME_INIT_WORKSPACE_TARGET}" || runtime_init_failed "create workspace target failed"
runtime_init_run_privileged chown user:user "${RUNTIME_INIT_WORKSPACE_TARGET}" || runtime_init_failed "chown workspace target failed"
runtime_init_run_privileged chmod 777 "${RUNTIME_INIT_WORKSPACE_TARGET}" || runtime_init_failed "chmod workspace target failed"
runtime_init_assert_dir "${RUNTIME_INIT_WORKSPACE_TARGET}" "workspace target must be directory"
if runtime_init_need_validate_chmod; then
  runtime_init_assert_owner "${RUNTIME_INIT_WORKSPACE_TARGET}" "user:user" "workspace target owner mismatch"
  runtime_init_assert_mode "${RUNTIME_INIT_WORKSPACE_TARGET}" "777" "workspace target mode mismatch"
else
  runtime_init_log "skip workspace target owner/mode assertion because VM_VALIDATE_MOUNT_CHMOD=false"
fi
runtime_init_log_duration_ms "workspace_prepare_target" "${stage_start_ms}"

runtime_init_log "bind managed workspace symlinks to session workspace"
runtime_init_ensure_workspace_symlink "${RUNTIME_INIT_WORKSPACE}" "runtime"

if [ "${RUNTIME_INIT_AGENT_MODE_WORKSPACE}" != "${RUNTIME_INIT_WORKSPACE}" ]; then
  runtime_init_ensure_workspace_symlink "${RUNTIME_INIT_AGENT_MODE_WORKSPACE}" "agent_mode"
fi

if [ "${RUNTIME_INIT_LEGACY_WORKSPACE}" != "${RUNTIME_INIT_WORKSPACE}" ] &&
  [ "${RUNTIME_INIT_LEGACY_WORKSPACE}" != "${RUNTIME_INIT_AGENT_MODE_WORKSPACE}" ]; then
  runtime_init_ensure_workspace_symlink "${RUNTIME_INIT_LEGACY_WORKSPACE}" "legacy"
fi

runtime_init_write_workspace_config

runtime_init_success "workspace linked to session workspace"
