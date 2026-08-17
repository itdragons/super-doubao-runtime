#!/bin/bash

set -euo pipefail

# 重定输出到日志文件
if [ -n "${MCP_VM_SERVER_LOG_PATH:-}" ]; then
    touch "${MCP_VM_SERVER_LOG_PATH}"
    chown user:user "${MCP_VM_SERVER_LOG_PATH}"
    exec &> >(tee -a "${MCP_VM_SERVER_LOG_PATH}")
fi

PROFILE="${MCP_VM_PROFILE:-all}"
# 统一镜像入口：默认走 all，命中 ci profile 时尽早转发到专用入口。
echo "entrypoint(all): MCP_VM_PROFILE=${PROFILE} ENABLE_CI_SERVER=${ENABLE_CI_SERVER:-true} WAIT_PORTS=${WAIT_PORTS:-<empty>}"
case "${PROFILE}" in
  all)
    ;;
  ci)
    echo "entrypoint(all): routing to ci entrypoint ${RUNTIME_PATH}/entrypoint_ci.sh"
    exec "${RUNTIME_PATH}/entrypoint_ci.sh" "$@"
    ;;
  *)
    echo "Unknown MCP_VM_PROFILE=${PROFILE}" >&2
    exit 1
    ;;
esac

normalize_wait_ports() {
  local wait_ports="${WAIT_PORTS:-8091}"
  local original_wait_ports="${WAIT_PORTS:-<empty>}"

  # all 模式下 nginx 默认等待 8091；如果启用了 CI server，再补上 9999。
  if [ "${ENABLE_CI_SERVER:-true}" = "true" ]; then
    case ",${wait_ports}," in
      *,9999,*)
        ;;
      *)
        wait_ports="${wait_ports},9999"
        ;;
    esac
  fi

  export WAIT_PORTS="${wait_ports}"
  echo "entrypoint(all): normalized WAIT_PORTS from ${original_wait_ports} to ${WAIT_PORTS}"
}

normalize_wait_ports

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_INIT_DIR="${SCRIPT_DIR}/runtime_init"
source "${RUNTIME_INIT_DIR}/common.sh"
RESOURCE_INIT_DIR="${RESOURCE_INIT_DIR:-/tmp/resource-init}"
RESOURCE_INIT_SUMMARY_OUTPUT=""

create_symlink() {
  local target_path="$1"
  local link_path="$2"
  echo "create_symlink: target_path=$target_path ; link_path=$link_path"

  if [ -d "$link_path" ]; then
      echo "错误: $link_path 是目录" >&2
  elif [ -f "$link_path" ]; then
      echo "错误: $link_path 是文件" >&2
  elif [ -L "$link_path" ]; then
      echo "错误: $link_path 已存在符号链接" >&2
  else
      echo "创建符号链接: $target_path -> $link_path"
      ln -sfT "$target_path" "$link_path"
  fi
}

USER_HOME=/home/user

sync_browser_proxy_server_env() {
  if [ -z "${PROXY:-}" ]; then
    echo "sync_browser_proxy_server_env: PROXY is empty, skip"
    return 0
  fi

  export PROXY_SERVER="${PROXY}"
  echo "sync_browser_proxy_server_env: PROXY_SERVER synced from PROXY"
}

export_shell_http_proxy_env() {
  if [ -z "${PROXY:-}" ]; then
    echo "export_shell_http_proxy_env: PROXY is empty, skip"
    return 0
  fi
  runtime_init_validate_proxy_url "${PROXY}"

  local no_proxy_value="localhost,127.0.0.1,::1"
  if [ -n "${NO_PROXY_DOMAINS:-}" ]; then
    no_proxy_value="${no_proxy_value},${NO_PROXY_DOMAINS}"
  fi
  runtime_init_validate_no_proxy_list "${no_proxy_value}"

  export http_proxy="${PROXY}"
  export https_proxy="${PROXY}"
  export HTTP_PROXY="${PROXY}"
  export HTTPS_PROXY="${PROXY}"
  export no_proxy="${no_proxy_value}"
  export NO_PROXY="${no_proxy_value}"
  echo "export_shell_http_proxy_env: shell proxy env exported, no_proxy=${no_proxy_value}"
}

