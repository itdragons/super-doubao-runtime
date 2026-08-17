---
name: lark-apps
version: 1.0.0
description: 仅用于处理以下两类场景：1. 原样发布成品：用户已提供完整的 HTML 文件 / 静态资源目录 / 附件，诉求是上传、托管、发布或获取可分享链接；只原样部署，不生成、不改写内容。2. 本地自持代码：用户点名要求由当前 agent（豆包）在本地工作区亲自编写 / 修改 HTML 代码，或对 lark-cli 托管应用（app_type=modern_html）二次开发后发布。边界：从零生成网页应用、网页应用产物问答/编辑/分析、运营数据查询等需求不使用本 skill。
metadata:
  requires:
    bins: ["lark-cli"]
  cliHelp: "lark-cli apps --help"
---
# apps (v1)
应用属于用户资产。默认用 `--as user`。本 Skill 面向已有 HTML / 静态页面 / 前端代码发布为应用的链路。
> 进入本 skill 的前提，是已按 doubao-app-builder 的「工具链分流」判定为两类窄场景之一——**原样发布用户提供的成品**，或**用户点名要豆包本地亲自写 / 改代码**。是否该用本 skill 由那里决定。
>
> **越界即转 `doubao-app-builder` skill**：一旦发现当前诉求不属于这两类窄场景（要基于自然语言 / PRD / 截图生成网页、要常规生成 / 编辑 / 迭代应用、要问答 / 分析产物或查运营数据），**立即停止本 skill 的链路，改为调用 `doubao-app-builder` skill**，不要在本 skill 里硬做或降级处理。
## 能力边界
本 Skill 仅支持**纯 HTML + CSS + JS 产物**。以下类型**不在**本 Skill 覆盖范围内：
- React、Vue、Angular、Svelte 等前端框架项目
- Vite、Webpack 等构建工具项目
- SPA（单页应用）
- 全栈应用（含后端、数据库）
如果用户要发布框架项目或全栈应用，不要尝试走本 Skill 的链路——这些应交给 `doubao-app-builder` skill 处理（它支持前端框架与 Node 全栈），**改为调用 `doubao-app-builder` skill**。
## 场景分流
先判断用户场景，再读取对应 reference。不要把首次发布、二次开发和沙箱恢复混成同一条链路。
### 首次创建并发布 HTML 应用
```text
+create --app-type html
-> +html-publish --app-id <app_id> --path <html_path>
-> +release-get --app-id <app_id> --release-id <release_id from html-publish>
```
用户已有 HTML 产物、要发布成新应用时，读取 [`lark-apps-html-publish.md`](references/lark-apps-html-publish.md)。不要进入 `+init` / git 工作区链路。
`+html-publish --path` 传当前工作目录内的相对路径。已有单文件时传 `./index.html`；已有目录时传 `./site`；已经在 HTML 产物目录内时可以传 `.`。不要在工作区根目录、用户主目录、仓库根目录等上层目录使用 `--path .`。不要为了发布重复创建目录或复制文件。
### 二次开发 / 沙箱恢复
```text
+get --app-id <app_id>
-> 判断 app_type 是否为 modern_html，并检查本地代码状态
+init --app-id <app_id> --dir <workspace_dir>
-> 修改工作区代码
-> git commit / push
-> +release-create
-> 如为异步发布，再 +release-get
```
用户已有 `app_id` 且要继续开发时，先读取 [`lark-apps-get.md`](references/lark-apps-get.md) 和 [`lark-apps-local-dev.md`](references/lark-apps-local-dev.md)。只有 `+get` 返回 `app_type=modern_html` 的已有应用允许走本链路。`modern_html` 是 `html` 下的内部子类型，只在这里用于已有应用判断；创建应用时必须使用 `--app-type html`。
二次开发不要直接等同于常规链路，先按本地沙箱状态分流：
- 本地已有 HTML 代码但不是应用 git 工作区：在现有代码目录修改，发布时走 html-publish 敏捷链路。
- 本地已有应用 git 工作区：修改代码，git commit / push，再 `+release-create` / `+release-get`。
- 本地没有代码：先 `+init --app-id <app_id> --dir <workspace_dir>` 恢复工作区，再修改、提交、发布。
## 意图路由
| 用户意图 | 命令 | 按需读取 |
|---|---|---|
| 首次创建并发布 HTML 应用 | `+create`, `+html-publish`, `+release-get` | [`lark-apps-html-publish.md`](references/lark-apps-html-publish.md) |
| 创建**新**应用资产、拿 app_id | `+create` | [`lark-apps-create.md`](references/lark-apps-create.md) |
| 按 app_id 查询应用详情 / 判断 app_type | `+get` | [`lark-apps-get.md`](references/lark-apps-get.md) |
| 找已有 app_id、按名字过滤应用 | `+list --keyword <name>` | [`lark-apps-list.md`](references/lark-apps-list.md) |
| 二次开发 / 沙箱恢复 | `+get`, `+init`, `git`, `+release-create`, `+release-get` | [`lark-apps-get.md`](references/lark-apps-get.md), [`lark-apps-local-dev.md`](references/lark-apps-local-dev.md), [`lark-apps-init.md`](references/lark-apps-init.md), [`lark-apps-git-credential.md`](references/lark-apps-git-credential.md) |
| 上传 HTML 产物 | `+html-publish` | [`lark-apps-html-publish.md`](references/lark-apps-html-publish.md) |
| 部署/上线应用；查发布状态/历史 | `+release-create`, `+release-get`, `+release-list` | [`lark-apps-release-create.md`](references/lark-apps-release-create.md), [`lark-apps-release-get.md`](references/lark-apps-release-get.md), [`lark-apps-release-list.md`](references/lark-apps-release-list.md) |
| 上传静态资源（图片、视频、字体等）供 HTML 引用 | `+file-upload` | [`lark-apps-file.md`](references/lark-apps-file.md) |
## app_id 获取
`app_id` 必须是应用 ID（`app_` 开头）。`cli_` 开头的是飞书应用 ID，**绝不能**传给任何 `apps +*` 命令。
按顺序尝试：
1. 用户给出 `app_xxx` 或应用链接（如 `/app/app_xxx`）时直接提取。
2. 当前目录是已初始化项目时读取 `.spark/meta.json` 的 `app_id`。
3. 用户只给应用名/描述时用 `lark-cli apps +list --keyword "<关键词>"` 定位；多候选再让用户确认。
## 失败处理
命令失败时把 `error.hint` 转述给用户，不要原样甩 envelope JSON。
## 发布状态查询
> 这里的「发布状态」指**本 skill 刚发起的这次 release 的进度**（finished / failed），不是对 app_builder_agent 产物的运营发布状态查询——后者走应用生成 Skill（app_builder_agent）。
拿到 `release_id` 后，用 `+release-get` 查询发布状态。轮询间隔不超过 3s；不要长时间静默等待。
`status=finished` 时只回报发布状态和 `app_id`；`status=failed` 时转述失败阶段和关键错误。不要自行拼接或输出链接。
## 静态资源规则
使用 html-publish 敏捷链路时，如果 HTML / CSS / JS 引用了本地图片、视频、音频、字体等静态资源，发布前先按 [`lark-apps-file.md`](references/lark-apps-file.md) 使用 `+file-upload` 上传资源，再将代码里的本地引用替换为返回的 `download_url`。不要替换成 `+file-sign` 返回的 `signed_url`，签名链接有有效期。
- 不要上传 `index.html` 主入口本身；只处理被 HTML / CSS / JS 引用的静态资源。
- 不要上传 `.env`、密钥、凭证、配置文件。
- `+file-upload --file` 使用工作目录内的相对路径。这里的工作目录指执行 `lark-cli` 命令时所在目录，不是远端路径，也不一定相对 `index.html`。文件不在当前目录时，先 `cd` 到包含该文件的目录执行上传，或把文件复制到当前工作目录后再上传；上传完成后再回到准备发布的 HTML 目录继续替换和发布。
- 每个文件上传一次就够了，记下本地路径和 `download_url` 的对应关系，后面直接替换，不要重复上传同一个文件。建议维护一个 `file_map.json` 文件记录映射，避免遗忘。
- 静态资源链接按 `app_id` 隔离。不要跨应用复用 `download_url`；为不同应用发布时，即使是同一个本地文件，也要用当前 `app_id` 重新上传并替换。`file_map.json` 应按 `app_id` 记录映射。
- 替换代码引用时保持原语义，例如 `<img src>`、`<video src>`、CSS `url(...)`。
- 发布前检查你准备传给 `+html-publish --path` 的路径。已经上传并替换成 `download_url` 的本地资源不需要再发布；`file_map.json` 只是执行过程记录，不要放进最终上传内容。需要清理时直接清理当前要发布的文件或目录，不要为了“保持目录干净”重复创建新目录或复制文件。