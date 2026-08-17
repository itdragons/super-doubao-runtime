# apps +init

`+init` 初始化应用的代码（clone 仓库、scaffold/同步源码、拉取本地环境变量）。运行时命令事实以 `lark-cli apps +init --help` 为准。

## 何时用

用于初始化应用工作区，并准备后续提交和发布所需的项目结构。已有 HTML / 静态资源 / 前端代码目录可作为 `--source-path` 传给本命令，由 `+init` 内部完成代码接入。

## 命令骨架

- 必填：`--app-id`。
- 可选：`--dir`，clone 目标目录；省略时默认 `./<app-id>`。
- 需要把已有 HTML / 静态页面 / 前端代码接入应用工作区时，传 `--source-path`；它是已生成代码目录，必须是目录，目录根下应包含 `index.html`。传入后，`+init` 会把该目录内容接入初始化后的应用工作区。
- 固定 checkout 分支：`sprint/default`。
- `+init` 会初始化 Git 凭证、clone 仓库、切到工作分支并生成/同步本地项目。

## 示例

```bash
lark-cli apps +init --app-id app_xxx --dir ./my-app
lark-cli apps +init --app-id app_xxx --dir /absolute/path/my-app --source-path ./generated-html
lark-cli apps +init --app-id app_xxx --dir ./my-app --dry-run
```

## 输出契约

- 真跑时 stdout 是 JSON envelope；stderr 会有 `->` / `→` 进度行。成功读 stdout，失败解析 stderr 末尾的 JSON 错误。
- 成功普通初始化读取 `data.clone_path`、`branch`、`committed`、`pushed`；`repository_url` 已脱敏，不要当凭据使用。
- `scaffold=already_initialized` 表示目录已初始化：跳过 clone/scaffold/commit，但仍会执行一次 env-pull 刷新本地环境变量（输出含 `env_pulled`，成功时含 `env_file`，失败时含 `env_pull_error` 且退出码仍为 0）；此时通常没有 `repository_url` / `branch`。
- `--dry-run` 只打印计划，不执行 git / npx；若输出含 `dir_error`，真跑前先让用户换目录。

## Agent 规则

- 目标目录必须不存在、为空目录，或已含 `.spark/meta.json` 且其 app_id 与 `--app-id` 一致的已初始化仓库。
- `--dir` 是应用工作区目标目录，建议使用不存在或空目录；`--source-path` 是已有 HTML 代码目录，二者不要混用。
- 普通二次开发 / 沙箱恢复只需要 `--app-id` 和 `--dir`；只有要导入一份新的 HTML 目录时才传 `--source-path`。
- 需要把已有 HTML / 静态页面 / 前端代码导入工作区时，传 `--source-path`。
- 不要手动搬运 `--source-path` 里的文件；由 `+init` 内部接入到合适位置。
- 目标目录已含 `.spark/meta.json` 时，`+init` 会跳过 clone/scaffold，但仍执行一次 env-pull 刷新本地环境变量；告知用户“仓库已初始化，本地环境变量已刷新，可直接开发”，不要误报失败或重复 clone。
- `+init` 输出没有必要原样复述；告诉用户 clone path、分支和下一步即可。
- 新建应用做本地初始化时，若选定的目标目录已存在，不要复用，改用一个不冲突的目录名（已预授权”放手做”时自动追加后缀如 `-2`；否则向用户确认目录名）。
