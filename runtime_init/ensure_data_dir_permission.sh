#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

data_dir="/sandboxdata/data"

runtime_init_log "start ensure data dir permission, path=${data_dir}"
if [ ! -e "${data_dir}" ]; then
  runtime_init_log "data dir is absent, skip chmod 700: ${data_dir}"
  runtime_init_skipped "data dir is absent"
fi
if ! runtime_init_path_is_healthy "${data_dir}"; then
  runtime_init_log "data dir is not healthy, skip chmod 700: ${data_dir}"
  runtime_init_skipped "data dir is not healthy"
fi
runtime_init_assert_not_symlink "${data_dir}" "data dir must not be symlink"
runtime_init_assert_dir "${data_dir}" "data dir must be directory"

stage_start_ms="$(runtime_init_now_ms)"
runtime_init_run_privileged chmod 700 "${data_dir}" || runtime_init_failed "chmod data dir failed"
runtime_init_log_duration_ms "chmod_data_dir_700" "${stage_start_ms}"

owner="$(runtime_init_path_owner "${data_dir}" || true)"
mode="$(stat -c '%a' "${data_dir}" 2>/dev/null || true)"
runtime_init_log "data dir permission ensured, path=${data_dir}, owner=${owner:-unknown}, mode=${mode:-unknown}"
if runtime_init_need_validate_chmod; then
  runtime_init_assert_owner "${data_dir}" "root:root" "data dir owner mismatch after chmod"
  runtime_init_assert_mode "${data_dir}" "700" "data dir mode mismatch after chmod"
else
  runtime_init_log "skip data dir owner/mode assertion because VM_VALIDATE_MOUNT_CHMOD=false"
fi
runtime_init_success "data dir permission ensured"
