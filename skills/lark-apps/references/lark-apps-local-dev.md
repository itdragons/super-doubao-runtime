# lark-apps 应用工作区开发与二次迭代

用于已有 HTML 应用的二次开发或沙箱恢复：已知 `app_id` 后，先用 [`lark-apps-get.md`](lark-apps-get.md) 查询应用详情和 `app_type`，再根据本地沙箱代码状态选择后续动作。

这个能力只处理 HTML 类型应用。非 HTML 类型应用不允许走本 Skill 的工作区链路。

## 二次开发分流

不要把“二次开发”直接等同于常规链路。先检查本地代码状态：

| 本地状态 | 判断 | 动作 |
|---|---|---|
| 有 HTML 代码，但不是应用 git 工作区 | 有 `index.html` 或静态产物，但没有 `.git` / `.spark/meta.json` 关联当前 `app_id` | 在现有代码目录修改，发布时走 html-publish 敏捷链路 |
| 有应用 git 工作区 | 存在 `.git` 和 `.spark/meta.json`，且 meta 中 app_id 与目标 `app_id` 一致 | 直接修改代码，git commit / push，再 `+release-create` / `+release-get` |
| 没有本地代码 | 找不到当前应用代码目录 | 先 `+init --app-id <app_id> --dir <workspace_dir>` 恢复工作区，再修改、提交、发布 |

## 工作区流程

```text
已有 app_id
-> +init --app-id <app_id> --dir <workspace_dir>
-> 修改工作区代码
-> git commit / push
-> +release-create
-> 如为异步发布，再 +release-get
```

## 初始化工作区

```bash
lark-cli apps +init --app-id app_xxx --dir ./html-app
cd ./html-app
```

`+init` 会编排凭证、clone、切到工作分支、脚手架和同步逻辑。需要逐步手动控制时，先 `+git-credential-init` 拿 `repository_url`，再用原生 `git clone` / `git checkout sprint/default`。

## 改完代码后部署上线

已拉到本地、改完代码，用户说"推上去""部署""上线""发布到云端"时，按此序列。

> `+release-create` 部署的是远端 `sprint/default` 上**已 push** 的代码，不是你本地工作区——未 commit / 未 push 的改动不会进入这次发布。所以发布前务必先把本次改动提交并推送。

1. `git status` 看本次改动；`git add <本次相关文件>` 暂存后 `git commit` 提交。只提交本次任务相关的改动即可，无关的零散文件不必强求清空——发布门禁是「**本次相关改动已提交并推送**」，不是「工作区绝对干净」。
2. `git push origin sprint/default` 把工作分支推到远端（遇非 fast-forward：先 `git pull --rebase origin sprint/default` 解决冲突再推，绝不 force-push；遇 Git 认证失败 / 401 / 403 / credential helper 缺失 / token 过期：先执行 `lark-cli apps +git-credential-init --app-id <app_id>` 刷新本地 Git 凭证，再重试原 git 命令；刷新凭证也失败时，停止并向用户报告错误，不要换路）。
3. `lark-cli apps +release-create --app-id <app_id>` 发起部署上线。
4. 读取 `+release-create` 输出的 `data.sync`：`sync=true` 为同步发布，直接返回 `online_url`；`sync=false` 或缺失为异步发布，再用 `lark-cli apps +release-get` 轮询。成功时读取本轮发布完成后的访问链接；失败时读取失败阶段和关键日志（`+list` 仅作独立查询入口）。

## 领域规则

- 代码读写走原生 `git`；CLI 负责凭证、初始化和发布。不存在 `apps +pull` / `apps +push` / `apps code +read` 这类代码读写 shortcut，不要臆造。
- `+init` 会编排 `+git-credential-init`、`git clone`、切到 `sprint/default`、运行脚手架，并在有变更时提交/推送；传入 `--source-path` 时，已生成 HTML 项目的接入也由 `+init` 内部处理。
- `+init --dir` 是应用工作区目标目录，最好使用不存在或空目录；`--source-path` 是已生成 HTML 项目目录，目录根下应包含 `index.html`。需要把已有 HTML / 静态页面 / 前端代码导入工作区时传 `--source-path`；不要把已有 HTML 项目目录直接当作 `--dir`。
- `sprint/default` 是工作分支；服务端护栏禁直推 `main`、拒 force-push、要求 `sprint/default` fast-forward。
- 已拉到工作区后，pull/push/diff/log 都用原生 git；远端 `sprint/default` 比工作区新时，先 `git pull --rebase origin sprint/default`，解决冲突后再 push 和 publish。
- 环境变量由脚手架在本地启动时处理；需要手动刷新时用 `+env-pull`。
- 只从 `+list` 看到 `is_published=true`，不能证明本地刚推送的代码已经部署；必须有本轮 `+release-get finished`。

## 特殊情况：导入新的 HTML 目录

普通二次开发 / 沙箱恢复不要传 `--source-path`。只有已有一份新的 HTML / 静态页面 / 前端代码目录需要接入当前应用工作区时，才在初始化时传 `--source-path`：

```bash
lark-cli apps +init --app-id app_xxx --dir ./html-app --source-path ./generated-html
```

`--source-path` 必须是目录，目录根下包含 `index.html`。

## 存量应用入口

已有项目目录先读 `.spark/meta.json` 取 `app_id`；没有本地项目但知道应用名时用：

```bash
lark-cli apps +list --keyword "应用名"
```

拿到应用标识后再 `+init` 或 `+git-credential-init`。
