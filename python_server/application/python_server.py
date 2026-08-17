import asyncio
import errno
import math
import mimetypes
import os
import time
from enum import Enum
from pathlib import Path
from typing import Dict, List

import httpx
from fastapi import Body, FastAPI, HTTPException, Query, Request, File, UploadFile, Form
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

from application.helpers.utils import upload_to_presigned_url, upload_file_parts
from application.helpers.signature_helper import verify_signature_with_base64_public_key
from application.logger import logger
from application.models import MultipartUploadRequest, MultipartUploadResponse
from application.router import TimedRoute
from application.trace_id_filter import set_trace_id, set_tool_use_id
from application.tools.base import ToolError
from application.tools.file import file_helper
from application.tools.file.file_helper import create_zip_archive
from application.tools.text_editor import text_editor
from application.types.messages import ToolResult, TextEditorAction, TextEditorActionResult

from application.code_interpreter import router as CIRouter
from application.metrics_server import metrics_server_router


app_base = FastAPI()

# ci应用
path_prefix = "/vm/exec/api"
ci_app = FastAPI()
ci_app.router.route_class = TimedRoute
ci_app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

FILENAME_MAX_BYTES = 255

app_base.mount("/vm/exec/api", ci_app)


class FileUploadRequest(BaseModel):
    file_path: str
    presigned_url: str


MULTIPART_THRESHOLD = 10485760  # 10MB

# store last access time, used for detecting inactive pods
last_access_times = time.time()

# last accessing api exclusion list
excluded_paths = ["/healthz", "/is_alive", "/vm/exec/api/metrics/loaded_modules","/vm/exec/api/v1/sandbox", "/v1/sandbox"]


def build_signature_message_v2(path: str, session: str, instance_name: str, utc_time: str) -> str:
    return f"{path}\n{session}\n{instance_name}\n{utc_time}"


def log_signature_verify_result(path: str, instance_name: str, success: bool):
    event = "signature_verify_result_v2"
    result = "success" if success else "failed"
    message = (
        f"event={event} result={result} version=v2 fallback=false "
        f"path={path} has_instance={str(bool(instance_name)).lower()}"
    )
    if success:
        logger.info(message)
    else:
        logger.warning(message)


@ci_app.middleware("http")
async def verify_request_signature(request: Request, call_next):
    # 检查是否需要签名验证
    if request.url.path not in excluded_paths:
        # 从请求头获取签名相关信息
        base64_public_key = request.headers.get("x-container-access-key")
        signature_v2 = request.headers.get("x-container-signature-v2")
        utc_time = request.headers.get("x-container-utc-time")
        session = request.headers.get("x-session-id")
        instance_name = request.headers.get("X-Faas-Instance-Name", "")

        # 检查必要的签名头是否存在
        if not base64_public_key or not utc_time or not signature_v2:
            return JSONResponse(
                status_code=401,
                content={"detail": "Missing signature headers"}
            )

        # 验证时间戳是否过期（允许10分钟的时间差）
        import datetime
        try:
            request_time = datetime.datetime.fromisoformat(utc_time.replace("Z", "+00:00"))
            current_time = datetime.datetime.utcnow().replace(tzinfo=datetime.timezone.utc)
            time_diff = abs((current_time - request_time).total_seconds())

            if time_diff > 600:  # 10分钟
                return JSONResponse(
                    status_code=401,
                    content={"detail": "Request expired"}
                )
        except Exception as e:
            return JSONResponse(
                status_code=401,
                content={"detail": "Invalid time format"}
            )

        url_path = request.url.path
        url_path = url_path.removeprefix(path_prefix)
        message = build_signature_message_v2(url_path, session, instance_name, utc_time)
        # 验证签名
        is_valid = verify_signature_with_base64_public_key(base64_public_key, message, signature_v2)
        log_signature_verify_result(url_path, instance_name, is_valid)

        if not is_valid:
            return JSONResponse(
                status_code=401,
                content={"detail": "Invalid signature"}
            )

    # 调用下一个中间件或路由处理程序
    return await call_next(request)


