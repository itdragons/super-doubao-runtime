#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

runtime_init_log "lark cli env: LARK_CLI_URL='${LARK_CLI_URL:-}' LARK_CLI_ALIAS='${LARK_CLI_ALIAS:-}'"
runtime_init_log "new lark cli env: LARK_CLI_ASSET_ID='${LARK_CLI_ASSET_ID:-}' LARK_CLI_RESOURCE_PATH='${LARK_CLI_RESOURCE_PATH:-}'"

LARK_CLI_DOWNLOADED_PATH=/usr/local/bin/lark-cli-downloaded
LARK_CLI_STATE_DIR="${RUNTIME_INIT_RUNTIME_PATH}/tmp"
LARK_CLI_TMP_PATH="${LARK_CLI_STATE_DIR}/lark-cli.download.tmp"
LARK_CLI_DONE_PATH="${LARK_CLI_STATE_DIR}/lark_cli_done"
LARK_CLI_LINK_PATH=""
selected_path=""

runtime_init_log "prepare lark cli state dir: ${LARK_CLI_STATE_DIR}"
mkdir -p "${LARK_CLI_STATE_DIR}"
chown user:user "${LARK_CLI_STATE_DIR}" || true
chmod 755 "${LARK_CLI_STATE_DIR}" || true

validate_lark_cli_url() {
  local url="$1"
  if [[ ! "${url}" =~ ^https?://[^[:space:]]+$ ]]; then
    runtime_init_log "invalid LARK_CLI_URL: ${url}"
    return 1
  fi
  return 0
}

resolve_lark_cli_alias() {
  local alias="${LARK_CLI_ALIAS:-lark-cli}"

  if [[ ! "${alias}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    runtime_init_log "LARK_CLI_ALIAS is invalid, fallback to default lark-cli: ${alias}"
    alias="lark-cli"
  fi

  LARK_CLI_LINK_PATH="/usr/local/bin/${alias}"
  runtime_init_log "lark cli command alias resolved: ${alias} -> ${LARK_CLI_LINK_PATH}"
}

get_lark_cli_binary() {
  local url="${LARK_CLI_URL:-}"
  local attempt=1

  rm -f "${LARK_CLI_TMP_PATH}"

  if [ -z "${url}" ]; then
    runtime_init_log "LARK_CLI_URL is empty, skip lark cli installation"
    return 2
  fi

  validate_lark_cli_url "${url}" || return 1

  while [ "${attempt}" -le 3 ]; do
    runtime_init_log "download lark cli attempt ${attempt}/3"
    rm -f "${LARK_CLI_TMP_PATH}"
    if curl --noproxy '*' -fL --connect-timeout 1 --max-time 5 "${url}" -o "${LARK_CLI_TMP_PATH}"; then
      if [ ! -s "${LARK_CLI_TMP_PATH}" ]; then
        runtime_init_log "downloaded lark cli is empty"
        rm -f "${LARK_CLI_TMP_PATH}"
        return 1
      fi
      runtime_init_run_privileged mv "${LARK_CLI_TMP_PATH}" "${LARK_CLI_DOWNLOADED_PATH}"
      selected_path="${LARK_CLI_DOWNLOADED_PATH}"
      return 0
    fi
    attempt=$((attempt + 1))
    if [ "${attempt}" -le 3 ]; then
      sleep 1
    fi
  done

  runtime_init_log "download lark cli failed after 3 attempts"
  return 1
}

ensure_symlink_points_to_target() {
  local target_path="$1"
  local link_path="$2"
  if [ -L "${link_path}" ] && [ "$(readlink "${link_path}")" = "${target_path}" ]; then
    runtime_init_log "lark cli symlink already up to date: ${link_path}"
    return 0
  fi
  runtime_init_log "update lark cli symlink, link=${link_path}, target=${target_path}"
  runtime_init_run_privileged ln -sfnT "${target_path}" "${link_path}"
}

if [ -n "${LARK_CLI_RESOURCE_PATH:-}" ]; then
  LARK_CLI_LINK_PATH="${LARK_CLI_RESOURCE_PATH}"
  runtime_init_log "lark cli resource path is present, skip legacy download and install chain: ${LARK_CLI_RESOURCE_PATH}"
  runtime_init_log "new lark cli chain selected: source=resource-loader, legacy_download_skipped=true, resource_path='${LARK_CLI_RESOURCE_PATH}'"
else
  resolve_lark_cli_alias
  if get_lark_cli_binary; then
    get_lark_cli_result=0
  else
    get_lark_cli_result=$?
  fi
  if [ "${get_lark_cli_result}" -eq 2 ]; then
    runtime_init_skipped "lark cli installation skipped"
  fi
  if [ "${get_lark_cli_result}" -ne 0 ]; then
    runtime_init_failed "get lark cli failed"
  fi

  [ -f "${selected_path}" ] || runtime_init_failed "selected lark cli binary not found"
  runtime_init_log "selected lark cli binary: ${selected_path}"

  runtime_init_log "ensure lark cli binary owner and permission"
  runtime_init_run_privileged chown user:user "${selected_path}" || runtime_init_failed "chown lark cli failed"
  runtime_init_run_privileged chmod 700 "${selected_path}" || runtime_init_failed "chmod lark cli failed"
  ensure_symlink_points_to_target "${selected_path}" "${LARK_CLI_LINK_PATH}" || runtime_init_failed "replace lark cli symlink failed"
fi

runtime_init_log "touch lark cli done marker: ${LARK_CLI_DONE_PATH}"
runtime_init_run_privileged touch "${LARK_CLI_DONE_PATH}" || runtime_init_failed "touch lark cli done marker failed"

if [ -n "${LARK_CLI_RESOURCE_PATH:-}" ]; then
  runtime_init_log "new lark cli install result: LARK_CLI_LINK_PATH='${LARK_CLI_LINK_PATH}', marker='${LARK_CLI_DONE_PATH}', status=success"
  runtime_init_success "using lark cli binary installed by resource-loader: ${LARK_CLI_RESOURCE_PATH}, command=${LARK_CLI_LINK_PATH}"
fi
runtime_init_success "using lark cli binary: ${selected_path}, command=${LARK_CLI_LINK_PATH}"
