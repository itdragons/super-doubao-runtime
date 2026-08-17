# apps +create

创建应用。运行时命令事实以 `lark-cli apps +create --help` 为准。

## 何时用

用来创建应用资产并拿到后续步骤需要的应用标识。已有 HTML / 静态页面 / 前端代码发布为应用时，创建 `html` 应用。

## 命令骨架

- 必填：`--name`、`--app-type`。
- 当前环境的 HTML 应用使用 `--app-type html`。
- 可选：`--description`、`--icon-url`。

## 示例

```bash
lark-cli apps +create --name "页面应用" --app-type html

lark-cli apps +create --name "页面应用" --app-type html \
  --description "HTML 应用"

lark-cli apps +create --name "Demo" --app-type html --dry-run
```

## 输出契约

- 成功默认 JSON envelope 中读取 `data.app.app_id`，同时可用 `data.app.name` / `description` 向用户确认结果。
- pretty 输出只适合人看；后续命令需要 app_id 时，用 JSON 或 `--jq '.data.app.app_id'`。

## app type 与命名

- HTML 应用创建时使用 `--app-type html`。
- 用户只给自然语言需求时，据此生成简洁的 `--name` 和一句 `--description` 直接创建；不满意再用 `+update` 改。

创建后继续执行常规链路或 html-publish 敏捷链路，以对应 reference 为准。