@ci_app.middleware("http")
async def log_access_time(request: Request, call_next):
    global last_access_times
    set_trace_id(request.headers.get("x-tt-logid", "unknown"))
    set_tool_use_id(request.headers.get("x-tool-use-id", "unknown"))
    # check
    if request.url.path not in excluded_paths:
        # 获取当前时间
        last_access_times = time.time()
        logger.debug(f"Update path {request.url.path} to update time {last_access_times}")
        requested_session = request.headers.get("x-session-id")
        env_session = os.getenv("SESSION_ID_ENV", None)
        if requested_session and env_session and requested_session != env_session:
            logger.error(f"Requested session {requested_session} does not match env session {env_session}")
            return JSONResponse(
                status_code=403,
                content={
                    "detail": f"Forbidden to access this session."}
            )
        else:
            logger.debug(f"Ignore session check, requested session {requested_session} and env session {env_session}")

    # 调用下一个中间件或路由处理程序
    return await call_next(request)


@ci_app.get("/is_alive")
async def is_alive(idle_timeout_sec: int = Query(3600)):
    """
        Download file endpoint
        Query params:
            idle_timeout_sec: int - idle timeout in seconds
        """
    return {
        "last_access_time": last_access_times,
        "is_alive": time.time() < last_access_times + idle_timeout_sec
    }

