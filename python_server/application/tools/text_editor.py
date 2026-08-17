import os
from pathlib import Path
import re
from typing import List, Optional, get_args
import asyncio

from application.logger import logger
from application.helpers.tool_helpers import MAX_RESPONSE_LEN, TRUNCATED_MESSAGE, maybe_truncate, run_shell
from application.tools.base import ToolError, DEFAULT_WORKSPACE_DIR
from application.tools.file.file_helper import create_zip_archive, upload_file
from application.types.messages import FileInfo, TextEditorAction, ToolResult, ReplacementResult
from application.types.messages import TextEditorCommand as Command
from application.types.messages import MultiTextEditorAction, MultiToolResult, MultiFileResult, FileOperation
import application.helpers.utils
import application.helpers.file_utils

SNIPPET_LINES: int = 4

class MultiTextEditor:
    '''
    A multi-file editor tool that allows concurrent editing of multiple files.
    Supports write and str_replace commands only.
    '''

    def __init__(self):
        self.text_editor = TextEditor()

    async def run_action(self, action: MultiTextEditorAction) -> MultiToolResult:
        """
        Run the specified editor action on multiple files concurrently.

        Args:
            action: The multi-file editor action to run

        Returns:
            MultiToolResult: The aggregated result of all file operations
        """
        # if action.command not in ['write', 'str_replace']:
        #     return MultiToolResult(
        #         success=False,
        #         result="Unsupported command",
        #         error=f"Command '{action.command}' is not supported. Only 'write' and 'str_replace' are allowed.",
        #         file_results=[],
        #         file_output="Error: Unsupported command"
        #     )

        if not action.file_operations:
            return MultiToolResult(
                success=False,
                result="Empty file operations list",
                error="file_operations cannot be empty",
                file_results=[],
                file_output="Error: No file operations specified"
            )
        
        validation_error = self._validate_file_operations(action.command, action.file_operations)
        if validation_error:
            return MultiToolResult(
                success=False,
                result="Validation error",
                error=validation_error,
                file_results=[],
                file_output=f"Error: {validation_error}"
            )
        # Create tasks for concurrent execution
        tasks = []
        for path in action.path_list:
            # Create individual TextEditorAction for each file
            individual_action = TextEditorAction(
                command=action.command,
                path=file_op.path,
                sudo=action.sudo,
                file_text=file_op.file_text,
                old_str=file_op.old_str,
                new_str=file_op.new_str,
                append=file_op.append,
                trailing_newline=file_op.trailing_newline,
                leading_newline=file_op.leading_newline
            )
            tasks.append(self._process_single_file(individual_action, path))

        # Execute all tasks concurrently
        file_results = await asyncio.gather(*tasks, return_exceptions=True)

        # Process results
        processed_results = []
        successful_count = 0
        error_count = 0
        output_messages = []

        for i, result in enumerate(file_results):
            file_op = action.file_operations[i]
            path = file_op.path
            
            if isinstance(result, Exception):
                # Handle exceptions
                processed_results.append(MultiFileResult(
                    path=path,
                    success=False,
                    result="Exception occurred",
                    error=str(result),
                    file_output=f"Error processing {path}: {str(result)}",
                    file_info=None
                ))
                error_count += 1
                output_messages.append(f"FileOpError. {path}: {str(result)}")
            else:
                # Handle successful results
                processed_results.append(MultiFileResult(
                    path=path,
                    success=result.success,
                    result=result.result,
                    error=result.error,
                    file_output=result.file_output,
                    file_info=result.file_info
                ))
                
                if result.success:
                    successful_count += 1
                    output_messages.append(f"FileOpSuccess. {path}: {result.result}")
                else:
                    error_count += 1
                    output_messages.append(f"FileOpFailed. {path}: {result.error or result.result}")

        # Generate summary
        total_files = len(action.file_operations)
        overall_success = error_count == 0
        
        summary_result = f"Processed {total_files} files: {successful_count} successful, {error_count} failed"
        summary_output = f"Multi-file {action.command} operation completed.\n\n" + "\n".join(output_messages)

        return MultiToolResult(
            success=overall_success,
            result=summary_result,
            error=None if overall_success else f"{error_count} files failed to process",
            file_results=processed_results,
            file_output=summary_output
        )
    
    def _validate_file_operations(self, command: str, file_operations: list[FileOperation]) -> str | None:
        """
        Validate file operations based on the command type.
        
        Args:
            command: The command being executed
            file_operations: List of file operations to validate
            
        Returns:
            str | None: Error message if validation fails, None if valid
        """
        for i, file_op in enumerate(file_operations):
            if not file_op.path:
                return f"File operation {i}: path cannot be empty"
                
            if command == 'write':
                if file_op.file_text is None:
                    return f"File operation {i} ({file_op.path}): file_text is required for write command"
            elif command == 'str_replace':
                if not file_op.old_str:
                    return f"File operation {i} ({file_op.path}): old_str is required for str_replace command"
                if file_op.new_str is None:
                    return f"File operation {i} ({file_op.path}): new_str is required for str_replace command"
        
        return None
    
    async def _process_single_file(self, action: TextEditorAction, path: str) -> ToolResult:
        """
        Process a single file operation.
        
        Args:
            action: The text editor action for a single file
            path: The file path being processed
            
        Returns:
            ToolResult: The result of the single file operation
        """
        try:
            return await self.text_editor.run_action(action)
        except Exception as e:
            return ToolResult(
                success=False,
                result="Exception in file processing",
                error=str(e),
                file_output=f"Error processing {path}: {str(e)}",
                file_info=None
            )

