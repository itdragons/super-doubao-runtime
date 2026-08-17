#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# bundle 是 lark-cli 登录态 tar+gzip 包，内含（相对 /home/user）：
#   .lark-cli/config.json
#   .local/share/lark-cli/master.key
#   .local/share/lark-cli/<account>.enc

WORKSPACE_ROOT="${RUNTIME_INIT_WORKSPACE_ROOT:-/sandboxdata/workspace}"
BUNDLE_FILE="${WORKSPACE_ROOT}/lark_cli_rebuild.tar.gz"
USER_HOME="${RUNTIME_INIT_USER_HOME:-/home/user}"
LARK_CLI_CONFIG_DIR="${USER_HOME}/.lark-cli"
LARK_CLI_KEYCHAIN_DIR="${USER_HOME}/.local/share/lark-cli"

# 挂载点可能未挂或不健康，目录可枚举后再判文件存在，避免 "Transport endpoint is not connected"。
if ! runtime_init_path_is_healthy "${WORKSPACE_ROOT}"; then
  runtime_init_skipped "workspace mount not healthy, skip lark cli rebuild"
fi
if [ ! -f "${BUNDLE_FILE}" ]; then
  runtime_init_skipped "lark cli rebuild bundle not found, skip lark cli rebuild"
fi

runtime_init_log "rebuild lark cli login state from bundle file: ${BUNDLE_FILE}"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# 先从挂载目录 cp 到本地临时目录再解包。
if ! cp "${BUNDLE_FILE}" "${TMP_DIR}/bundle.tar.gz" 2>/dev/null; then
  runtime_init_failed "copy lark cli rebuild bundle from mount failed"
fi

# 已复制到本地，挂载目录的 bundle 不再需要（内含登录凭证），消费即删；删除失败不阻塞。
remove_bundle_start_ms="$(runtime_init_now_ms)"
if runtime_init_run_privileged rm -f "${BUNDLE_FILE}"; then
  runtime_init_log_duration_ms "remove_lark_cli_rebuild_bundle" "${remove_bundle_start_ms}"
  runtime_init_log "removed consumed lark cli rebuild bundle: ${BUNDLE_FILE}"
else
  runtime_init_log_duration_ms "remove_lark_cli_rebuild_bundle_failed" "${remove_bundle_start_ms}"
  runtime_init_log "remove lark cli rebuild bundle failed, continue: ${BUNDLE_FILE}"
fi

if ! tar -xzf "${TMP_DIR}/bundle.tar.gz" -C "${TMP_DIR}" 2>/dev/null; then
  runtime_init_failed "extract lark cli rebuild bundle failed"
fi

# 校验关键文件存在。
if [ ! -f "${TMP_DIR}/.lark-cli/config.json" ] || [ ! -f "${TMP_DIR}/.local/share/lark-cli/master.key" ]; then
  runtime_init_failed "rebuild bundle missing config.json or master.key"
fi

runtime_init_run_privileged mkdir -p "${LARK_CLI_CONFIG_DIR}" "${LARK_CLI_KEYCHAIN_DIR}"

# 落地 config.json。
runtime_init_run_privileged cp "${TMP_DIR}/.lark-cli/config.json" "${LARK_CLI_CONFIG_DIR}/config.json"

# 落地 keychain：master.key + 全部 .enc 条目。
runtime_init_run_privileged cp "${TMP_DIR}/.local/share/lark-cli/master.key" "${LARK_CLI_KEYCHAIN_DIR}/master.key"
for enc_file in "${TMP_DIR}/.local/share/lark-cli/"*.enc; do
  [ -e "${enc_file}" ] || continue
  runtime_init_run_privileged cp "${enc_file}" "${LARK_CLI_KEYCHAIN_DIR}/"
done

# 修正属主与权限（容器内 user）。
runtime_init_run_privileged chown -R user:user "${LARK_CLI_CONFIG_DIR}" "${LARK_CLI_KEYCHAIN_DIR}"
runtime_init_run_privileged chmod 600 "${LARK_CLI_CONFIG_DIR}/config.json"
runtime_init_run_privileged chmod 700 "${LARK_CLI_KEYCHAIN_DIR}"
runtime_init_run_privileged bash -c "chmod 600 ${LARK_CLI_KEYCHAIN_DIR}/*" || true

runtime_init_success "lark cli login state rebuilt from bundle"
