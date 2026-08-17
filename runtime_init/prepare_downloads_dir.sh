#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Downloads must live under the session workspace so browser downloads persist
# to the mounted workspace after post_hook finishes.
runtime_init_log "start prepare downloads dir, downloads_path=${RUNTIME_INIT_DOWNLOADS_PATH}"
if ! runtime_init_workspace_is_ready; then
  runtime_init_log "workspace is not bound to session workspace, skip prepare_downloads_dir"
  runtime_init_skipped "workspace is not ready"
fi

runtime_init_log "workspace is ready, ensure downloads dir owner and permission"
runtime_init_run_privileged mkdir -p "${RUNTIME_INIT_DOWNLOADS_PATH}" || runtime_init_failed "create downloads dir failed"
runtime_init_run_privileged chown user:user "${RUNTIME_INIT_DOWNLOADS_PATH}" || runtime_init_failed "chown downloads dir failed"
runtime_init_run_privileged chmod 777 "${RUNTIME_INIT_DOWNLOADS_PATH}" || runtime_init_failed "chmod downloads dir failed"

runtime_init_success "downloads dir prepared"
