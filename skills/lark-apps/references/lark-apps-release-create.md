# apps +release-create

为应用创建发布 release。运行时命令事实以 `lark-cli apps +release-create --help` 为准。

## 何时用

用于从 Git 分支触发应用部署。注意：HTML 应用的敏捷发布链路使用 `+html-publish`（已内部整合发布），不需要单独调本命令。

## 命令骨架

- 必填：`--app-id`。
- 可选：`--branch`；省略时服务端使用默认发布分支。
- 返回 `release_id`、`status` 和 `sync`，后续用 `+release-get` 轮询。

## 示例

```bash
lark-cli apps +release-create --app-id app_xxx
lark-cli apps +release-create --app-id app_xxx --branch sprint/default --dry-run
```

## 输出契约

- 成功读取 `data.release_id`、`data.status` 和 `data.sync`；`release_id` 是后续 `+release-get` 的入参。
- `sync=true` 表示同步部署（服务端等待部署完成后才返回），`sync=false` 或缺失表示异步部署。
- `status=publishing` 表示发布仍在进行；继续用 `+release-get` 轮询，轮询间隔应该为 20s。应用发布平均耗时大约 2min，整体超时时间大约 5min。
- `status=finished` 表示部署已完成（同步部署时可能直接返回此状态）。
- `+release-create` 只返回进行中状态时，不能说本轮最新版本已部署；必须等 `+release-get` 查询到 `finished`，或 `+release-create` 本身已经返回 `finished`。

## Agent 规则

`+release-create` 部署的是远端 `sprint/default` 上已 push 的代码，不是本地工作区——本地若有未推送的改动，需要先 `git add` + `git commit` 并 `git push` 到 `sprint/default`，否则这些改动不会进入这次发布。`git push` 如遇认证失败、401/403、credential helper 缺失或 token 过期，先执行 `lark-cli apps +git-credential-init --app-id <app_id>` 刷新本地 Git 凭证，再重试原 git 命令；刷新凭证也失败时，停止并向用户报告错误，不要换路。

发布后根据 `data.sync` 判断：`sync=true` 为同步发布，直接返回 `online_url`；`sync=false` 或缺失为异步发布，用 [`+release-get`](lark-apps-release-get.md) 查询。
