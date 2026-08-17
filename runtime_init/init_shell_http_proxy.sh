#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

if [ -z "${PROXY:-}" ]; then
  runtime_init_log "PROXY is empty, skip init_shell_http_proxy"
  runtime_init_skipped "proxy is not configured"
fi
runtime_init_validate_proxy_url "${PROXY}"

# Persist proxy envs into .bashrc via a managed block so repeated post_hook
# executions converge instead of appending duplicate exports.
no_proxy_value="localhost,127.0.0.1,::1"
if [ -n "${NO_PROXY_DOMAINS:-}" ]; then
  runtime_init_log "NO_PROXY_DOMAINS is configured, append to no_proxy"
  no_proxy_value="${no_proxy_value},${NO_PROXY_DOMAINS}"
fi
runtime_init_validate_no_proxy_list "${no_proxy_value}"
runtime_init_log "proxy is configured, update shell proxy managed block"

managed_block=$(
  {
    runtime_init_shell_export_line "http_proxy" "${PROXY}"
    runtime_init_shell_export_line "https_proxy" "${PROXY}"
    runtime_init_shell_export_line "HTTP_PROXY" "${PROXY}"
    runtime_init_shell_export_line "HTTPS_PROXY" "${PROXY}"
    runtime_init_shell_export_line "no_proxy" "${no_proxy_value}"
    runtime_init_shell_export_line "NO_PROXY" "${no_proxy_value}"
  }
)

runtime_init_replace_managed_block \
  "${RUNTIME_INIT_USER_HOME}/.bashrc" \
  "# >>> mcp_vm_server proxy start >>>" \
  "# <<< mcp_vm_server proxy end <<<" \
  "${managed_block}"

# Export for the remaining commands in this script execution as well as future
# interactive shells through .bashrc.
export http_proxy="${PROXY}"
export https_proxy="${PROXY}"
export HTTP_PROXY="${PROXY}"
export HTTPS_PROXY="${PROXY}"
export no_proxy="${no_proxy_value}"
export NO_PROXY="${no_proxy_value}"

runtime_init_success "proxy initialized"
