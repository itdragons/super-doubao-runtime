#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TINYPROXY_CONFIG_PATH="/etc/tinyproxy.conf"
TINYPROXY_BASE_CONFIG_PATH="/opt/gem/tinyproxy/base.conf"
TINYPROXY_CONFIG_DIR="/opt/gem/tinyproxy"
TINYPROXY_SUPERVISOR_CONFIG="/opt/gem/supervisord/supervisord.tinyproxy.conf"

normalize_proxy_value() {
  local raw_value="${1:-}"

  raw_value="$(printf '%s' "${raw_value}" | xargs)"
  raw_value="${raw_value#\"}"
  raw_value="${raw_value%\"}"
  raw_value="${raw_value#\'}"
  raw_value="${raw_value%\'}"
  raw_value="${raw_value#http://}"
  raw_value="${raw_value#https://}"
  printf '%s' "${raw_value}"
}

normalize_proxy_exclude_entry() {
  local raw_value="${1:-}"

  raw_value="$(printf '%s' "${raw_value}" | xargs)"
  raw_value="${raw_value#\"}"
  raw_value="${raw_value%\"}"
  raw_value="${raw_value#\'}"
  raw_value="${raw_value%\'}"

  if [ -z "${raw_value}" ]; then
    return 1
  fi

  if [[ "${raw_value}" == *"://"* ]]; then
    runtime_init_log "skip invalid PROXY_EXCLUDE entry with scheme: ${raw_value}"
    return 1
  fi

  if [[ "${raw_value}" == *"/"* ]]; then
    if [[ ! "${raw_value}" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]] && [[ ! "${raw_value}" =~ ^[0-9A-Fa-f:.]+/[0-9A-Fa-f:.]+$ ]]; then
      runtime_init_log "skip invalid PROXY_EXCLUDE entry with path-like content: ${raw_value}"
      return 1
    fi
  fi

  if [[ "${raw_value}" == *"*"* ]]; then
    if [[ "${raw_value}" == \*.* ]]; then
      raw_value=".${raw_value#*.}"
    else
      runtime_init_log "skip invalid PROXY_EXCLUDE wildcard entry: ${raw_value}"
      return 1
    fi
  fi

  printf '%s' "${raw_value}"
}

append_optional_tinyproxy_fragments() {
  local fragment_path

  if [ ! -d "${TINYPROXY_CONFIG_DIR}" ]; then
    return 0
  fi

  for fragment_path in "${TINYPROXY_CONFIG_DIR}"/*.conf; do
    if [ ! -f "${fragment_path}" ]; then
      continue
    fi
    if [ "${fragment_path}" = "${TINYPROXY_BASE_CONFIG_PATH}" ]; then
      continue
    fi

    runtime_init_log "append optional tinyproxy fragment: ${fragment_path}"
    printf "\n# === %s ===\n" "$(basename "${fragment_path}")"
    envsubst < "${fragment_path}"
  done
}

append_proxy_exclude_rules() {
  local raw_list="${PROXY_EXCLUDE:-}"
  local raw_entry normalized_entry
  local seen_entries="|"
  local appended_count=0

  if [ -z "${raw_list}" ]; then
    return 0
  fi

  IFS=',' read -r -a raw_entries <<< "${raw_list}"
  for raw_entry in "${raw_entries[@]}"; do
    if ! normalized_entry="$(normalize_proxy_exclude_entry "${raw_entry}")"; then
      continue
    fi

    if [[ "${seen_entries}" == *"|${normalized_entry}|"* ]]; then
      continue
    fi

    if [ "${appended_count}" -eq 0 ]; then
      printf "\n# === Auto-generated Proxy Exclude ===\n"
    fi
    printf 'Upstream none "%s"\n' "${normalized_entry}"

    seen_entries="${seen_entries}${normalized_entry}|"
    appended_count=$((appended_count + 1))
  done

  return 0
}

if [ -z "${PROXY:-}" ]; then
  runtime_init_log "PROXY is empty, skip apply_browser_proxy_server"
  runtime_init_skipped "proxy is not configured"
fi

if [ ! -f "${TINYPROXY_CONFIG_PATH}" ]; then
  runtime_init_log "tinyproxy config is missing, skip apply_browser_proxy_server: ${TINYPROXY_CONFIG_PATH}"
  runtime_init_skipped "tinyproxy config is not initialized"
fi

if [ ! -f "${TINYPROXY_SUPERVISOR_CONFIG}" ]; then
  runtime_init_log "tinyproxy supervisor config is missing, skip apply_browser_proxy_server: ${TINYPROXY_SUPERVISOR_CONFIG}"
  runtime_init_skipped "tinyproxy supervisor config is not initialized"
fi

if [ ! -f "${TINYPROXY_BASE_CONFIG_PATH}" ]; then
  runtime_init_failed "tinyproxy base config not found: ${TINYPROXY_BASE_CONFIG_PATH}"
fi

normalized_proxy="$(normalize_proxy_value "${PROXY}")"
if [ -z "${normalized_proxy}" ]; then
  runtime_init_log "PROXY becomes empty after normalization, skip apply_browser_proxy_server"
  runtime_init_skipped "proxy is empty after normalization"
fi

export TINYPROXY_PORT="${TINYPROXY_PORT:-8118}"

runtime_init_log "apply browser proxy server from PROXY"
tmp_file="$(mktemp)"
trap 'rm -f "${tmp_file}"' EXIT

{
  envsubst < "${TINYPROXY_BASE_CONFIG_PATH}"
  printf "\n# === Auto-generated Upstream ===\n"
  printf "Upstream http %s\n" "${normalized_proxy}"
  append_optional_tinyproxy_fragments
  append_proxy_exclude_rules
} > "${tmp_file}"

runtime_init_run_privileged chmod 644 "${tmp_file}"
runtime_init_run_privileged mv "${tmp_file}" "${TINYPROXY_CONFIG_PATH}"
export PROXY_SERVER="${PROXY}"

wait_for_tinyproxy_running() {
  local attempt
  local status_output

  for attempt in $(seq 1 30); do
    status_output="$(runtime_init_run_privileged supervisorctl status tinyproxy 2>/dev/null || true)"
    if printf '%s\n' "${status_output}" | grep -q "RUNNING"; then
      return 0
    fi
    sleep 0.1
  done

  return 1
}

runtime_init_log "reload tinyproxy via supervisorctl signal HUP"
if ! runtime_init_run_privileged supervisorctl signal HUP tinyproxy >/tmp/apply_browser_proxy_server.supervisorctl.log 2>&1; then
  cat /tmp/apply_browser_proxy_server.supervisorctl.log >&2 || true
  runtime_init_log "reload tinyproxy failed, fallback to restart"
  if ! runtime_init_run_privileged supervisorctl restart tinyproxy >/tmp/apply_browser_proxy_server.supervisorctl.log 2>&1; then
    cat /tmp/apply_browser_proxy_server.supervisorctl.log >&2 || true
    runtime_init_failed "restart tinyproxy failed"
  fi
fi
rm -f /tmp/apply_browser_proxy_server.supervisorctl.log

if ! wait_for_tinyproxy_running; then
  runtime_init_failed "tinyproxy is not running after reload"
fi

runtime_init_success "browser proxy server applied"
