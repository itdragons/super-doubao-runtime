from pydantic import BaseModel
from typing import List, Optional, Dict, Any, Literal, Union


class PresignedUrlPart(BaseModel):
    part_number: int
    url: str

class MultipartUploadRequest(BaseModel):
    file_path: str
    presigned_urls: List[PresignedUrlPart]
    part_size: int

class PartUploadResult(BaseModel):
    part_number: int
    etag: Optional[str] = ""
    success: bool
    error: Optional[str] = None

class MultipartUploadResponse(BaseModel):
    status: str
    message: str
    file_name: str
    parts_results: List[PartUploadResult]
    successful_parts: int
    failed_parts: int


class ObjectReference(BaseModel):
    type: Literal[
        "multi_kernel_manager",
        "kernel_manager",
        "client",
        "callbacks",
    ]
    id: str


class MethodCall(BaseModel):
    message_type: Literal["call_request"] = "call_request"
    object_reference: ObjectReference
    request_id: str
    method: str
    args: List[Any]

    kwargs: Dict[str, Any]


class MethodCallException(BaseModel):
    message_type: Literal["call_exception"] = "call_exception"
    request_id: str
    type: str
    value: str
    traceback: List[str]


class MethodCallReturnValue(BaseModel):
    message_type: Literal["call_return_value"] = "call_return_value"
    request_id: str
    value: Any


class MethodCallObjectReferenceReturnValue(BaseModel):
    message_type: Literal["call_object_reference"] = "call_object_reference"
    request_id: str
    object_reference: ObjectReference


class UploadFileRequest(BaseModel):
    message_type: Literal["upload_file_request"] = "upload_file_request"
    destination: str


class UploadFileFromUrlRequest(BaseModel):
    message_type: Literal["upload_file_from_url_request"] = (
        "upload_file_from_url_request"
    )
    source_url: str
    destination: str


class DownloadFileToUrlRequest(BaseModel):
    message_type: Literal["download_file_to_url_request"] = (
        "download_file_to_url_request"
    )
    source: str
    destination_url: str


class ListMntDirResponse(BaseModel):
    message_type: Literal["list_mnt_directory_response"] = "list_mnt_directory_response"
    files: List[str]


class MntDirDetailResponse(BaseModel):
    message_type: Literal["mnt_dir_detail_response"] = "mnt_dir_detail_response"
    file: str
    update_time: str


class ListMntDirDetailResponse(BaseModel):
    message_type: Literal["list_mnt_directory_response"] = "list_mnt_directory_response"
    files: List[MntDirDetailResponse]


class CreateKernelRequest(BaseModel):
    message_type: Literal["create_kernel_request"] = "create_kernel_request"
    language: str


class CreateKernelResponse(BaseModel):
    message_type: Literal["create_kernel_response"] = "create_kernel_response"
    kernel_id: str


class GetKernelStateResponse(BaseModel):
    message_type: Literal["get_kernel_state_response"] = "get_kernel_state_response"
    time_remaining_ms: float


UserMachineRequest = Union[
    MethodCall,
    MethodCallException,
    MethodCallReturnValue,
    MethodCallObjectReferenceReturnValue,
]

UserMachineResponse = Union[
    MethodCall,
    MethodCallException,
    MethodCallReturnValue,
    MethodCallObjectReferenceReturnValue,
]


class UserMachineResponseTooLarge(Exception):
    pass
