import asyncio
import json
import os
import queue
import urllib.parse
from datetime import datetime
import time

import jwt
import traitlets
from fastapi import (
    File,
    Form,
    Body,
    HTTPException,
    UploadFile,
    APIRouter,
    Request,
    Depends,
    status,
)
from fastapi.responses import JSONResponse, StreamingResponse
from jupyter_client import (
    AsyncMultiKernelManager,
    KernelManager,
)
from pydantic import parse_obj_as

from application.logger import logger
from application.models import *
from application.router import TimedRoute
from application.types.messages import CodeInterpreterRequest, CodeInterpreterResult, CodeInterpreterResponse, EmptyCodeInterpreterResult, CIFileInfo
from application.analyze.analyze_timeout_v2 import static_analyze_code_async, CodeAnalyzeResult, TimeoutReason
from concurrent.futures import ProcessPoolExecutor
import multiprocessing
from application.types.error_code import ErrorCode

# os.chdir(os.path.expanduser("~"))

_DOWNLOAD_CHUNK_SIZE = 1024 * 1024
_MAX_JUPYTER_MESSAGE_SIZE = 10 * 1024 * 1024

prefix = "/code_interpreter"
global ws_id
ws_id = os.getenv("WS_ID")
public_key = os.getenv("SECURITY_PK")
logger.info(f"env ws_id: {ws_id}")
logger.info(f"env public_key: {public_key}")
if ws_id and os.getenv("ROUTE_USE_PREFIX"):
    prefix = "/" + ws_id


def check_auth(token: str):
    if not public_key:
        return ""
    if not token:
        errmsg = "token empty"
    else:
        try:
            payload = jwt.decode(token, public_key, algorithms=["RS256"])
            errmsg = check_auth_payload(payload, ws_id)
            if errmsg == "":
                return token
        except jwt.InvalidTokenError:
            errmsg = "invalid token"
        except ValueError:
            errmsg = "check token failed"
    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail=errmsg,
    )


def check_auth_payload(payload, ws_id):
    if "ws_id" not in payload or payload["ws_id"] != ws_id:
        return "ws_id not equal, want {}, but got {}".format(ws_id, payload["ws_id"])
    if "exp" not in payload:
        return "exp not in jwt"
    expire_at = datetime.fromtimestamp(int(payload["exp"]))
    now = datetime.now()
    if now > expire_at:
        return "jwt exp at {} but now is {}".format(expire_at, now)
    return ""


def check_header(request: Request):
    # 如果有公钥则验证，否则认为不开启鉴权跳过验证
    token = ""
    if "Authorization" in request.headers:
        token = request.headers["Authorization"]
    return check_auth(token)


router = APIRouter(prefix=prefix, route_class=TimedRoute)

jupyter_config = traitlets.config.get_config()

jupyter_config.KernelRestarter.restart_limit = 0
_MULTI_KERNEL_MANAGER = AsyncMultiKernelManager(config=jupyter_config)
_MULTI_KERNEL_MANAGER.connection_dir = "/tmp"


async def get_or_init_kernel(kernel_id: str, check_channel=False, cwd=None) -> KernelManager:
    try:
        return _MULTI_KERNEL_MANAGER.get_kernel(kernel_id)
    except KeyError:
        logger.info(f"kernel_id:{kernel_id} not exists,creating new kernel...")
    # 传入工作目录参数
    kwargs = {"kernel_id": kernel_id}
    if cwd:
        kwargs["cwd"] = cwd
    await _MULTI_KERNEL_MANAGER.start_kernel(
        kernel_name="python3.10",
        **kwargs,
    )
    km = _MULTI_KERNEL_MANAGER.get_kernel(kernel_id)
    if check_channel:
        kc = km.client()
        kc.start_channels()
        logger.info(f"kernel_id:{kernel_id} start_channels")
        await kc.wait_for_ready()
        logger.info(f"kernel_id:{kernel_id} wait_for_ready")
        kc.stop_channels()
        logger.info(f"kernel_id:{kernel_id} stop_channels")
    logger.info(f"kernel_id:{kernel_id} init successfully")
    return km


@router.post("/kernel_v2")
async def create_kernel_v2(kernel_id: str = "", token: str = Depends(check_header)):
    try:
        await get_or_init_kernel(kernel_id)
        return JSONResponse(content={"status": "success"})
    except Exception as e:
        return JSONResponse(
            content={"status": "failed", "reason": "kernel init failed: " + str(e)}
        )

