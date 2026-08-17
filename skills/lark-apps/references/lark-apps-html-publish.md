# apps +html-publish

把本地 HTML 文件或静态目录发布为应用。运行时命令事实以 `lark-cli apps +html-publish --help` 为准。

## 何时用

用于把已经存在的本地 HTML 文件或静态产物目录发布为应用。它不负责生成 HTML 内容。`+html-publish` 会上传产物并创建发布，返回 `release_id` 后用 `+release-get` 查询发布状态。

## Workflow

```text
+create --app-type html
-> +html-publish --app-id <app_id> --path <html_path>
-> +release-get --app-id <app_id> --release-id <release_id from html-publish>
```

## 命令骨架

- `+create` 必填：`--name`、`--app-type html`。
- `+html-publish` 必填：`--app-id`、`--path`。
- `+html-publish --path` 可以是单个文件或目录；入口必须是 `index.html`。
- `+html-publish` 可选：`--allow-sensitive`，跳过凭据文件扫描。
- `+release-get` 必填：`--app-id`、`--release-id`。

## 路径规则

- `--path` 传当前工作目录内的相对路径。
- 已有单文件时传 `./index.html`；文件名必须是 `index.html`。
- 已有目录时传 `./site`；目录根下必须有 `index.html`。
- 已经在 HTML 产物目录内时可以传 `.`。
- 不要在工作区根目录、用户主目录、仓库根目录等上层目录使用 `--path .`。
- 不要为了发布重复创建目录或复制文件；直接传已有 HTML 文件或目录。
- 不要传绝对路径；如果文件或目录不在当前工作目录内，先 `cd` 到 HTML 文件或目录的父目录，再传相对路径。

## 命令事实

- 客户端打包 tar.gz 上传。三条硬性大小限制，任一超限即被客户端拒绝、无法上传：单个 `.html` 文件 ≤ 10MB、打包后 tar.gz ≤ 20MB、未压缩候选文件总量 ≤ 200MB。
- `+html-publish` 输出包含 `data.release_id`；`release_id` 是后续 `+release-get` 的入参，用于轮询发布状态直到 `finished`。

## 发布前置门（第一步，先于任何其他动作）

收到发布意图后，第一个动作是量三个尺寸，不是读文件内容、不是打包：
1. 单个 `.html` ≤ 10MB / tar.gz ≤ 20MB / 未压缩总量 ≤ 200MB。
2. 任一超限 → 立即 STOP，把超限数字转述给用户，交还决定权。
3. 三项都通过 → 才进入上面的 workflow。

## 预览与发布边界

- 用户只说"用 HTML 写个 PPT/页面给我看看"时，先生成本地文件或目录，返回路径并问是否发布为可访问应用；不要默认创建应用或部署。
- 用户明确说"部署出去/发链接"时，才创建应用并发布。
- 用户要发布但没有 app_id 时，先 `+create --app-type html` 创建应用；应用名可从页面/站点主题生成，不要让用户手动提供 app_id。
- 重新部署同一个 HTML 应用时复用原 `app_id`，重新执行 `+html-publish` 并用新的 `release_id` 查询发布状态。

## 安全规则

默认会拦截 `.env`、`.npmrc`、`.aws/credentials` 等凭据文件。只有用户明确要发布凭据示例文件或教程内容时，才追加 `--allow-sensitive`；追加前先说明将包含哪些敏感候选文件。

## 常见失败

- `--path` 传了绝对路径：`--path` 只接受相对路径，传绝对路径会报 `--path must be a relative path within the current directory`。改用 `cd` + 相对路径，例如 `cd /target/dir && lark-cli apps +html-publish --path .`。
- 缺少 `index.html`：目录根放置 `index.html`，或单文件路径直接指向名为 `index.html` 的文件。
