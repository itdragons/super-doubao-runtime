import os
import shutil
import tempfile
from io import FileIO
from pathlib import Path

# import bytedtos
import uuid

from application.tools.file.retry_util import retry


def create_zip_archive(source_dir: str, output_zip: str) -> tuple[bool, str]:
    """
    Create a zip archive of a directory, excluding node_modules and .next

    Args:
        source_dir: Path to the directory to zip
        output_zip: Path for the output zip file

    Returns:
        tuple[bool, str]: (success, error_message)
    """
    try:
        source_path = Path(source_dir).resolve()
        if not source_path.is_dir():
            return False, f"Directory '{source_dir}' does not exist"

        if not output_zip.endswith('.zip'):
            output_zip += '.zip'

        exclude_patterns = [
            'node_modules',
            '.next',
            '.open-next',
            '.turbo',
            '.wrangler',
            '.git'
        ]

        def copy_files(src, dst, ignores=exclude_patterns):
            for item in os.listdir(src):
                if item in ignores:
                    continue

                s = os.path.join(src, item)
                d = os.path.join(dst, item)

                if os.path.isdir(s):
                    shutil.copytree(s, d, ignore=lambda x, y: ignores)
                else:
                    shutil.copy2(s, d)

        # Create a temporary directory for the archive
        with tempfile.TemporaryDirectory() as temp_dir:
            source_copy = os.path.join(temp_dir, 'source')
            os.makedirs(source_copy)

            # Copy files to the temporary directory, excluding patterns
            copy_files(str(source_path), source_copy)

            # Create the zip archive
            shutil.make_archive(output_zip[:-4], 'zip', source_copy)

        return True, ''
    except Exception as e:
        return False, f"Failed to create zip archive: {str(e)}"

def upload_file(bucket: str, ak: str, endpoint: str, local_path: str, file_name: str) -> (bool, str):
    pass
#     tos_key = f"{uuid.uuid4().hex}/{file_name}"
#     try:
#         return _do_upload_file(bucket, ak, endpoint, local_path, tos_key)
#     except Exception as e:
#         return False, f"ToS upload error: {e}"
#
# @retry(max_retries=3, delay=2)
# def _do_upload_file(bucket: str, ak: str, endpoint: str, local_path: str, tos_key: str) -> (bool, str):
#     client = bytedtos.Client(
#         bucket=bucket,
#         access_key=ak,
#         # endpoint 是可选参数，设置是否通过子域名初始化
#         endpoint=endpoint,
#         # stream 是可选参数，设置是否流式下载
#         stream=False,
#         # remote_psm 是可选参数，设置客户端的 PSM
#         # remote_psm=client_psm,
#         # timeout 是可选参数，设置请求超时
#         timeout=60,
#         # connection_time 是可选参数，设置连接超时
#         connect_timeout=60,
#         # 设置connection_pool_size =10，将连接池大小设置为 10
#         connection_pool_size=10,
#     )
#     file_io = FileIO(local_path, "r")
#     resp = client.put_object(tos_key, file_io)
#     if 200 <= resp.status_code < 300:
#         return True, f"https://tosv.byted.org/obj/{bucket}/{tos_key}"
#     else:
#         raise Exception(f"ToS upload returned status code {resp.status_code}")