def ls_workspace(workspace):
    """
    list all files in workspace, return filepath and mtime

    :param workspace: eg: /mnt
    :return: dict of {filepath: mtime}
    """
    file_update_times = {}
    for root, dirs, files in os.walk(workspace):
        dirs[:] = [dir_name for dir_name in dirs if not dir_name.startswith(".")]
        for file in files:
            if file.startswith("."):
                continue
            file_path = os.path.join(root, file)
            try:
                file_update_times[file_path] = os.path.getmtime(file_path)
            except Exception as e:
                logger.error(f"get {file_path} update time error: {e}")
    return file_update_times

def get_generated_files(workspace: str, prev_files: dict):
    """
    compare current workspace files with prev_files, return new files and modified files

    :param workspace: eg: /mnt
    :param prev_files: previous files, dict of {filepath: mtime}
    :return: List[new_files, modified_files]
    """
    logger.info(f"get_generated_files. workspace={workspace}, prev_files={prev_files}")
    updated_files = []
    current_file_update_times = {}

    for root, dirs, files in os.walk(workspace):
        dirs[:] = [dir_name for dir_name in dirs if not dir_name.startswith(".")]
        for file in files:
            if file.startswith("."):
                continue
            file_path = os.path.join(root, file)
            try:
                mtime = os.path.getmtime(file_path)
                current_file_update_times[file_path] = mtime

                # add new file or modified file
                if (file_path not in prev_files) or (mtime > prev_files[file_path]):
                    updated_files.append(file_path)
            except Exception as e:
                logger.error(f"get {file_path} update time error: {e}")

    logger.info(f"get_generated_files finished")
    return updated_files

def process_code_output(contents: list, is_timeout: bool = False) -> CodeInterpreterResult:
    result = CodeInterpreterResult(
        base64_image="",
        path_list=[],
        ci_output="",
        exec_result="",
        error="",
    )
    # 如果超时，只取前100条输出内容
    if is_timeout:
        logger.info(f"exec code timeout, only keep first 100 contents. actual contents len={len(contents)}")
        
    processed_contents = contents[:1] if is_timeout else contents
    output_len = 0

    for content in processed_contents:
        if content["type"] == "stream":
            content_result = content["text"]
            result.ci_output += content_result
            if is_timeout:
                output_len += len(content_result)
                if output_len > 1000:
                    result.ci_output += f"\n...output truncated, only keep first 1000 chars"
                    break
        elif content["type"] == "error":
            traceback_str = ";".join(content["traceback"])
            error_detail = content['evalue']
            error_type = content['ename']
            err_str = f"\nename={error_type},evalue={error_detail},traceback={traceback_str}\n"
            result.error += err_str
            result.error_type = error_type
            result.error_detail = error_detail

            if is_timeout:
                output_len += len(err_str)
                if output_len > 1000:
                    result.error += f"\n...error truncated, only keep first 1000 chars"
                    break
        elif content["type"] == "display_data":
            if "image/png" in content["data"]:
                result.base64_image = content["data"]["image/png"]
        elif content["type"] == "execute_result":
            if "text/plain" in content["data"]:
                result.exec_result += content["data"]["text/plain"]
    return result


async def interrupt_kernel(kernel_id: str):
    shutdown_start = time.monotonic()
    try:
        await _MULTI_KERNEL_MANAGER.shutdown_kernel(kernel_id, True)
        shutdown_elapsed_ms = int((time.monotonic() - shutdown_start) * 1000)
        logger.info(
            f"kernel_id:{kernel_id} interrupted successfully, shutdown_kernel elapsed={shutdown_elapsed_ms}ms"
        )
    except Exception as e:
        logger.error(f"Failed to interrupt kernel {kernel_id}: {e}")


# 用于静态分析代码是否会超时（异步任务）
async def async_analyze_timeout_with_queue(code: str, analyze_timeout_result_queue: asyncio.Queue):
    try:
        # 用线程池执行同步函数并设置超时
        analyze_result = await asyncio.wait_for(
            static_analyze_code_async(code),
            timeout=5.0
        )
        if analyze_result:
            logger.info(f"analyze_timeout_result_queue.put_nowait({analyze_result})")
            analyze_timeout_result_queue.put_nowait(analyze_result)
        else:
            logger.warning(f"static_analyze_code return empty result")
            analyze_timeout_result_queue.put_nowait(CodeAnalyzeResult())
    except asyncio.TimeoutError:
        logger.error(f"static_analyze_code exec timeout")
        pass
    except asyncio.CancelledError:
        logger.info(f"static_analyze_timeout cancelled")
        pass
    except Exception as e:
        logger.error(f"static_analyze_timeout error: {e}")