start_official_npm_cli_install_async() {
  local start_seconds=$SECONDS
  if [ -z "${MCP_VM_OFFICIAL_NPM_CLI_INSTALL_CONFIG_B64:-}" ]; then
    echo "official npm cli installer: config absent; skip"
    return 0
  fi
  echo "official npm cli installer: config present; submit asynchronously"
  (
    set +e
    bash "${RUNTIME_INIT_DIR}/official_npm_cli_install.sh"
    local install_status=$?
    echo "official npm cli installer: finished in $((SECONDS - start_seconds))s, status=${install_status}"
    exit "${install_status}"
  ) &
  OFFICIAL_NPM_CLI_INSTALL_PID=$!
  echo "official npm cli installer submitted asynchronously, pid=${OFFICIAL_NPM_CLI_INSTALL_PID}"
}

wait_official_npm_cli_install() {
  if [ -z "${OFFICIAL_NPM_CLI_INSTALL_PID:-}" ]; then
    return 0
  fi
  echo "official npm cli installer: wait after service startup, pid=${OFFICIAL_NPM_CLI_INSTALL_PID}"
  if wait "${OFFICIAL_NPM_CLI_INSTALL_PID}"; then
    echo "official npm cli installer: completed after service startup"
    return 0
  fi
  local wait_status=$?
  if [ "${wait_status}" -gt 128 ]; then
    echo "official npm cli installer: wait interrupted, status=${wait_status}"
    return 0
  fi
  echo "official npm cli installer: failed after service startup, status=${wait_status}; continue startup"
  return 0
}

wait_service_startup_before_official_npm_cli_wait() {
  if [ -z "${OFFICIAL_NPM_CLI_INSTALL_PID:-}" ]; then
    return 0
  fi
  local health_url="http://127.0.0.1:${VM_SERVER_PORT}/vm/exec/api/v3/health"
  local timeout_seconds="${OFFICIAL_NPM_CLI_INSTALL_SERVICE_READY_TIMEOUT_SECONDS:-30}"
  local deadline=$((SECONDS + timeout_seconds))
  echo "official npm cli installer: wait service startup before install wait, health_url=${health_url}, timeout=${timeout_seconds}s"
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    if curl -fsS --max-time 2 "${health_url}" >/dev/null 2>&1; then
      echo "official npm cli installer: service startup detected before install wait"
      return 0
    fi
    sleep 1
  done
  echo "official npm cli installer: service startup wait timeout before install wait; continue"
  return 0
}

run_runtime_init_script() {
  local script_name="$1"
  local script_path="${RUNTIME_INIT_DIR}/${script_name}"
  echo "run_runtime_init_script: ${script_name}"
  if [ ! -f "${script_path}" ]; then
    echo "runtime init script not found: ${script_path}" >&2
    exit 1
  fi
  bash "${script_path}"
}

run_runtime_init_script_best_effort() {
  local script_name="$1"
  if run_runtime_init_script "${script_name}"; then
    return 0
  fi
  echo "run_runtime_init_script_best_effort: ${script_name} failed, continue startup"
  return 0
}

start_persistent_sync() {
  if [ -z "${MCP_VM_PERSISTENT_SYNC_CONFIG_B64:-}" ]; then
    echo "persistent sync: config absent; skip"
    return 0
  fi
  bash "${RUNTIME_INIT_DIR}/persistent_sync.sh" restore &
  PERSISTENT_SYNC_PID=$!
  echo "persistent sync restore submitted asynchronously, pid=${PERSISTENT_SYNC_PID}"
}

resource_init_summary_output_path() {
	local mode="$2"
	printf '%s/%s_resource_init_summary.json' "${RESOURCE_INIT_DIR}" "${mode}"
}

