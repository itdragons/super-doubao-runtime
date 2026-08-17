#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

HIJACK_PROXY_CA_DIR="/hijack_proxy/ca"
HIJACK_PROXY_CONFIG_DIR="/hijack_proxy/config"
HIJACK_PROXY_OUTPUT_DIR="/hijack_proxy/output"
HIJACK_PROXY_BINARY="/hijack_proxy/lark_hijack_proxy"
HIJACK_PROXY_CERT_PATH="${HIJACK_PROXY_OUTPUT_DIR}/cert.pem"
HIJACK_PROXY_KEY_PATH="${HIJACK_PROXY_OUTPUT_DIR}/key.pem"
HIJACK_PROXY_CERT_EXT_PATH="${HIJACK_PROXY_CONFIG_DIR}/server_cert.ext"
HIJACK_PROXY_CSR_PATH="${HIJACK_PROXY_OUTPUT_DIR}/server.csr"
HIJACK_PROXY_CA_SERIAL_PATH="${HIJACK_PROXY_OUTPUT_DIR}/ca.srl"
HIJACK_PROXY_DOMAINS_PATH="${HIJACK_PROXY_OUTPUT_DIR}/dns_hosts"
DEFAULT_HIJACK_DNS_HOSTS="open.feishu.cn,open.feishu-pre.cn,accounts.feishu.cn,accounts.feishu-pre.cn,open.larksuite.com,accounts.larksuite.com,meego.larkoffice.com,project.feishu.cn,meegle.com,mediakit.cn-beijing.volces.com"
script_start_ms="$(runtime_init_now_ms)"

is_hijack_proxy_enabled() {
  local value="${HIJACK_PROXY_ENABLE:-}"

  [ "${value}" != "0" ]
}

generate_hijack_proxy_cert() {
  local dns_domains="$1"
  local first_domain=""
  local san_entries=""
  local domain=""

  mkdir -p "${HIJACK_PROXY_CONFIG_DIR}" "${HIJACK_PROXY_OUTPUT_DIR}"

  for domain in $dns_domains; do
    if [ -z "$first_domain" ]; then
      first_domain="$domain"
    fi

    if [ -n "$san_entries" ]; then
      san_entries="${san_entries},"
    fi
    san_entries="${san_entries}DNS:${domain}"
  done

  if [ -z "$first_domain" ]; then
    runtime_init_log "no valid hijack dns domains found"
    return 1
  fi

  cat > "${HIJACK_PROXY_CERT_EXT_PATH}" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${san_entries}
EOF

  rm -f "${HIJACK_PROXY_CERT_PATH}" "${HIJACK_PROXY_KEY_PATH}" "${HIJACK_PROXY_CA_SERIAL_PATH}" "${HIJACK_PROXY_CSR_PATH}"

  openssl req -new -nodes -newkey rsa:2048 \
    -keyout "${HIJACK_PROXY_KEY_PATH}" \
    -out "${HIJACK_PROXY_CSR_PATH}" \
    -subj "/CN=${first_domain}" || return 1

  openssl x509 -req \
    -in "${HIJACK_PROXY_CSR_PATH}" \
    -CA "${HIJACK_PROXY_CA_DIR}/hijack-ca.crt" \
    -CAkey "${HIJACK_PROXY_CA_DIR}/hijack-ca.key" \
    -CAcreateserial \
    -CAserial "${HIJACK_PROXY_CA_SERIAL_PATH}" \
    -out "${HIJACK_PROXY_CERT_PATH}" \
    -days 3650 \
    -sha256 \
    -extfile "${HIJACK_PROXY_CERT_EXT_PATH}" || return 1

  chmod 600 "${HIJACK_PROXY_KEY_PATH}"
  chmod 644 "${HIJACK_PROXY_CERT_PATH}" "${HIJACK_PROXY_CERT_EXT_PATH}"
  rm -f "${HIJACK_PROXY_CSR_PATH}" "${HIJACK_PROXY_CA_SERIAL_PATH}"
}

ensure_hosts_entry() {
  local domain="$1"
  if grep -qE "^[[:space:]]*127\\.0\\.0\\.2[[:space:]]+${domain}([[:space:]]|$)" /etc/hosts; then
    runtime_init_log "dns hijack host already exists: ${domain}"
    return 0
  fi
  echo "127.0.0.2 ${domain}" >> /etc/hosts
}