async def sleep_async(seconds: float):
    await asyncio.sleep(seconds)

async def cancel_tasks_if_not_done(*tasks):
    for task in tasks:
        if task.done():
            continue
        
        task.cancel()
        try:
            await task
        except:
            pass

def get_result_from_async_queue(analyze_timeout_result_queue: asyncio.Queue) -> Optional[CodeAnalyzeResult]:
    try:
        item = analyze_timeout_result_queue.get_nowait()
    except asyncio.QueueEmpty:
        item = None
    return item


# CI http 入口
@router.post("/run")
async def run_code(
    req: CodeInterpreterRequest,
    token: str = Depends(check_header),
):  

    http_resp = await run_code_with_analyze_timeout(req, token)
    # 增加文件大小信息
    ci_result = http_resp.result
    if ci_result.path_list:
        logger.info(f"add file size before return")
        for file_path in ci_result.path_list:
            ci_result.file_info_list.append(CIFileInfo(
                path=file_path,
                size=os.path.getsize(file_path)
            ))

    return http_resp


# 执行代码 + 异步分析超时
async def run_code_with_analyze_timeout(
    req: CodeInterpreterRequest,
    token: str = Depends(check_header),
):  
    # 1. 初始化kernel
    try:
        km = await get_or_init_kernel(req.kernel_id, True, req.workspace)
        kc = km.client()
    except Exception as e:
        workspace = req.workspace
        prev_files = ls_workspace(workspace)
        ci_resp = CodeInterpreterResponse(
            status="error",
            error="kernel init failed: " + str(e),
            result=process_code_output([]),
            )
        ci_resp.result.path_list = get_generated_files(workspace, prev_files)
        logger.info(f"ci exec failed while init kernel, result={ci_resp}")
        return ci_resp

    # 1 启动代码执行任务
    execute_task = asyncio.create_task(
        execute_code(req, kc)
    )

    # 2 定义代码分析结果队列 & 启动代码分析任务
    analyze_timeout_result_queue = asyncio.Queue()
    analyze_task = asyncio.create_task(
        async_analyze_timeout_with_queue(req.code, analyze_timeout_result_queue)
    )

    # 3 启动等待任务（达到时间后才检查分析结果）
    sleep_wait_task = asyncio.create_task(sleep_async(5.0))

    analyze_result = None
    done, pending = await asyncio.wait(
        {execute_task, sleep_wait_task},
        return_when=asyncio.FIRST_COMPLETED,
    )
    
    if execute_task in done:
        logger.info(f"execute_task done")
        # 代码正常执行完成。取消分析任务和sleep等待任务
        await cancel_tasks_if_not_done(analyze_task, sleep_wait_task)

        # 获取执行结果
        result = execute_task.result()

        # 记录检测结果
        analyze_result = get_result_from_async_queue(analyze_timeout_result_queue)
        if analyze_result and analyze_result.error_type:
            result.result.bad_code_detect_result = analyze_result.error_type
        return result

    else:
        logger.info(f"sleep_wait_task done")
        # sleep等待任务完成。开始检查分析结果
        analyze_result = get_result_from_async_queue(analyze_timeout_result_queue)
        
        # 分析结果有异常，取消代码执行任务&关闭kernel，然后直接返回
        if analyze_result and analyze_result.error_type:
            logger.error(f"analyze_result.error_type={analyze_result.error_type}, will cancel execute_task")
            await cancel_tasks_if_not_done(execute_task, analyze_task)
            ci_result = EmptyCodeInterpreterResult()
            ci_result.bad_code_detect_result = analyze_result.error_type
            
            await interrupt_kernel(req.kernel_id)

            return CodeInterpreterResponse(
                status="error",
                error=f"{ErrorCode.ANALYZE_TIMEOUT.description}. {analyze_result.desc_for_user()}" ,
                error_code=ErrorCode.ANALYZE_TIMEOUT.value,
                result=ci_result
            )
        else:
            logger.info(f"analyze_result is None, will await execute_task")
            result = await execute_task
            if analyze_result and analyze_result.error_type:
                result.result.bad_code_detect_result = analyze_result.error_type
            return result


