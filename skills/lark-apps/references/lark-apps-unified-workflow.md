# lark-apps 常规发布 Workflow

用于把已经生成的 HTML、静态页面或前端代码接入为应用工作区并发布上线。本文记录常规链路的原子 workflow；具体命令参数、输出字段和异常处理以对应 reference 与当前 `--help` 为准。

## 适用范围

仅支持**纯 HTML + CSS + JS 产物**（入口为 `index.html`）。React、Vue 等框架项目、SPA 或全栈应用不在范围内。

## Workflow

```text
+create --app-type html
-> +init --app-id <app_id> --dir <workspace_dir> --source-path <source_path>
-> git add / commit / pull --rebase / push
-> +release-create
-> 如为异步发布，再 +release-get
```

## 步骤

1. 读取 [`lark-apps-create.md`](lark-apps-create.md)，创建 HTML 应用。
2. 读取 [`lark-apps-init.md`](lark-apps-init.md)，执行 `+init` 初始化应用工作区；需要导入已经生成的 HTML、静态资源或前端代码目录时，把该目录作为 `--source-path` 传入。
3. 进入初始化后的工作区，读取工作区内的通用开发指引，例如 `AGENTS.md`、README 或脚手架说明。
4. 提交并推送工作区代码到远端工作分支。
5. 读取 [`lark-apps-release-create.md`](lark-apps-release-create.md)，创建发布单。
6. 解析 `+release-create` 输出：读取 `data.sync`，`sync=true` 为同步发布；`sync=false` 或缺失为异步发布，再读取 [`lark-apps-release-get.md`](lark-apps-release-get.md) 用 `data.release_id` 查询，直到 `finished` 或 `failed`。

## 已有代码目录

如果当前目录已经存在 HTML 项目，不要直接把这个目录当作 `+init --dir` 目标。

正确做法是：

1. 保留已有代码目录作为 `--source-path`。
2. 选择一个不存在或空目录作为 `--dir` 应用工作区。
3. 执行 `+init --app-id <app_id> --dir <workspace_dir> --source-path <generated_html_dir>`。
4. 不要反向覆盖 `.spark`、`.agent`、Git 配置或 `+init` 生成的项目元数据。

## 发布前检查

- 发布的是远端已 push 的代码，不是工作区未提交内容。
- 如果没有额外代码变更，确认 `+init` 或上一步合入流程已经把目标代码推到远端分支后，再继续发布。
- 遇到非 fast-forward，先拉取远端工作分支最新内容并解决冲突，不要 force push。

## 输出给用户

完成后只回报发布状态和 `app_id`；不要自行拼接或输出链接，也不要描述页面内容（你没有访问过部署后的页面）。

如果发布失败，优先给出失败阶段和关键日志摘要，不要用历史发布链接冒充本轮结果。
