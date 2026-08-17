import sys
import os
# 将项目根目录添加到 Python 路径
sys.path.append(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from analyze_timeout import *

import time

# ------------ 测试 ------------
if __name__ == "__main__":
#     test_code_with_main = """
# if __name__ == "__main__":
#     a=input()
# """
#     res = static_analyze_code(test_code_with_main)
#
#
#     print(f"[test_code_with_main] code={test_code_with_main} Result: {res}")
#     print("=" * 50)

    test_code_without_main = """
a=float(input())
"""
    res = static_analyze_code(test_code_without_main)
    print(f"[test_code_without_main] code={test_code_without_main} Result: {res}")