async def execute_code(
    req: CodeInterpreterRequest,
    kc,
    token: str = Depends(check_header),
):
    logger.info(f"run_code req={req}")
    code = req.code
    workspace = req.workspace
    timeout = req.timeout
    kernel_id = req.kernel_id
    prev_files = ls_workspace(workspace)

    logger.info(f"kernel_id:{kernel_id} begin to execute...")
    
    contents = []
    try:
        kc.start_channels()
        logger.info(f"kernel_id:{kernel_id} start channels successfully...")
        msg_id = kc.execute(code)
        logger.info(f"kernel_id:{kernel_id} executing code...")
        execute_start = time.monotonic()

        try:
            await asyncio.wait_for(_collect_messages(kc, msg_id, contents, timeout), timeout)
        except asyncio.TimeoutError:
            timeout_elapsed_seconds = time.monotonic() - execute_start
            logger.error(
                f"kernel_id:{kernel_id} execute timeout after {timeout_elapsed_seconds:.3f}s, interrupt kernel..."
            )
            await interrupt_kernel(kernel_id)
            ci_resp = CodeInterpreterResponse(
                status="success",
                error=ErrorCode.TIMEOUT.description,
                error_code=ErrorCode.TIMEOUT.value,
                result=process_code_output(contents, True),
            )
            ci_resp.result.path_list = get_generated_files(workspace, prev_files)
            logger.info(f"ci exec timeout, result={ci_resp}")
            return ci_resp
    except Exception as e:
        await _MULTI_KERNEL_MANAGER.shutdown_kernel(
            kernel_id=kernel_id, now=True, restart=True
        )
        logger.error(
            f"kernel_id:{kernel_id} execute failed: {e} kernel already shutdown"
        )

        ci_resp = CodeInterpreterResponse(
            status="error",
            error="kernel execute failed: " + str(e),
            result=process_code_output(contents),
        )
        ci_resp.result.path_list = get_generated_files(workspace, prev_files)
        logger.info(f"ci exec failed, result={ci_resp}")
        return ci_resp
    finally:
        logger.info(f"execute finally  ...")
        try:
            # 使用线程池执行stop_channels，设置超时时间
            loop = asyncio.get_event_loop()
            await asyncio.wait_for(
                loop.run_in_executor(None, kc.stop_channels),
                timeout=5  # 5秒超时
            )
            logger.info(f"kernel_id:{kernel_id} stop channels successfully, after execute code")
        except asyncio.TimeoutError:
            logger.error(f"kernel_id:{kernel_id} stop_channels timeout after 10s, force shutdown kernel...")
            # 超时后强制关闭kernel
            await interrupt_kernel(kernel_id)
            logger.info(f"kernel_id:{kernel_id} force shutdown kernel successfully after stop_channels timeout")
        except Exception as e:
            logger.error(f"kernel_id:{kernel_id} stop_channels failed: {e}, interrupt kernel...")
            await interrupt_kernel(kernel_id)
            logger.info(f"kernel_id:{kernel_id} stop_channels failed, interrupt kernel successfully")

    logger.info(f"kernel_id:{kernel_id} execute code success")

    ci_result = process_code_output(contents)
    ci_result.path_list = get_generated_files(workspace, prev_files)
    ci_result.success = True
    ci_resp = CodeInterpreterResponse(
        status="success",
        result=ci_result,
    )
    if ci_result.error != "":
        # 外层status=success表示api请求成功，内层success=false表示CI运行报错
        ci_resp.status = "success"
        ci_resp.error = "code execute return error"
        ci_resp.result.success = False
    logger.info(f"ci exec success, result={ci_resp}")
    return ci_resp

async def _collect_messages(kc: Any, msg_id: str, contents: list, timeout: int):
    retry_count = 1
    max_retries = timeout
    while True:
        try:
            logger.info("loop to reading data...")
            iopub_msg = await kc.iopub_channel.get_msg(timeout=1)
        except queue.Empty:
            if retry_count > max_retries:  # 使用更大的重试次数
                logger.error(
                    "execute failed: kernel iopub read failed. kernel restarted"
                )
                raise Exception(
                    "kernel iopub read failed"
                )  # This will be caught by the timeout handler
            logger.warning("iopub read failed, retrying after 10ms")
            retry_count += 1
            time.sleep(0.01)
            continue
        logger.info(f"data type: {iopub_msg['msg_type']}")
        logger.info(f"data content: {iopub_msg['content']}")
        logger.info(f"parent_header: {iopub_msg['parent_header']}")
        logger.info(f"iopub_msg.parent_header.msg_id: {iopub_msg['parent_header'].get('msg_id')}, input.msg_id={msg_id}.")
        
        if iopub_msg["parent_header"].get("msg_id") == msg_id:
            if iopub_msg["msg_type"] == "status":
                if iopub_msg["content"]["execution_state"] == "idle":
                    logger.info("content.execution_state is idle")
                    break
                continue
            if iopub_msg["msg_type"] == "execute_input":
                continue
            if (
                iopub_msg["msg_type"] == "execute_result"
                and "code" in iopub_msg["content"]
            ):
                continue
            content = iopub_msg["content"]
            content["type"] = iopub_msg["msg_type"]
            contents.append(content)