run_resource_init_if_needed() {
	RESOURCE_INIT_SUMMARY_OUTPUT=""
	local manifest_path="${MCP_VM_RESOURCE_INIT_MANIFEST_PATH:-}"
	if [ -z "${manifest_path}" ] || [ ! -s "${manifest_path}" ]; then
		echo "resource init manifest is empty or unavailable, skip"
		return 0
	fi
	# manifest 是一次性输入。RETURN 覆盖正常返回，EXIT 覆盖 set -e 在命令替换等
	# 场景直接终止 shell；%q 将 local 路径固化进 trap，避免 EXIT 时变量已离开作用域。
	local cleanup_manifest_command
	printf -v cleanup_manifest_command \
		'trap - RETURN EXIT; rm -f -- %q || echo %q >&2' \
		"${manifest_path}" "resource init manifest cleanup failed: ${manifest_path}"
	trap "${cleanup_manifest_command}" RETURN EXIT

	local workspace="${RUNTIME_PATH}/workspace"
	mkdir -p "${RESOURCE_INIT_DIR}"
	if [ -L "${RESOURCE_INIT_DIR}" ]; then
		echo "resource init dir must not be a symlink: ${RESOURCE_INIT_DIR}" >&2
		return 1
	fi
	chown root:root "${RESOURCE_INIT_DIR}"
	chmod 0700 "${RESOURCE_INIT_DIR}"
	local manifest_id summary_output
	manifest_id="$(resource-loader manifest-id --manifest "${manifest_path}")"
	summary_output="$(resource_init_summary_output_path "${manifest_id}" "entrypoint")"
	echo "resource init start, manifest=${manifest_path}, manifest_id=${manifest_id}, workspace=${workspace}"
	local apply_status=0
	if resource-loader apply --manifest "${manifest_path}" --workspace "${workspace}" --mode entrypoint --summary-output "${summary_output}"; then
		:
	else
		apply_status=$?
	fi
	if [ "${apply_status}" -ne 0 ]; then
		return "${apply_status}"
	fi
	RESOURCE_INIT_SUMMARY_OUTPUT="${summary_output}"
	echo "resource init finished, summary=${summary_output}"
}

configure_lark_cli_resource_path() {
	local asset_id="${LARK_CLI_ASSET_ID:-}"
	unset LARK_CLI_RESOURCE_PATH
	if [ -z "${asset_id}" ] || [ -z "${RESOURCE_INIT_SUMMARY_OUTPUT}" ]; then
		echo "lark cli resource summary is unavailable, keep legacy URL chain"
		return 0
	fi
	if LARK_CLI_RESOURCE_PATH="$(resource-loader artifact-path --summary-output "${RESOURCE_INIT_SUMMARY_OUTPUT}" --asset-id "${asset_id}")"; then
		export LARK_CLI_RESOURCE_PATH
		echo "lark cli resource path resolved from summary: ${LARK_CLI_RESOURCE_PATH}"
		return 0
	fi
	echo "lark cli asset ${asset_id} has no usable output path, keep legacy URL chain"
}

init_browser_config() {
  echo "init_browser_config"
  local start_marker="# >>> mcp_vm_server browser config start >>>"
  local end_marker="# <<< mcp_vm_server browser config end <<<"
  local tmp_file filtered_file
  tmp_file="$(mktemp)"
  filtered_file="$(mktemp)"
  touch /root/.bashrc
  awk -v start="${start_marker}" -v end="${end_marker}" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    skip != 1 { print }
  ' /root/.bashrc > "${filtered_file}"
  cat "${filtered_file}" > "${tmp_file}"
  {
    echo "${start_marker}"
    echo "export BROWSER_EXTRA_ARGS=\"${BROWSER_EXTRA_ARGS:-} --disable-sync\""
    echo "${end_marker}"
  } >> "${tmp_file}"
  mv "${tmp_file}" /root/.bashrc
  rm -f "${filtered_file}"
}

