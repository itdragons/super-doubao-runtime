#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

skills_dir="${RUNTIME_INIT_RUNTIME_PATH}/skills"
# 官方包本次解压产物的暂存目录（与真实 skills/ 同文件系统，便于 Go 侧 rename 搬运）。
# 真实目录的清空/搬运/差集删除统一由 Go 的 commitSkills 完成，本脚本不再直接改动 skills/。
tmp_official_dir="${RUNTIME_INIT_RUNTIME_PATH}/skills.tmp/official"
workspace_skills="${RUNTIME_INIT_WORKSPACE}/skills"
tmp_file="$(mktemp /tmp/skills.zip.XXXXXX)"

cleanup_tmp_artifacts() {
  rm -f "${tmp_file}"
}

now_ms() {
  date +%s%3N
}

log_duration_ms() {
  local stage_name="$1"
  local start_ms="$2"
  local end_ms
  end_ms="$(now_ms)"
  runtime_init_log "timing, stage=${stage_name}, duration_ms=$((end_ms - start_ms))"
}

log_skills_archive_size() {
  local archive_path="$1"
  local source_name="$2"
  local size_bytes

  if size_bytes="$(stat -c '%s' "${archive_path}" 2>/dev/null)"; then
    runtime_init_log "skills archive size, source=${source_name}, path=${archive_path}, size_bytes=${size_bytes}"
    return 0
  fi

  runtime_init_log "skills archive size unavailable, source=${source_name}, path=${archive_path}"
}

remove_workspace_skills_archive() {
  local archive_path="$1"
  local stage_start_ms

  if [ ! -f "${archive_path}" ]; then
    runtime_init_log "workspace skills.zip already absent, skip cleanup: ${archive_path}"
    return 0
  fi

  stage_start_ms="$(now_ms)"
  runtime_init_log "remove consumed workspace skills.zip: ${archive_path}"
  if runtime_init_run_privileged rm -f "${archive_path}"; then
    log_duration_ms "remove_workspace_skills_zip" "${stage_start_ms}"
    return 0
  fi

  log_duration_ms "remove_workspace_skills_zip_failed" "${stage_start_ms}"
  runtime_init_log "remove workspace skills.zip failed, continue for compatibility: ${archive_path}"
  return 0
}