@router.post("/upload")
async def upload(
    upload_request: str = Form(),
    file: UploadFile = File(),
    token: str = Depends(check_header),
):
    logger.info("Upload request.")
    request = parse_obj_as(UploadFileRequest, json.loads(upload_request))
    try:
        path = os.path.abspath(request.destination)
        if not path.startswith("/mnt"):
            return JSONResponse(
                content={
                    "status": "failed",
                    "reason": "only upload to /mnt directory is allowed",
                },
                status_code=400,
            )

        with open(path, "wb") as f:
            while chunk := file.file.read():
                f.write(chunk)
    except Exception:
        try:
            os.remove(request.destination)
        except Exception as e:
            logger.exception(
                f"Error while removing file: {request.destination}", exc_info=e
            )
        raise

    logger.info(f"Upload request complete. {upload_request}")
    return JSONResponse(content={})


@router.get("/download/{path:path}")
async def download(path: str, token: str = Depends(check_header)):
    logger.info(f"Download file{path}")
    if path.startswith("mnt"):
        path = "/" + path
    path = os.path.abspath(urllib.parse.unquote(path))
    if not os.path.isfile(path):
        raise HTTPException(404, f"File not found: {path}")

    logger.info(f"Download request. {path}")

    if not path.startswith("/mnt"):
        return JSONResponse(
            content={
                "status": "failed",
                "reason": "only download from /mnt directory is allowed",
            },
            status_code=400,
        )

    def iterfile():
        with open(path, "rb") as f:
            while chunk := f.read(_DOWNLOAD_CHUNK_SIZE):
                yield chunk

    return StreamingResponse(
        iterfile(),
        headers={"Content-Length": f"{os.path.getsize(path)}"},
        media_type="application/octet-stream",
    )


@router.get("/list_mnt_dir")
async def list_mnt_dir(token: str = Depends(check_header)):
    result = []
    for subdir, dirs, files in os.walk("/mnt"):
        for filename in files:
            file_path = os.path.join(subdir, filename)
            result.append(file_path)
    return ListMntDirResponse(files=result)


@router.get("/list_mnt_dir_detail")
async def list_mnt_dir_detail(token: str = Depends(check_header)):
    # Add Mod time
    result = []
    # {"update_time": "2023-09-18 11:00:00", : "xxx"}
    for subdir, dirs, files in os.walk("/mnt"):
        for filename in files:
            file_path = os.path.join(subdir, filename)
            file_stat = os.stat(file_path)
            time = datetime.fromtimestamp(file_stat.st_mtime)
            result.append(
                MntDirDetailResponse(
                    file=file_path, update_time=time.strftime("%Y-%m-%d %H:%M:%S")
                )
            )
    return ListMntDirDetailResponse(files=result)


@router.post("/kernel")
async def create_kernel(kernel_id: str = "", token: str = Depends(check_header)):
    try:
        await get_or_init_kernel(kernel_id)
        return JSONResponse(content={"status": "success"})
    except Exception as e:
        return JSONResponse(
            content={"status": "failed", "reason": "kernel init failed: " + str(e)}
        )

@router.post("/delete_kernel")
async def delete_kernel(kernel_id: str = "", token: str = Depends(check_header)):
    try:
        # 先 shutdown 再 remove
        await _MULTI_KERNEL_MANAGER.shutdown_kernel(kernel_id=kernel_id, now=True)
        logger.info(f"kernel_id:{kernel_id} shutdown successfully")
        _MULTI_KERNEL_MANAGER.remove_kernel(kernel_id)
        logger.info(f"kernel_id:{kernel_id} delete successfully")
        return JSONResponse(content={"status": "success"})
    except Exception as e:
        return JSONResponse(
            content={"status": "failed", "reason": "delete kernel failed: " + str(e)}
        )
