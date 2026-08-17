# AGENTS.md - python_server/ FastAPI AIO runtime

本文件是 `python_server/` 的本地入口。仓库总入口见 `../AGENTS.md`，架构边界见 `../ARCHITECTURE.md`。

## 模块定位

`python_server/` 是容器内 Python AIO runtime。它通过 FastAPI 提供文件上传/下载、text editor、code interpreter、metrics、runtime metadata 和本地签名/session 检查。

## 知识导航

| 我要做什么 | 去哪里看 |
| --- | --- |
| 修改 FastAPI app、middleware、file/text endpoints | `application/python_server.py` |
| 修改 code interpreter/Jupyter kernel | `application/code_interpreter.py` |
| 修改 runtime metadata `/v1/sandbox` | `application/runtime_server.py` |
| 修改 metrics endpoint | `application/metrics_server.py` |
| 修改 signature helper | `application/helpers/signature_helper.py` |
| 修改 text editor 实现 | `application/tools/text_editor.py` |
| 修改 file helper/upload/zip | `application/tools/file/`、`application/helpers/utils.py` |
| 更新 Python 依赖 | `requirements_ci.txt`、`setup.py`、`pyproject.toml`，并同步 Docker base layer |

## 目录结构

```text
python_server/
├── start_server.py              # uvicorn entrypoint and startup env handling
├── setup.py                     # package metadata
├── pyproject.toml               # build backend
├── requirements_ci.txt          # runtime dependency set baked into image layers
├── openapi.yaml                 # API reference snapshot
└── application/
    ├── python_server.py         # mounted FastAPI app and main endpoints
    ├── code_interpreter.py      # Jupyter/kernel endpoints
    ├── runtime_server.py        # sandbox runtime metadata
    ├── metrics_server.py        # metrics endpoints
    ├── helpers/                 # signature, upload, utility helpers
    ├── tools/                   # text editor and file helpers
    └── types/                   # Pydantic message/error types
```

## 本地约束

- `app_base.mount("/vm/exec/api", ci_app)` is the path root; route changes must be checked from the mounted external path.
- Python signature middleware must stay semantically aligned with Go `middleware/signature.go`.
- Do not bypass signature middleware through request headers; local validation must use real signatures or exempt health paths.
- Upload/write routes must keep allowed base path checks for container workspaces.
- Dependency changes can invalidate slow Docker lower layers; use `skills/build-docker-image/SKILL.md` and decide whether `--rebuild-base` is required.
- `python_server/application/README.md` contains older path examples; source code and this `AGENTS.md` are the current Agent routing truth.

## 常用命令

```bash
cd python_server
python3 -m py_compile start_server.py application/python_server.py application/code_interpreter.py application/runtime_server.py application/metrics_server.py
python3 -m compileall -q application start_server.py
```

For endpoint behavior, prefer repository Docker verification from the root:

```bash
python3 skills/local-docker-api-verify/scripts/local_api_verify.py \
  --path /vm/exec/api/v3/health
```

## 进一步阅读

- `../docs/harness/verification-matrix.md`
- `../docker_build/AGENTS.md`