class TextEditor:
    '''
    A filesystem editor tool that allows the agent to view, create, and edit files.
    The tool parameters are defined by Anthropic and are not editable.
    '''

    def __init__(self):
        super().__init__()

    async def run_action(self, action: TextEditorAction) -> ToolResult:
        """
        Run the specified editor action.

        Args:
            action: The editor action to run

        Returns:
            ToolResult: The result of the action
        """
        command = action.command

        # todo: zhangxinchun, hard code workspace
        if command == "reset" and action.path == "":
            action.path = DEFAULT_WORKSPACE_DIR

        path = Path(action.path)
        sudo = action.sudo or False

        try:
            # Validate the path
            path = self.validate_path(command, path)

            # Execute the appropriate command
            if command == 'view_dir':
                return await self.view_dir(path)
            elif command == 'view':
                return await self.view(path, action.view_range, sudo)
            elif command == 'create':
                return await self.write_file(path, action.file_text or '', sudo, False, False, False)
            elif command == 'write':
                return await self.write_file(
                    path,
                    action.file_text or '',
                    sudo,
                    action.append or False,
                    action.trailing_newline or False,
                    action.leading_newline or False
                )
            elif command == 'str_replace':
                return await self.file_str_replace(path, action.old_str or '', action.new_str or '', action.replace_mode, sudo)
            elif command == 'find_content':
                return await self.find_content(path, action.regex or '', sudo)
            elif command == 'find_file':
                return await self.find_file(path, action.glob or '*')
            elif command == 'reset':
                return await self.reset(path)
            elif command == 'zip_and_upload':
                return await self.zip_and_upload(action)
            elif command == 'file_merge':
                return await self.file_merge(action)
            else:
                raise ToolError(
                    f"Unrecognized command {command}. The allowed commands for the TextEditor tool are: {', '.join(get_args(Command))}")

        except ToolError as e:
            logger.exception("text_editor error: %s", e)
            return ToolResult(
                success=False,
                result="text editor error",
                error=e.message,
                file_output=str(e)
            )
        except Exception as e:
            raise e

    def validate_path(self, command: Command, path: Path) -> Path:
        '''
        Check that the path/command combination is valid.
        
        Args:
            command: The command being performed
            path: The path to validate
            
        Returns:
            Path: The validated path
            
        Raises:
            ToolError: If the path is invalid for the given command
        '''
        # if path.is_absolute() and DEFAULT_WORKING_DIR:
        #     path = Path(DEFAULT_WORKING_DIR) / path.relative_to('/')

        if not path.exists() and command not in ['create', 'write', 'reset', 'file_merge']:
            raise ToolError(f'The path {path} does not exist. Please provide a valid path.')

        if path.exists():
            if command == 'create':
                if path.is_file() or path.stat().st_size > 0:
                    raise ToolError(
                        f'Non-empty file already exists at: {path}. Cannot overwrite non-empty files using command `create`.')
            elif command in ('view_dir', 'find_file'):
                if not path.is_dir():
                    raise ToolError(f'The path {path} is not a directory.')
            elif command in ('move', 'delete', 'reset', 'zip_and_upload'):
                pass
            elif path.is_dir():
                raise ToolError(
                    f'The path {path} is a directory. Directory operations are not supported for this command.')

        return path

    async def view_dir(self, path: Path) -> ToolResult:
        '''
        List contents of a directory.
        
        Args:
            path: Directory path to list
            
        Returns:
            ToolResult: The directory listing
        '''
        cmd = f'ls -la "{path}"'
        return_code, stdout, stderr = await run_shell(cmd)

        if return_code != 0:
            raise ToolError(f"Failed to list directory {path}: {stderr}")

        return ToolResult(
            success=True,
            result="view directory success",
            error=None,
            file_output=f"Directory contents of {path}:\n\n{stdout}"
        )

    async def view(self, path: Path, view_range: Optional[List[int]], sudo: bool) -> ToolResult:
        '''
        View the content of a file.
        
        Args:
            path: File path to view
            view_range: Optional line range to view [start, end]
            sudo: Whether to use sudo privileges
            
        Returns:
            ToolResult: The file content
        '''
        # Read the file content
        file_content = await self.read_file(path, sudo)

        # Apply view range if specified
        if view_range and len(view_range) == 2:
            start, end = view_range
            lines = file_content.split('\n')

            # Adjust for 1-based indexing and ensure valid range
            start = max(1, min(start, len(lines))) - 1
            end = max(start + 1, min(end, len(lines)))

            file_content = '\n'.join(lines[start:end])

        # Format the output
        output = self._make_output(file_content, str(path), 1, True)

        # Create file info
        file_info = FileInfo(path=str(path), content=file_content)

        return ToolResult(
            success=True,
            result="view file success",
            error=None,
            file_output=output,
            file_info=file_info
        )

    async def file_str_replace(self, path: Path, old_str: str, new_str: str, replace_mode: str, sudo: bool) -> ToolResult:
        '''
        Replace occurrences of old_str with new_str in the file.
        
        Args:
            path: File path to modify
            old_str: String to replace
            new_str: Replacement string
            sudo: Whether to use sudo privileges
            
        Returns:
            ToolResult: The result of the operation
        '''
        if not old_str:
            raise ToolError("old_str cannot be empty")
        # Read the file content
        old_content = await self.read_file(path, sudo)

        # Perform the replacement
        if old_str not in old_content:
            return ToolResult(
                success=True,
                result="str_replace not found",
                error=None,
                file_output=f"Warning: The string '{old_str}' was not found in {path}.",
                file_info=FileInfo(path=str(path), content=old_content)
            )

        # new_content = old_content.replace(old_str, new_str)

        replacement_result = self._do_string_replacement(old_content, old_str, new_str, replace_mode)
        new_content = replacement_result.new_content
        replacements = replacement_result.replacements

        file_type = app.helpers.file_utils.get_file_type(path)
        # Write the modified content back to the file
        await self.write_file(path, new_content, sudo, False, False, False)

        return ToolResult(
            success=True,
            result="str_replace success",
            error=None,
            file_output=f"Successfully replaced {replacements} occurrence(s) of '{old_str}' with '{new_str}' in {path}.",
            file_info=FileInfo(path=str(path), content=new_content, old_content=old_content,file_type=file_type,diff_text=replacement_result.diff_text),
        )

    def _do_string_replacement(self, content: str, old_str: str, new_str: str, replace_mode: str) -> ReplacementResult:
        """
        根据指定模式执行字符串替换
        Args:
            content: 原始内容
            old_str: 要替换的字符串
            new_str: 替换后的字符串
            replace_mode: 替换模式 ('ALL', 'FIRST', 'LAST')
        Returns:
            ReplacementResult: 包含替换结果的详细信息
        """
        if replace_mode == 'ALL':
            new_content = content.replace(old_str, new_str)
            replacements = content.count(old_str)
        elif replace_mode == 'FIRST':
            new_content = content.replace(old_str, new_str, 1)
            replacements = 1 if old_str in content else 0
        elif replace_mode == 'LAST':
            # 找到最后一个匹配项的位置
            last_index = content.rfind(old_str)
            if last_index != -1:
                new_content = content[:last_index] + new_str + content[last_index + len(old_str):]
                replacements = 1
            else:
                new_content = content
                replacements = 0
        else:
            raise ToolError(f"Invalid replace_mode: {replace_mode}. Must be one of: 'ALL', 'FIRST', 'LAST'")
        
        diff_text = app.helpers.utils.diff(content, new_content)
        
        return ReplacementResult(
            new_content=new_content,
            replacements=replacements,
            diff_text=diff_text
        )

    async def find_content(self, path: Path, regex: str, sudo: bool) -> ToolResult:
        '''
        Find content matching regex in the file.
        
        Args:
            path: File path to search
            regex: Regular expression pattern to search for
            sudo: Whether to use sudo privileges
            
        Returns:
            ToolResult: The search results
        '''
        if not regex:
            raise ToolError("regex pattern cannot be empty")

        # Construct the grep command
        grep_cmd = f"{'sudo ' if sudo else ''}grep -n '{regex}' '{path}'"
        return_code, stdout, stderr = await run_shell(grep_cmd)

        # Read the file content for the file_info
        file_content = await self.read_file(path, sudo)

        if return_code != 0 and not stderr:
            # No matches found (grep returns 1 when no matches)
            return ToolResult(
                success=True,
                result="find_content not found",
                error=None,
                file_output=f"No matches found for pattern '{regex}' in {path}.",
                file_info=FileInfo(path=str(path), content=file_content)
            )
        elif return_code != 0:
            # Error occurred
            raise ToolError(f"Error searching file: {stderr}")

        # Format the output
        results = [f"Line {match.split(':', 1)[0]}: {match.split(':', 1)[1]}" for match in stdout.strip().split('\n') if
                   match]
        output = f"Found {len(results)} matches for pattern '{regex}' in {path}:\n\n" + '\n'.join(results)

        return ToolResult(
            success=True,
            result="find_content success",
            error=None,
            file_output=output,
            file_info=FileInfo(path=str(path), content=file_content)
        )

    async def file_merge(self, action: TextEditorAction) -> ToolResult:
        if action.to_merge_paths is None or len(action.to_merge_paths) == 0:
            raise ToolError(f"To be merged file list: {action.to_merge_paths} is empty")

        for p in action.to_merge_paths:
            path = Path(p).resolve()
            if not path.exists() or not path.is_file():
                raise ToolError(f"Path {p} does not exist or is not a regular file.")

        output = Path(action.path).resolve()
        if output.exists() and not action.overwrite:
            raise ToolError(
                f"Output file {output} already exists. Not allowed to overwrite when overwrite={action.append}.")

        if not output.exists():
            open(output, 'w').close()  # create empty target file

        with open(output, 'w') as outfile:
            for file in action.to_merge_paths:
                with open(file, 'r') as infile:
                    outfile.write(infile.read().strip() + '\n')

        return ToolResult(
            success=True,
            result="file_merge success",
            error=None,
            file_output=f"Successfully merged files {action.to_merge_paths} into {action.path}."
        )

    async def zip_and_upload(self, action: TextEditorAction) -> ToolResult:
        # Get the project name from the directory
        project_name = os.path.basename(action.path.rstrip('/'))

        # Path for the output zip file
        output_zip = f"/tmp/{project_name}.zip"

        # Create the zip archive
        success, message = create_zip_archive(action.path, output_zip)

        if not success:
            raise ToolError(f"Failed to create zip file for directory {action.path}")

        if not os.path.exists(output_zip):
            raise ToolError(f"Zip file was not created for {action.path}")

        # Upload the zip to ToS
        succ, resp = upload_file(action.bucket, action.ak, action.endpoint, output_zip,
                                 f"{project_name}.zip")
        if not succ:
            raise ToolError(f"Upload file was failed for {action.path}: error={resp}")

        # Clean up
        os.remove(output_zip)

        return ToolResult(
            success=True,
            result="zip_and_upload success",
            error=None,
            file_output=resp
        )

    async def reset(self, path: Path) -> ToolResult:
        """
        Reset content in the workspace.

        Args:
            path: Directory to reset

        Returns:
            ToolResult: The result of the reset operation
        """
        # remove the directory and create an empty one
        if path.exists():
            import shutil, os
            # 使用 shutil.rmtree 删除目录及其内容
            # 考虑到目录权限问题，忽略错误并用handle_error处理异常目录
            shutil.rmtree(path, onerror = self.handle_error)
            # 重新创建目录，忽略目录存在时抛出的异常
            try:
                os.makedirs(path, exist_ok = True)
            except Exception as e:
                raise ToolError(f"Failed to create directory {path}: {e}")
        else:
            return ToolResult(
                success=True,
                result="reset directory success",
                error=None,
                file_output=f"Directory not exist: {path}"
            )

        cmd = f'ls -la "{path}"'
        return_code, stdout, stderr = await run_shell(cmd)

        if return_code != 0:
            raise ToolError(f"Failed to list directory {path}: {stderr}")

        return ToolResult(
            success=True,
            result="reset directory success",
            error=None,
            file_output=f"Directory contents of {path}:\n\n{stdout}" if return_code == 0 else ""
        )

    def handle_error(self, func, path, exc_info):
        """
        自定义错误处理函数
        :param func: 引发错误的函数
        :param path: 引发错误的路径
        :param exc_info: 异常信息
        """
        logger.warn(f"操作 {func.__name__} 在路径 {path} 上失败: {exc_info}")

    async def find_file(self, path: Path, glob_pattern: str) -> ToolResult:
        '''
        Find files matching glob pattern in directory.
        
        Args:
            path: Directory path to search
            glob_pattern: Glob pattern to match files
            
        Returns:
            ToolResult: The search results
        '''
        if not glob_pattern:
            glob_pattern = "*"

        # Construct the find command
        find_cmd = f"find '{path}' -type f -name '{glob_pattern}' | sort"
        return_code, stdout, stderr = await run_shell(find_cmd)

        if return_code != 0:
            raise ToolError(f"Error finding files: {stderr}")

        # Format the output
        files = stdout.strip().split('\n')
        if not files or (len(files) == 1 and not files[0]):
            return ToolResult(
                success=True,
                result="find_file not found",
                error=None,
                file_output=f"No files matching pattern '{glob_pattern}' found in {path}."
            )

        output = f"Found {len(files)} files matching pattern '{glob_pattern}' in {path}:\n\n" + '\n'.join(files)

        return ToolResult(
            success=True,
            result="find_file success",
            error=None,
            file_output=output
        )

    async def read_file(self, path: Path, sudo: bool) -> str:
        '''
        Read the content of a file from a given path.
        
        Args:
            path: File path to read
            sudo: Whether to use sudo privileges
            
        Returns:
            str: The file content
            
        Raises:
            ToolError: If an error occurs while reading the file
        '''
        if not path.exists():
            raise ToolError(f"File does not exist: {path}")

        if path.is_dir():
            raise ToolError(f"Cannot read directory as file: {path}")

        # Construct the cat command
        cat_cmd = f"{'sudo ' if sudo else ''}cat '{path}'"
        return_code, stdout, stderr = await run_shell(cat_cmd)

        if return_code != 0:
            raise ToolError(f"Failed to read file {path}: {stderr}")

        return stdout

    async def write_file(self, path: Path, content: str, sudo: bool, append: bool,
                         trailing_newline: bool, leading_newline: bool) -> ToolResult:
        """
        Write content to a file.
        
        Args:
            path: File path to write to
            content: Content to write
            sudo: Whether to use sudo privileges
            append: If True, append content to file instead of overwriting
            trailing_newline: If True, add a newline at the end of content
            leading_newline: If True, add a newline at the beginning of content
            
        Returns:
            ToolResult: The result of the operation
            
        Raises:
            ToolError: If an error occurs while writing the file
        """
        # Create parent directories if they don't exist
        if not path.parent.exists():
            try:
                path.parent.mkdir(parents=True, exist_ok=True)
            except Exception as e:
                raise ToolError(f"Failed to create directory {path.parent}: {str(e)}")

        # Prepare the content
        if leading_newline and not content.startswith('\n'):
            content = '\n' + content

        if trailing_newline and not content.endswith('\n'):
            content = content + '\n'

        # Determine if we need to append or create new
        old_content = ""
        if path.exists() and path.is_file() and append:
            old_content = await self.read_file(path, sudo)
            content = old_content + content

        # Write to a temporary file first
        temp_path = path.with_name(f".tmp_{path.name}")
        with open(temp_path, 'w', encoding='utf-8') as f:
            f.write(content)

        # Move the temporary file to the destination
        if sudo:
            # Use sudo to move the file
            mv_cmd = f"sudo mv '{temp_path}' '{path}'"
            return_code, stdout, stderr = await run_shell(mv_cmd)

            if return_code != 0:
                raise ToolError(f"Failed to write file {path}: {stderr}")
        else:
            # Move without sudo
            try:
                temp_path.replace(path)
            except Exception as e:
                raise ToolError(f"Failed to write file {path}: {str(e)}")

        action = "Created" if not append or not path.exists() else "Updated"
        file_type = app.helpers.file_utils.get_file_type(path)
        return ToolResult(
            success=True,
            result="write file success",
            error=None,
            file_output=f"{action} file {path} successfully.",
            file_info=FileInfo(path=str(path), content=content, old_content=old_content if append else None, file_type=file_type),
        )

    def _make_output(self, file_content: str, file_descriptor: str, init_line: int = 1,
                     expand_tabs: bool = True) -> str:
        '''
        Format file content for output with line numbers.
        
        Args:
            file_content: The content to format
            file_descriptor: Description of the file (usually path)
            init_line: Initial line number
            expand_tabs: Whether to expand tabs to spaces
            
        Returns:
            str: Formatted output with line numbers
        '''
        if expand_tabs:
            file_content = file_content.expandtabs(4)

        header = f"Here's the result of running `cat -n` on {file_descriptor}:\n"
        line_width = 8  # Width for line numbers
        max_content_length = MAX_RESPONSE_LEN - len(header) - len(TRUNCATED_MESSAGE)
        lines = file_content.split('\n')
        line_num_chars = line_width * len(lines)
        max_content_length -= line_num_chars

        if len(file_content) > max_content_length:
            # Truncate the content
            content_parts = []
            current_length = 0

            for i, line in enumerate(lines):
                if current_length + len(line) + 1 > max_content_length:
                    break

                content_parts.append(line)
                current_length += len(line) + 1  # +1 for newline

            file_content = '\n'.join(content_parts)
            file_content = maybe_truncate(file_content, max_content_length)

        # Add line numbers
        numbered_lines = []
        for i, line in enumerate(file_content.split('\n')):
            line_num = i + init_line
            numbered_lines.append(f"{line_num:>{line_width - 1}}  {line}")

        return header + '\n'.join(numbered_lines)


text_editor = TextEditor()

multi_text_editor = MultiTextEditor()