extract_skills_archive() {
  local archive_path="$1"
  local source_name="$2"
  local stage_start_ms

  log_skills_archive_size "${archive_path}" "${source_name}"

  stage_start_ms="$(now_ms)"
  runtime_init_log "reset tmp official dir before applying ${source_name}: ${tmp_official_dir}"
  runtime_init_run_privileged rm -rf "${tmp_official_dir}" || runtime_init_failed "reset tmp official dir failed"
  runtime_init_run_privileged mkdir -p "${tmp_official_dir}" || runtime_init_failed "create tmp official dir failed"
  log_duration_ms "reset_tmp_official_dir" "${stage_start_ms}"

  stage_start_ms="$(now_ms)"
  runtime_init_log "extract skills archive into tmp official dir from ${source_name}"
  if ! unzip -o "${archive_path}" -d "${tmp_official_dir}"; then
    runtime_init_log "unzip ${source_name} failed"
    return 1
  fi
  log_duration_ms "unzip_skills_archive" "${stage_start_ms}"

  if [ -z "$(find "${tmp_official_dir}" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    runtime_init_log "skills archive is empty after extraction: ${source_name}"
  fi

  # 权限模型：保证 user 可读 + 去写位、保留执行位（等价 chmod -R a-w，保留 r/x）。
  # 不修改属主（不 chown 给 user），真实目录搬运由 Go 完成。
  stage_start_ms="$(now_ms)"
  runtime_init_run_privileged chmod -R a-w,a+rX "${tmp_official_dir}" || runtime_init_failed "chmod tmp official skills failed"
  log_duration_ms "chmod_tmp_official_dir" "${stage_start_ms}"
  return 0
}

trap cleanup_tmp_artifacts EXIT

# Skills depend on the runtime workspace symlink, because callers expect
# ${RUNTIME_INIT_WORKSPACE}/skills to point to the runtime skills directory.
if ! runtime_init_workspace_is_ready; then
  runtime_init_log "workspace is not ready, skip load_session_skills"
  runtime_init_skipped "workspace is not ready"
fi

runtime_init_log "prepare runtime skills dir: ${skills_dir}"
stage_start_ms="$(now_ms)"
runtime_init_run_privileged mkdir -p "${skills_dir}" || runtime_init_failed "create runtime skills dir failed"
# 仅确保 skills 根目录本身可写可遍历（便于 Go 侧 add/remove 子目录）；不递归 chown/chmod，
# 避免破坏 Go 管理的 root 属主、只读的官方/个人 skill 内容。
runtime_init_run_privileged chmod 777 "${skills_dir}" || runtime_init_failed "chmod runtime skills dir failed"
log_duration_ms "prepare_runtime_skills_dir" "${stage_start_ms}"

stage_start_ms="$(now_ms)"
runtime_init_log "bind workspace skills symlink, link=${workspace_skills}, target=${skills_dir}"
runtime_init_replace_symlink "${skills_dir}" "${workspace_skills}" || runtime_init_failed "replace workspace skills symlink failed"
log_duration_ms "bind_workspace_skills_symlink" "${stage_start_ms}"

workspace_skills_archive="${RUNTIME_INIT_WORKSPACE_ROOT}/skills.zip"
if [ -f "${workspace_skills_archive}" ]; then
  runtime_init_log "workspace skills.zip found, extract directly from workspace mount"
  if extract_skills_archive "${workspace_skills_archive}" "workspace skills.zip"; then
    remove_workspace_skills_archive "${workspace_skills_archive}"
    runtime_init_success "session skills loaded from workspace"
  fi
  remove_workspace_skills_archive "${workspace_skills_archive}"
  runtime_init_log "unzip workspace skills.zip failed, fallback to remote download"
else
  runtime_init_log "workspace skills.zip not found, fallback to remote download"
fi

if [ -z "${SKILLS_DOWNLOAD_URL:-}" ] || [ -z "${SKILLS_DOWNLOAD_TOKEN:-}" ]; then
  runtime_init_log "skills fallback download is not configured"
  runtime_init_skipped "skills download fallback is not configured"
fi

curl_args=(--noproxy '*' -fL -H "Authorization: ${SKILLS_DOWNLOAD_TOKEN}" "${SKILLS_DOWNLOAD_URL}" -o "${tmp_file}")
if [ -n "${PPE_ENV:-}" ]; then
  curl_args+=(-H "X-Use-Ppe: 1" -H "X-Tt-Env: ${PPE_ENV}")
fi
if [ -n "${CLUSTER_ENV:-}" ]; then
  curl_args+=(-H "cluster: ${CLUSTER_ENV}")
fi

attempt=1
while [ "${attempt}" -le 5 ]; do
  runtime_init_log "download fallback skills archive attempt ${attempt}/5"
  rm -f "${tmp_file}"
  stage_start_ms="$(now_ms)"
  if curl "${curl_args[@]}"; then
    log_duration_ms "download_fallback_skills_zip" "${stage_start_ms}"
  else
    log_duration_ms "download_fallback_skills_zip_failed" "${stage_start_ms}"
    attempt=$((attempt + 1))
    if [ "${attempt}" -le 5 ]; then
      sleep 1
    fi
    continue
  fi

  if extract_skills_archive "${tmp_file}" "fallback skills.zip"; then
    rm -f "${tmp_file}"
    runtime_init_success "session skills loaded from fallback download"
  fi
  attempt=$((attempt + 1))
  if [ "${attempt}" -le 5 ]; then
    sleep 1
  fi
done

rm -f "${tmp_file}"
runtime_init_skipped "skills fallback download failed"