normalize_dns_domains() {
  printf '%s' "$1" | tr ',' ' ' | xargs -n1 | sort -u | xargs
}

contains_domain() {
  local domains="$1"
  local target="$2"
  local domain=""
  for domain in ${domains}; do
    if [ "${domain}" = "${target}" ]; then
      return 0
    fi
  done
  return 1
}

read_current_dns_domains() {
  if [ ! -f "${HIJACK_PROXY_DOMAINS_PATH}" ]; then
    return 0
  fi
  normalize_dns_domains "$(cat "${HIJACK_PROXY_DOMAINS_PATH}")"
}

remove_hosts_entry() {
  local domain="$1"
  local tmp_file=""
  if ! awk -v domain="${domain}" '$1 == "127.0.0.2" && $2 == domain { found = 1 } END { exit found ? 0 : 1 }' /etc/hosts; then
    return 0
  fi

  runtime_init_log "remove stale dns hijack host: ${domain}"
  tmp_file="$(mktemp)"
  awk -v domain="${domain}" '!($1 == "127.0.0.2" && $2 == domain)' /etc/hosts > "${tmp_file}" || {
    rm -f "${tmp_file}"
    return 1
  }
  cat "${tmp_file}" > /etc/hosts || {
    rm -f "${tmp_file}"
    return 1
  }
  rm -f "${tmp_file}"
}

remove_stale_hosts_entries() {
  local current_domains="$1"
  local requested_domains="$2"
  local domain=""
  for domain in ${current_domains}; do
    if ! contains_domain "${requested_domains}" "${domain}"; then
      remove_hosts_entry "${domain}" || return 1
    fi
  done
}

wait_hijack_proxy_stopped() {
  local i=""
  for i in {1..20}; do
    if ! pgrep -f "${HIJACK_PROXY_BINARY}" >/dev/null 2>&1; then
      if [ "${i}" -gt 1 ]; then
        runtime_init_log "hijack proxy stopped, attempts=${i}"
      fi
      return 0
    fi
    sleep 0.05
  done
  runtime_init_log "hijack proxy stop timeout, attempts=20"
  return 1
}

wait_hijack_proxy_running() {
  local i=""
  for i in {1..20}; do
    if pgrep -f "${HIJACK_PROXY_BINARY}" >/dev/null 2>&1; then
      if [ "${i}" -gt 1 ]; then
        runtime_init_log "hijack proxy running, attempts=${i}"
      fi
      return 0
    fi
    sleep 0.05
  done
  runtime_init_log "hijack proxy start timeout, attempts=20"
  return 1
}

restart_hijack_proxy_if_running() {
  local pids
  pids="$(pgrep -f "${HIJACK_PROXY_BINARY}" || true)"
  if [ -z "${pids}" ]; then
    return 0
  fi

  runtime_init_log "restart hijack proxy for updated dns hosts, pids=${pids}"
  pkill -f "${HIJACK_PROXY_BINARY}" || return 1
  if ! wait_hijack_proxy_stopped; then
    runtime_init_log "hijack proxy still running after graceful stop, force kill"
    pkill -9 -f "${HIJACK_PROXY_BINARY}" || return 1
  fi
}

if ! is_hijack_proxy_enabled; then
  runtime_init_log "HIJACK_PROXY_ENABLE is disabled, skip dns hijack proxy"
  runtime_init_log_duration_ms "hijack_proxy_total" "${script_start_ms}"
  runtime_init_skipped "hijack proxy disabled"
fi

if [ ! -x "${HIJACK_PROXY_BINARY}" ]; then
  runtime_init_log "hijack proxy binary not found: ${HIJACK_PROXY_BINARY}"
  runtime_init_log_duration_ms "hijack_proxy_total" "${script_start_ms}"
  runtime_init_failed "hijack proxy binary not available"
fi

stage_start_ms="$(runtime_init_now_ms)"
dns_domains="${HIJACK_DNS_HOSTS:-}"
if [ -z "${dns_domains// }" ]; then
  dns_domains="${DEFAULT_HIJACK_DNS_HOSTS}"
  runtime_init_log "HIJACK_DNS_HOSTS is empty, use default: ${dns_domains}"
