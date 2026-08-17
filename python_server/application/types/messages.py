import os
from typing import Literal, NamedTuple
from pydantic import BaseModel
# from application.types.browser_types import BrowserAction, BrowserActionResult

TextEditorCommand = Literal[
    'view', 'create', 'write', 'str_replace', 'find_content', 'find_file', 'reset', 'zip_and_upload', 'zip_and_download',
    'file_merge']
StringReplaceMode = Literal[
    'ALL', 'FIRST', 'LAST']


class CommonApiResult(BaseModel):
    status: Literal['success', 'error']
    error: str | None = None
    error_code: int | None = None

class FileOperation(BaseModel):
    path: str
    file_text: str | None = None  # for write command
    old_str: str | None = None    # for str_replace command
    new_str: str | None = None    # for str_replace command
    append: bool | None = None
    trailing_newline: bool | None = None
    leading_newline: bool | None = None

class MultiTextEditorAction(BaseModel):
    command: TextEditorCommand
    sudo: bool | None = None
    file_operations: list[FileOperation]

class TextEditorAction(BaseModel):
    command: TextEditorCommand
    path: str
    sudo: bool | None = None
    file_text: str | None = None
    view_range: list[int] | None = None
    old_str: str | None = None
    new_str: str | None = None
    replace_mode: str | None = None
    insert_line: int | None = None
    glob: str | None = None
    regex: str | None = None
    append: bool | None = None
    trailing_newline: bool | None = None
    leading_newline: bool | None = None
    bucket: str | None = None
    ak: str | None = None
    endpoint: str | None = None
    to_merge_paths: list[str] | None = None
    overwrite: bool | None = None


class FileInfo(BaseModel):
    path: str
    content: str
    old_content: str | None = None
    file_type: str | None = None
    diff_text: str | None = None

class ReplacementResult(NamedTuple):
    """字符串替换操作的详细结果"""
    new_content: str | None = None             # 替换后的内容
    replacements: int | None = None            # 替换次数
    diff_text: str   | None = None             # diff 内容。unified diff 格式

class MultiFileResult(BaseModel):
    path: str
    success: bool
    result: str
    error: str | None = None
    file_output: str
    file_info: FileInfo | None = None

class MultiToolResult(BaseModel):
    success: bool
    result: str
    error: str | None = None
    file_results: list[MultiFileResult]
    file_output: str

class MultiTextEditorActionResult(CommonApiResult):
    result: MultiToolResult

class ToolResult(BaseModel):
    success: bool
    result: str
    error: str | None = None
    file_output: str
    file_info: FileInfo | None = None


class TextEditorActionResult(CommonApiResult):
    result: ToolResult


# class BrowserActionRequest(BaseModel):
#     action: BrowserAction
#     screenshot_presigned_url: str | None = None
#     clean_screenshot_presigned_url: str | None = None


# class BrowserActionResponse(CommonApiResult):
#     result: BrowserActionResult | None = None


class TerminalWriteApiRequest(BaseModel):
    text: str
    enter: bool | None = None


class TerminalExecuteApiRequest(BaseModel):
    command: str
    exec_dir: str | None = None
    is_async: bool = False


class TerminalApiResult(BaseModel):
    success: bool
    result: str
    error: str | None = None
    terminal_output: list[str]
    terminal_id: str
    terminal_status: str


class TerminalApiResponse(CommonApiResult):
    result: TerminalApiResult


TerminalInputMessageType = Literal['command', 'view', 'view_last', 'kill_process', 'reset', 'reset_all']
TerminalOutputMessageType = Literal['update', 'finish', 'partial_finish', 'error', 'history', 'action_finish']
TerminalCommandMode = Literal['run', 'send_line', 'send_key', 'send_control']
TerminalStatus = Literal['idle', 'running']


class TerminalInputMessage(BaseModel):
    type: TerminalInputMessageType
    terminal: str
    action_id: str
    command: str | None = None
    mode: TerminalCommandMode | None = None
    exec_dir: str | None = None

    def create_response(self, type: TerminalOutputMessageType, result: str, output: list[str],
                        terminal_status: TerminalStatus, sub_command_index: int = 0):
        return TerminalOutputMessage(
            type=type,
            terminal=self.terminal,
            action_id=self.action_id,
            sub_command_index=sub_command_index,
            result=result,
            output=output,
            terminal_status=terminal_status
        )


class TerminalOutputMessage(BaseModel):
    type: TerminalOutputMessageType
    terminal: str
    action_id: str
    sub_command_index: int = 0
    result: str | None = None
    output: list[str]
    terminal_status: Literal['idle', 'running', 'unknown']


try:
    DEFAULT_CODE_INTERPRETER_TIMEOUT = int(os.getenv("CODE_INTERPRETER_TIMEOUT", "45"))
except ValueError:
    DEFAULT_CODE_INTERPRETER_TIMEOUT = 45


class CodeInterpreterRequest(BaseModel):
    workspace: str = "/mnt"
    code: str
    timeout: int = DEFAULT_CODE_INTERPRETER_TIMEOUT
    kernel_id: str = "defaultCIKernel"

class CIFileInfo(BaseModel):
    path: str = ""
    size: int = 0

class CodeInterpreterResult(BaseModel):
    base64_image: str
    path_list: list[str]
    file_info_list: list[CIFileInfo] = []
    ci_output: str
    error: str | None = None
    error_type: str=""
    error_detail: str=""
    exec_result: str | None = None
    success: bool = False
    bad_code_detect_result: str | None = None

def EmptyCodeInterpreterResult() -> CodeInterpreterResult:
    return CodeInterpreterResult(
        base64_image="",
        path_list=[],
        ci_output="",
        error="",
        exec_result="",
        success=False,
        bad_code_detect_result=""
    )

class CodeInterpreterResponse(CommonApiResult):
    result: CodeInterpreterResult
