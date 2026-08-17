import mimetypes
from pathlib import Path


# 可选：如果需要更准确的检测，安装 python-magic
try:
    import magic
    HAS_MAGIC = True
    print("HAS_MAGIC=true")
except ImportError:
    HAS_MAGIC = False
    print("HAS_MAGIC=false")


def get_file_type(file_path: Path):
    """
    获取文件类型（扩展名）
    使用多层次检测策略：扩展名 -> MIME类型 -> 文件头检测
    """
    if file_path.is_dir():
        return 'dir'

    # 检查文件是否存在
    if not file_path.exists():
        print("not exists")
        return ''

    # 尝试从文件扩展名获取
    file_ext = file_path.suffix
    if file_ext:
        print(f"file_ext={file_ext}")
        return file_ext.lower().lstrip('.')

    # 使用 python-magic 库
    if HAS_MAGIC:
        import magic
        try:
            mime_type = magic.from_file(str(file_path), mime=True)
            ext = _mime_to_extension(mime_type)
            if ext:
                return ext
        except Exception as e:
            print(e)
            pass

    # 使用 mimetypes 库
    try:
        mime_type, _ = mimetypes.guess_type(str(file_path))
        if mime_type:
            ext = _mime_to_extension(mime_type)
            if ext:
                return ext
    except Exception as e:
        print(e)
        pass

    # 第四层：文件头检测
    return _detect_by_header(file_path)


def _mime_to_extension(mime_type: str) -> str:
    """将MIME类型转换为文件扩展名"""
    # 常见MIME类型映射
    mime_map = {
        'text/plain': 'txt',
        'text/html': 'html',
        'text/css': 'css',
        'text/javascript': 'js',
        'application/json': 'json',
        'application/xml': 'xml',
        'application/pdf': 'pdf',
        'application/zip': 'zip',
        'application/x-tar': 'tar',
        'application/gzip': 'gz',
        'image/jpeg': 'jpg',
        'image/png': 'png',
        'image/gif': 'gif',
        'image/bmp': 'bmp',
        'image/svg+xml': 'svg',
        'audio/mpeg': 'mp3',
        'audio/wav': 'wav',
        'video/mp4': 'mp4',
        'video/avi': 'avi',
        'application/msword': 'doc',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
        'application/vnd.ms-excel': 'xls',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
    }

    return mime_map.get(mime_type, '')


def _detect_by_header(file_path: Path) -> str:
    """通过文件头检测文件类型"""
    try:
        with open(file_path, 'rb') as f:
            header = f.read(16)

        # 检测常见的文件签名
        if header.startswith(b'\x89PNG'):
            return 'png'
        elif header.startswith(b'\xff\xd8\xff'):
            return 'jpg'
        elif header.startswith(b'GIF8'):
            return 'gif'
        elif header.startswith(b'%PDF'):
            return 'pdf'
        elif header.startswith(b'PK\x03\x04'):
            return 'zip'
        elif header.startswith(b'\x1f\x8b'):
            return 'gz'
        elif header.startswith(b'BM'):
            return 'bmp'
        elif b'<html' in header.lower() or b'<!doctype html' in header.lower():
            return 'html'
        elif header.startswith(b'<?xml'):
            return 'xml'
        # 检测文本文件
        elif all(byte < 128 for byte in header if byte != 0):
            # 进一步检测是否为代码文件
            try:
                content = header.decode('utf-8', errors='ignore')
                if 'def ' in content or 'import ' in content:
                    return 'py'
                elif 'function' in content or 'var ' in content:
                    return 'js'
                elif '#include' in content or 'int main' in content:
                    return 'c'
                else:
                    return 'txt'
            except:
                return 'txt'
    except Exception:
        pass

    return ''