fi

runtime_init_log "init dns hijack hosts: ${dns_domains}"
requested_dns_domains="$(normalize_dns_domains "${dns_domains}")"
current_dns_domains="$(read_current_dns_domains)"
dns_domains="${requested_dns_domains}"

if [ -z "${dns_domains// }" ]; then
  runtime_init_log_duration_ms "hijack_proxy_resolve_domains" "${stage_start_ms}"
  runtime_init_log_duration_ms "hijack_proxy_total" "${script_start_ms}"
  runtime_init_failed "no valid hijack dns domains found"
fi
runtime_init_log_duration_ms "hijack_proxy_resolve_domains" "${stage_start_ms}"

stage_start_ms="$(runtime_init_now_ms)"
if [ "${current_dns_domains}" = "${dns_domains}" ]; then
  runtime_init_log "dns hijack hosts unchanged, skip cert and hosts preparation"
  runtime_init_log_duration_ms "hijack_proxy_prepare_cert_hosts" "${stage_start_ms}"
else
  runtime_init_log "dns hijack hosts changed, prepare cert and hosts"
  if ! generate_hijack_proxy_cert "${dns_domains}"; then
    runtime_init_log_duration_ms "hijack_proxy_prepare_cert_hosts" "${stage_start_ms}"
    runtime_init_log_duration_ms "hijack_proxy_total" "${script_start_ms}"
    runtime_init_failed "generate hijack proxy cert failed"
  fi

  for domain in ${dns_domains}; do
    if ! ensure_hosts_entry "${domain}"; then
      runtime_init_log_duration_ms "hijack_proxy_prepare_cert_hosts" "${stage_start_ms}"
      runtime_init_log_duration_ms "hijack_proxy_total" "${script_start_ms}"
      runtime_init_failed "update /etc/hosts for ${domain} failed"
    fi
  done

  if ! remove_stale_hosts_entries "${current_dns_domains}" "${dns_domains}"; then
    runtime_init_log_duration_ms "hijack_proxy_prepare_cert_hosts" "${stage_start_ms}"
    runtime_init_log_duration_ms "hijack_proxy_total" "${script_start_ms}"
    runtime_init_failed "remove stale hijack dns hosts failed"
  fi
  runtime_init_log_duration_ms "hijack_proxy_prepare_cert_hosts" "${stage_start_ms}"
fi

stage_start_ms="$(runtime_init_now_ms)"
if pgrep -f "${HIJACK_PROXY_BINARY}" >/dev/null 2>&1; then
  if ! restart_hijack_proxy_if_running; then
    runtime_init_log_duration_ms "hijack_proxy_restart_existing" "${stage_start_ms}"
    runtime_init_log_duration_ms "hijack_proxy_total" "${script_start_ms}"
    runtime_init_failed "restart hijack proxy failed"
  fi
fi
runtime_init_log_duration_ms "hijack_proxy_restart_existing" "${stage_start_ms}"

stage_start_ms="$(runtime_init_now_ms)"
session_present="false"
if [ -n "${SESSION_ID:-}" ]; then
  session_present="true"
fi
keychain_present="false"
if [ -n "${HIJACK_PROXY_KEYCHAIN_KEY:-}" ]; then
  keychain_present="true"
fi
runtime_init_log "start dns hijack proxy, session_present=${session_present}, keychain_present=${keychain_present}, no_proxy=${NO_PROXY:-${no_proxy:-}}"
"${HIJACK_PROXY_BINARY}" </dev/null >/proc/1/fd/1 2>/proc/1/fd/2 &
disown || true
if ! wait_hijack_proxy_running; then
  runtime_init_log_duration_ms "hijack_proxy_start_process" "${stage_start_ms}"
  runtime_init_log_duration_ms "hijack_proxy_total" "${script_start_ms}"
  runtime_init_failed "hijack proxy exited after start"
fi
runtime_init_log_duration_ms "hijack_proxy_start_process" "${stage_start_ms}"

printf '%s' "${dns_domains}" > "${HIJACK_PROXY_DOMAINS_PATH}"
runtime_init_log "dns hijack proxy start command submitted"

runtime_init_log_duration_ms "hijack_proxy_total" "${script_start_ms}"
runtime_init_success "hijack proxy started"
