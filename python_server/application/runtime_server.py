import os
from pydantic import BaseModel
from fastapi import APIRouter
from application.logger import logger
import subprocess
import json
import re


runtime_server_router = APIRouter()

class GetSandboxRuntimeRequest(BaseModel):
    pass

class SandboxSystem(BaseModel):
    os: str = ""
    os_version: str = ""
    # arch: str = ""
    detail: str = ""

class SandboxPython(BaseModel):
    version: str = ""
    path: str = ""
    libs: dict[str, str] = {}

class SandboxRuntime(BaseModel):
    system : SandboxSystem | None = None
    python : SandboxPython | None = None
   
class GetSandboxRuntimeResponse(BaseModel):
    success: bool = True
    message: str = ""
    detail: SandboxRuntime | None = None
 

@runtime_server_router.get("/v1/sandbox")
async def getSandboxRuntime():
    resp = GetSandboxRuntimeResponse()
    
    try:
        # 获取系统信息
        system_info = SandboxSystem()
        
        # 获取操作系统信息
        os_release = exec_shell("cat /etc/os-release")
        if os_release:
            system_info.detail = os_release
            # 解析 os-release 文件
            for line in os_release.split('\n'):
                if line.startswith('NAME='):
                    system_info.os = line.split('=')[1].strip('"')
                elif line.startswith('VERSION='):
                    system_info.os_version = line.split('=')[1].strip('"')
        
        # 获取架构信息
        # arch = exec_shell("uname -m").strip()
        # system_info.arch = arch
        
        # 获取Python信息
        python_info = SandboxPython()
        # 获取Python路径
        python_path = exec_shell("which python3").strip()
        python_info.path = python_path
        
        # 获取Python版本
        python_version = exec_shell("python3 --version").strip()
        if python_version.startswith('Python '):
            python_info.version = python_version.replace('Python ', '')
        
        # 获取已安装的Python包
        pip_list = exec_shell("pip3 list --format=json")
        print("pip_list=" + pip_list)
        if pip_list:
            try:
                packages = json.loads(pip_list)
                python_info.libs = {pkg['name']: pkg['version'] for pkg in packages}
            except json.JSONDecodeError:
                # 如果JSON解析失败，尝试解析普通格式
                pip_list_plain = exec_shell("pip3 list")
                libs = {}
                for line in pip_list_plain.split('\n')[2:]:  # 跳过头部
                    if line.strip():
                        parts = line.split()
                        if len(parts) >= 2:
                            libs[parts[0]] = parts[1]
                python_info.libs = libs
        
        # 构建响应
        runtime = SandboxRuntime(
            system=system_info,
            python=python_info
        )
        
        resp.detail = runtime
        resp.message = "Successfully retrieved sandbox runtime information"
        
    except Exception as e:
        logger.error(f"Error getting sandbox runtime info: {str(e)}")
        resp.success = False
        resp.message = f"Failed to retrieve sandbox runtime information: {str(e)}"
    
    return resp


def exec_shell(cmd: str):
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.stderr:
        logger.error(f"Command= {cmd}. Stderr= {result.stderr}")
    return result.stdout