start_vm_runtime_hook() {
  if [ -z "${VM_RUNTIME_HOOK_INTERNAL_TOKEN:-}" ]; then
    VM_RUNTIME_HOOK_INTERNAL_TOKEN="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    export VM_RUNTIME_HOOK_INTERNAL_TOKEN
  fi

  "${SCRIPT_DIR}/vm_runtime_hook" --host 127.0.0.1 --port 10080 &
  VM_RUNTIME_HOOK_PID=$!
  echo "vm_runtime_hook started asynchronously, pid=${VM_RUNTIME_HOOK_PID}"
}

run_runtime_init_script ensure_cookie_dir_owner.sh
run_runtime_init_script init_workspace.sh
run_runtime_init_script init_shell_http_proxy.sh
export_shell_http_proxy_env
start_official_npm_cli_install_async
run_runtime_init_script prepare_downloads_dir.sh
run_runtime_init_script ensure_data_dir_permission.sh
start_persistent_sync
# 官方 + 个人 skills 冷加载：复用 Go 内核（root 身份、一次性进程）。
# load_session_skills.sh 现在只负责把官方包解到 skills.tmp/official，真实落地由 Go commit；
# 因此 entrypoint 不能直接调用该脚本，否则会先消费 workspace skills.zip，导致 sync-skills 无法 commit。
"${SCRIPT_DIR}/vm_runtime_hook" sync-skills || echo "[entrypoint] skills cold sync failed (best-effort)"
("${SCRIPT_DIR}/vm_runtime_hook" audit-skill-permissions || echo "[entrypoint] skill permission audit failed (best-effort)") &
SKILL_PERMISSION_AUDIT_PID=$!
echo "skill permission audit submitted asynchronously, pid=${SKILL_PERMISSION_AUDIT_PID}"
run_resource_init_if_needed
configure_lark_cli_resource_path
run_runtime_init_script_best_effort init_lark_cli.sh
run_runtime_init_script_best_effort rebuild_lark_cli.sh
init_browser_config
start_vm_runtime_hook

bash "${RUNTIME_INIT_DIR}/start_hijack_proxy.sh" &
HIJACK_PROXY_INIT_PID=$!
echo "hijack proxy start script submitted asynchronously, pid=${HIJACK_PROXY_INIT_PID}"

# nginx
envsubst '${VM_SERVER_PORT} ${CI_PYTHON_SERVER_PORT}' < /tmp/nginx.mcp_vm_server.conf.template > /opt/gem/nginx/nginx.mcp_vm_server.conf

# 启动 aio & gem browser
sync_browser_proxy_server_env
/opt/gem/run.sh &
RUN_GEM_PID=$!
child_pid="${RUN_GEM_PID}"
echo "start gem. pid=$RUN_GEM_PID"


# 转发信号给子进程
forward_signal() {
  sig="$1"
  echo "Entrypoint received SIG$sig, forwarding..."
  if [ -n "${VM_RUNTIME_HOOK_PID:-}" ]; then
    kill "-$sig" "${VM_RUNTIME_HOOK_PID}" 2>/dev/null || true
  fi
  if [ -n "${PERSISTENT_SYNC_PID:-}" ]; then
    kill "-$sig" "${PERSISTENT_SYNC_PID}" 2>/dev/null || true
  fi
  if [ -n "${OFFICIAL_NPM_CLI_INSTALL_PID:-}" ]; then
    kill "-$sig" "${OFFICIAL_NPM_CLI_INSTALL_PID}" 2>/dev/null || true
  fi
  # /opt/gem/run.sh ends with `exec supervisord`, so child_pid becomes the
  # supervisord pid. Signal that pid directly and let supervisord stop programs.
  kill "-$sig" "$child_pid" 2>/dev/null || true
}

trap 'forward_signal TERM' SIGTERM
trap 'forward_signal INT'  SIGINT
trap 'forward_signal QUIT' SIGQUIT

wait_service_startup_before_official_npm_cli_wait
wait_official_npm_cli_install

set +e
wait "$RUN_GEM_PID"
wait_status=$?
if [ "$wait_status" -gt 128 ]; then
  # The first wait is interrupted by the trapped signal. Keep PID 1 alive until
  # supervisord finishes stopping its managed processes.
  wait "$RUN_GEM_PID"
  exit $?
fi
exit "$wait_status"