@ci_app.post("/file/upload_to_s3")
async def upload_file(cmd: FileUploadRequest = Body()):
    """
    Upload a file to S3. If file size exceeds threshold, return size information instead.

    Request body:
    {
        "file_path": str,         # The local file path to upload
        "presigned_url": str      # The presigned URL to upload to
    }

    Returns:
    - For small files: Uploads the file and returns success response
    - For large files: Returns file information for multipart upload
    """
    try:
        file_path = Path(cmd.file_path).resolve()
        if not file_path.exists():
            raise HTTPException(status_code=404, detail="File not found")
        if not file_path.is_file():
            raise HTTPException(status_code=400, detail="Path is not a file")

        file_size = file_path.stat().st_size
        content_type = mimetypes.guess_type(str(file_path))[0] or "application/octet-stream"
        file_name = file_path.name

        if file_size > MULTIPART_THRESHOLD:
            return {
                "status": "requires_multipart",
                "message": "File size exceeds single upload limit",
                "file_name": file_name,
                "content_type": content_type,
                "file_size": file_size,
                "requires_multipart": True,
                "recommended_part_size": MULTIPART_THRESHOLD,
                "estimated_parts": file_size // MULTIPART_THRESHOLD + 1
            }

        with open(file_path, 'rb') as f:
            content = f.read()

        upload_result = await upload_to_presigned_url(
            data=content,
            presigned_url=cmd.presigned_url,
            content_type=content_type,
            filename=file_name
        )

        if not upload_result:
            raise HTTPException(status_code=500, detail="Failed to upload file")

        return {
            "status": "success",
            "message": "File uploaded successfully",
            "file_name": file_name,
            "content_type": content_type,
            "file_size": file_size,
            "requires_multipart": False,
            "upload_result": {"success": True, "uploaded": True}
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error handling file upload: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@ci_app.post("/file/multipart_upload_to_s3")
async def multipart_upload(cmd: MultipartUploadRequest = Body(...)):
    """
    使用预签名URLs上传文件分片  # Upload file chunks using presigned URLs
    
    Request body:
    {
        "file_path": str,              # 要上传的文件路径  # File path to upload
        "presigned_urls": [            # 预签名URL列表  # List of presigned URLs
            {
                "part_number": int,    # 分片编号（从1开始）  # Part number (starting from 1)
                "url": str             # 该分片的预签名URL  # Presigned URL for this part
            },
            ...
        ],
        "part_size": int              # 每个分片的大小（字节）  # Size of each part in bytes
    }
    """
    try:
        print("1")
        file_path = Path(cmd.file_path).resolve()
        if not file_path.exists():
            raise HTTPException(status_code=404, detail="File not found")
        if not file_path.is_file():
            raise HTTPException(status_code=400, detail="Path is not a file")

        file_size = file_path.stat().st_size
        expected_parts = math.ceil(file_size / cmd.part_size)

        if len(cmd.presigned_urls) != expected_parts:
            raise HTTPException(
                status_code=400,
                detail=f"Number of presigned URLs ({len(cmd.presigned_urls)}) does not match expected parts ({expected_parts})"
            )

        results = await upload_file_parts(str(file_path), cmd.presigned_urls, cmd.part_size)

        successful = sum(1 for r in results if r.success)
        failed = len(results) - successful

        response = MultipartUploadResponse(
            status="success" if failed == 0 else "partial_success",
            message="All parts uploaded successfully" if failed == 0 else f"Uploaded {successful}/{len(results)} parts successfully",
            file_name=file_path.name,
            parts_results=results,
            successful_parts=successful,
            failed_parts=failed
        )

        if failed > 0:
            return response, 206

        return response
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error in multipart upload: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@ci_app.get("/file/zip")
async def get_zipped_file(path: str):
    """
    Download file endpoint
    Query params:
        path: str - The file path to download
    """
    try:
        # Check if directory exists
        if not os.path.exists(path):
            raise HTTPException(status_code=404, detail="File not found")

        # Get the project name from the directory
        project_name = os.path.basename(path.rstrip('/'))

        # Path for the output zip file
        output_zip = f"/tmp/{project_name}.zip"
        success, message = create_zip_archive(path, output_zip)
        if not success:
            raise HTTPException(status_code=500, detail=message)

        file_path = Path(output_zip).resolve()
        if not file_path.exists():
            raise HTTPException(status_code=404, detail="File not found")
        if not file_path.is_file():
            raise HTTPException(status_code=400, detail="Compressed file is not a regular file")

        return FileResponse(
            path=str(file_path),
            filename=file_path.name,
            media_type="application/octet-stream"
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error serving file: {e}")
        raise HTTPException(status_code=500, detail=str(e))

max_download_file_MB = 500  # 500MB
max_download_file_size = max_download_file_MB * 1024 * 1024

@ci_app.get("/file")
async def get_file(path: str):
    """
    Download file endpoint
    Query params:
        path: str - The file path to download
    """
    try:
        file_path = Path(path).resolve()
        if not file_path.exists():
            raise HTTPException(status_code=404, detail="File not found")
        if not file_path.is_file():
            raise HTTPException(status_code=400, detail="Given path is not a regular file")

        file_size = file_path.stat().st_size
        if file_size > max_download_file_size:
            raise HTTPException(status_code=400, detail=f"File size exceeds {max_download_file_MB}MB limit")

        return FileResponse(
            path=str(file_path),
            filename=file_path.name,
            media_type="application/octet-stream"
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error serving file: {e}")
        raise HTTPException(status_code=500, detail=str(e))


class DownloadItem(BaseModel):
    url: str
    filename: str


class DownloadRequest(BaseModel):
    files: List[DownloadItem]
    folder: str | None = None


class DownloadResult(BaseModel):
    filename: str
    success: bool
    error: str | None = None


@ci_app.post("/request-download-attachments")
async def batch_download(cmd: DownloadRequest):
    """
    Batch download files endpoint
    Request body:
    {
        "files": [
            {
                "url": "https://example.com/file1.pdf",
                "filename": "file1.pdf"
            },
            ...
        ],
        "folder": "optional/subfolder/path"  # Optional folder to save files /home/ubuntu/upload/optional/subfolder/
    }
    """
    try:
        results = []

        async def download_file(client, item):
            file_name = os.path.basename(item.filename)
            base_path = "/home/ubuntu/upload/"
            target_path = base_path

            if hasattr(cmd, "folder") and cmd.folder:
                subfolder = cmd.folder.strip('/')
                target_path = os.path.join(base_path, subfolder)

            os.makedirs(target_path, exist_ok=True)
            file_path = os.path.join(target_path, file_name)

            try:
                response = await client.get(item.url)
                if response.status_code != 200:
                    return DownloadResult(
                        filename=file_name,
                        success=False,
                        error=f"HTTP {response.status_code}"
                    )

                content = response.read()
                with open(file_path, 'wb') as f:
                    f.write(content)

                return DownloadResult(filename=file_name, success=True)
            except Exception as e:
                return DownloadResult(
                    filename=file_name,
                    success=False,
                    error=str(e)
                )

        async with httpx.AsyncClient() as client:
            tasks = [download_file(client, item) for item in cmd.files]
            results = await asyncio.gather(*tasks)

        success_count = sum(1 for r in results if r.success)
        fail_count = len(results) - success_count

        return {
            "status": "completed",
            "total": len(results),
            "success_count": success_count,
            "fail_count": fail_count,
            "results": results
        }
    except Exception as e:
        logger.error(f"Error in batch download: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@ci_app.post("/file/upload_local")
async def upload_local_file(
    path: str = Form(),
    overwrite: bool = Form(True),
    file: UploadFile = File(...)
):
    """
    上传文件到服务器本地路径
    
    参数:
    - path: 服务器上的目标文件路径
    - overwrite: 是否覆盖已存在的文件 (默认: True)
    - file: 上传的文件
    
    返回:
    {
        "status": "success" | "error",
        "message": str,
        "file_path": str,
        "file_size": int,
        "content_type": str
    }
    """
    try:
        # 验证文件路径安全性
        target_path = Path(path).resolve()
        
        # 安全检查：确保路径在允许的目录内（可根据需要调整）
        allowed_base_paths = [
            Path("/mnt").resolve(),
            Path("/tmp").resolve(),
            Path("/sandboxdata/workspace").resolve(),
        ]
        
        path_allowed = any(
            str(target_path).startswith(str(base_path)) 
            for base_path in allowed_base_paths
        )
        
        if not path_allowed:
            raise HTTPException(
                status_code=403,
                detail=f"Upload to path {target_path} is not allowed. Allowed paths: {[str(p) for p in allowed_base_paths]}"
            )

        # 校验目标文件名长度，按 UTF-8 字节数判断
        filename_limit_bytes = FILENAME_MAX_BYTES
        filename_bytes = len(target_path.name.encode("utf-8"))
        if filename_bytes > filename_limit_bytes:
            raise HTTPException(
                status_code=400,
                detail=(
                    f"Filename too long: {filename_bytes} bytes exceeds limit "
                    f"{filename_limit_bytes} bytes"
                ),
            )
        
        # 检查文件是否已存在
        if target_path.exists() and not overwrite:
            raise HTTPException(
                status_code=409, 
                detail=f"File {target_path} already exists. Set overwrite=true to replace it."
            )
        # 创建目录
        target_path.parent.mkdir(parents=True, exist_ok=True)
        
        # 获取文件信息
        content_type = file.content_type or "application/octet-stream"
        
        # 写入文件
        file_size = 0
        with open(target_path, "wb") as f:
            while chunk := await file.read(8192):  # 8KB chunks
                f.write(chunk)
                file_size += len(chunk)
        
        logger.info(f"Successfully uploaded file to {target_path}, size: {file_size} bytes")
        
        return {
            "status": "success",
            "message": "File uploaded successfully",
            "file_path": str(target_path),
            "file_size": file_size,
            "content_type": content_type,
            "original_filename": file.filename
        }
        
    except HTTPException:
        raise
    except OSError as e:
        logger.error(f"Error uploading file: {e}")
        # 清理可能创建的部分文件
        try:
            if target_path.exists():
                target_path.unlink()
        except:
            pass

        if e.errno == errno.ENAMETOOLONG:
            raise HTTPException(
                status_code=400,
                detail=f"Filename or path too long: {str(e)}"
            )
        raise HTTPException(status_code=500, detail=f"Failed to upload file: {str(e)}")
    except Exception as e:
        logger.error(f"Error uploading file: {e}")
        # 清理可能创建的部分文件
        try:
            if target_path.exists():
                target_path.unlink()
        except:
            pass
        raise HTTPException(status_code=500, detail=f"Failed to upload file: {str(e)}")
    finally:
        try:
            await file.close()
        except:
            pass

@ci_app.post("/text_editor")
async def text_editor_endpoint(cmd: TextEditorAction):
    """Endpoint for text editor"""
    try:
        result = await text_editor.run_action(cmd)
        assert result.file_output, "text editor action must has an output"

        return TextEditorActionResult(
            status="success",
            result=result
        ).model_dump()
    except ToolError as e:
        logger.error(f"Error: {e}")
        return TextEditorActionResult(
            status="success",
            result=ToolResult(
                success=False,
                result="text editor error",
                error=e.message,
                file_output="",
                file_info=None
            )
        ).model_dump()
    except Exception as e:
        logger.error(f"Error: {e}")
        return TextEditorActionResult(
            status="error",
            error=str(e),
            result=ToolResult(
                success=False,
                result="text editor error",
                error=str(e),
                file_output="",
                file_info=None
            )
        ).model_dump()


@ci_app.get("/healthz")
async def healthz():
    wait_for_port("127.0.0.1", 9222)
    """Health check endpoint."""
    return {"status": "ok"}


class ProjectType(str, Enum):
    FRONTEND = 'frontend'
    BACKEND = 'backend'
    NEXTJS = 'nextjs'


class ZipAndUploadRequest(BaseModel):
    directory: str
    bucket: str
    ak: str
    endpoint: str


class ZipAndUploadResponse(BaseModel):
    status: str
    message: str
    download_url: str | None = None
    error: str | None = None


@ci_app.post("/zip-and-upload")
async def zip_and_upload(request: ZipAndUploadRequest):
    """
    Zip a directory (excluding node_modules) and upload to ToS
    """
    try:
        # Check if directory exists
        if not os.path.exists(request.directory):
            return ZipAndUploadResponse(
                status="error",
                message=f"Directory {request.directory} not found",
                error=f"Directory {request.directory} does not exist"
            ).model_dump()

        # Get the project name from the directory
        project_name = os.path.basename(request.directory.rstrip('/'))

        # Path for the output zip file
        output_zip = f"/tmp/{project_name}.zip"

        # Create the zip archive
        success, message = create_zip_archive(request.directory, output_zip)

        if not success:
            return ZipAndUploadResponse(
                status="error",
                message=f"Failed to create zip file for directory {request.directory}",
                error=message
            ).model_dump()

        if not os.path.exists(output_zip):
            return ZipAndUploadResponse(
                status="error",
                message=f"Zip file was not created for {request.directory}",
                error="Zip operation failed"
            ).model_dump()

        # Upload the zip to ToS
        succ, msg = file_helper.upload_file(request.bucket, request.ak, request.endpoint, output_zip,
                                            f"{project_name}.zip")
        if not succ:
            return ZipAndUploadResponse(
                status="error",
                message=f"Zip file was not created for {request.directory}",
                error=msg
            ).model_dump()

        # Clean up
        os.remove(output_zip)

        return ZipAndUploadResponse(
            status="success",
            download_url=msg,
            message=f"Successfully processed directory {request.directory} and uploaded to ToS"
        ).model_dump()
    except Exception as e:
        logger.error(f"Error in zip-and-upload: {str(e)}")

        return ZipAndUploadResponse(
            status="error",
            message="Internal server error",
            error=str(e)
        ).model_dump()


ci_app.include_router(CIRouter)
ci_app.include_router(metrics_server_router)

from application.runtime_server import runtime_server_router
logger.info("Include runtime_server_router")
ci_app.include_router(runtime_server_router)
