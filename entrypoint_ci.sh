#! /usr/bin/env bash

create_dir_and_symlink() {
  local target_path="$1"
  local link_path="$2"

  mkdir -p "$target_path"
  chown user:user "$target_path"
  chmod 777 "$target_path"
  create_symlink "$target_path" "$link_path"
}

# function: 创建软链接
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
      ln -s "$target_path" "$link_path"
  fi
}

init_workspace() {
  echo "init_workspace"
}

init_http_proxy() {
  # 如果传入了PROXY环境变量，则使用PROXY作为代理
  if [ -n "$PROXY" ]; then
    echo "PROXY=${PROXY}, init_http_proxy"
    echo "export http_proxy=\"${PROXY}\"" >> ~/.bashrc
    echo "export https_proxy=\"${PROXY}\"" >> ~/.bashrc
    echo "export HTTP_PROXY=\"${PROXY}\"" >> ~/.bashrc
    echo "export HTTPS_PROXY=\"${PROXY}\"" >> ~/.bashrc
    echo "export no_proxy=\"localhost,127.0.0.1,::1\"" >> ~/.bashrc

    . ~/.bashrc
  fi
}

init_http_proxy

# ci profile 约定直接对外监听 8080，不复用底包中的 9999 默认值。
export CI_PYTHON_SERVER_PORT="8080"
echo "entrypoint(ci): forcing CI_PYTHON_SERVER_PORT=${CI_PYTHON_SERVER_PORT}"

cd ${RUNTIME_PATH}
PY_ARGS="$@"
echo "PY_ARGS=$PY_ARGS"

if [ "${ENABLE_CI_SERVER:-true}" != "true" ]; then
  echo "Skip starting python server because ENABLE_CI_SERVER=${ENABLE_CI_SERVER}"
  exit 0
fi

# 使用gosu，以user用户启动进程 且 继承当前进程的 ulimit fd上限（1024 -> 2048）
# 暂时不使用 supervisord
exec gosu user /opt/python3.12/bin/python3.12 ${RUNTIME_PATH}/python_server/start_server.py "$@"
