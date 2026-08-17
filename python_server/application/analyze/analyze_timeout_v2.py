from dataclasses import dataclass
from typing import Dict, Set, Optional, cast
import ast
from pydantic import BaseModel

from enum import Enum
class StrEnum(str, Enum):
    """字符串枚举基类，成员值即为字符串本身"""
    pass


# 超时原因枚举
class TimeoutReason(StrEnum):
    wait_input = "wait_input"
    infinite_loop = "infinite_loop"

class CodeAnalyzeResult(BaseModel):
    error_type: str = ""
    function: str = ""
    lineno: int = 0
    col_offset: int = 0
    snippet: str = ""

    def desc_for_user(self) -> str:

        """生成用户友好的分析结果描述"""

        parts = []
        if self.error_type:
            parts.append(f"error_type: {self.error_type}")
        if self.lineno:
            parts.append(f"lineno: {self.lineno}")
        if self.col_offset:
            parts.append(f"col_offset: {self.col_offset}")
        if self.snippet:
            parts.append(f"code_snippet: {self.snippet}")

        if parts:
            return "; ".join(parts)

        return ""


@dataclass
class ScopeInfo:
    """
    一个可分析的逻辑执行单元
    """
    name: str                 # "<module>" / "func" / "Class.method"
    node: ast.AST             # 对应的 AST node
    calls: Set[str]           # 该 scope 内调用到的其他 scope 名称

@dataclass
class ScopeGraph:
    """
    全量 scope 图
    """
    scopes: Dict[str, ScopeInfo]

    # 用户自定义方法
    defined_names: set[str]


def parse_code_to_ast(code: str) -> ast.Module:
    return ast.parse(code)

def build_scope_graph(tree: ast.Module) -> ScopeGraph:
    scopes: Dict[str, ScopeInfo] = {}
    defined_names: set[str] = set()

    # module scope
    scopes["<module>"] = ScopeInfo(
        name="<module>",
        node=tree,
        calls=set(),
    )

    for node in tree.body:
        if isinstance(node, ast.FunctionDef):
            scopes[node.name] = ScopeInfo(
                name=node.name,
                node=node,
                calls=set(),
            )
            defined_names.add(node.name)

        elif isinstance(node, ast.ClassDef):
            defined_names.add(node.name)
            for item in node.body:
                if isinstance(item, ast.FunctionDef):
                    scope_name = f"{node.name}.{item.name}"
                    scopes[scope_name] = ScopeInfo(
                        name=scope_name,
                        node=item,
                        calls=set(),
                    )
                    defined_names.add(item.name)

        elif isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    defined_names.add(target.id)

    for scope in scopes.values():
        scope.calls = collect_calls_in_scope(scope.node)

    return ScopeGraph(scopes=scopes, defined_names=defined_names)


def extract_call_name(call: ast.Call) -> Optional[str]:
    """
    R3 策略：
    - f()           -> "f"
    - a.f()         -> "f"
    - A.f()         -> "f"
    """
    if isinstance(call.func, ast.Name):
        return call.func.id

    if isinstance(call.func, ast.Attribute):
        return call.func.attr

    return None


def collect_calls_in_scope(node: ast.AST) -> Set[str]:
    calls: Set[str] = set()

    for child in ast.walk(node):
        if isinstance(child, ast.Call):
            name = extract_call_name(child)
            if name:
                calls.add(name)

    return calls


def compute_reachable_scopes(graph: ScopeGraph) -> Set[str]:
    reachable: Set[str] = set()
    visited: Set[str] = set()

    def dfs(scope_name: str):
        if scope_name in visited:
            return
        visited.add(scope_name)
        reachable.add(scope_name)

        scope = graph.scopes.get(scope_name)
        if not scope:
            return

        for callee in scope.calls:
            if callee in graph.scopes:
                dfs(callee)
            else:
                # 尝试匹配类方法
                for sname in graph.scopes:
                    if sname.endswith("." + callee):
                        dfs(sname)

    dfs("<module>")
    return reachable


def extract_snippet(code: str, node: ast.AST) -> str:
    try:
        return ast.get_source_segment(code, node) or ""
    except Exception:
        return ""


def build_result(
    error_type: str,
    scope_name: str,
    node: ast.AST,
    code: str,
) -> CodeAnalyzeResult:

    return CodeAnalyzeResult(
        error_type=error_type,
        function=scope_name,
        lineno=node.lineno,
        col_offset=node.col_offset,
        snippet=extract_snippet(code, node),
    )



def is_blocking_input(
    node: ast.AST,
    graph: ScopeGraph,
) -> bool:
    if not isinstance(node, ast.Call):
        return False

    if isinstance(node.func, ast.Name) and node.func.id == "input":
        # 如果 input 被用户定义过，就不是 builtin input
        if "input" not in graph.defined_names:
            return True

    return False


EXIT_NODE_TYPES = (ast.Break, ast.Return, ast.Raise)
YIELD_NODE_TYPES = (ast.Yield, ast.YieldFrom, ast.Await)


def has_exit(while_node: ast.While) -> bool:
    for stmt in while_node.body:
        node = cast(ast.AST, stmt)
        for inner in ast.walk(node):
            if isinstance(inner, EXIT_NODE_TYPES):
                return True
            if isinstance(inner, YIELD_NODE_TYPES):
                return True
    return False


def is_definitely_infinite_loop(node: ast.AST) -> bool:
    if not isinstance(node, ast.While):
        return False

    if isinstance(node.test, ast.Constant) and node.test.value is True:
        if not has_exit(node):
            return True

    return False


def detect_timeout_in_module(
    module_node: ast.Module,
    scope_name: str,
    code: str,
    graph: ScopeGraph,
) -> Optional[CodeAnalyzeResult]:
    # 只遍历顶层可执行语句
    for stmt in module_node.body:
        if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            continue  # 跳过定义

        # stmt 是可执行语句，遍历 AST
        for child in ast.walk(stmt):
            if is_blocking_input(child, graph):
                return build_result(TimeoutReason.wait_input, scope_name, child, code)
            if is_definitely_infinite_loop(child):
                return build_result(TimeoutReason.infinite_loop, scope_name, child, code)

    return None

def detect_timeout_in_node(
    node: ast.AST,
    scope_name: str,
    code: str,
    graph: ScopeGraph,
) -> Optional[CodeAnalyzeResult]:

    for child in ast.walk(node):

        # input()
        if is_blocking_input(child, graph):
            return build_result(
                TimeoutReason.wait_input, scope_name, child, code
            )

        # while True
        if is_definitely_infinite_loop(child):
            return build_result(
                TimeoutReason.infinite_loop, scope_name, child, code
            )

    return None


def detect_timeout_patterns(
    graph: ScopeGraph,
    reachable_scopes: Set[str],
    code: str,
) -> Optional[CodeAnalyzeResult]:

    for scope_name in reachable_scopes:
        scope = graph.scopes[scope_name]

        # 模块级特殊处理
        if scope_name == "<module>":
            result = detect_timeout_in_module(
                module_node=cast(ast.Module, scope.node),
                scope_name=scope_name,
                code=code,
                graph=graph
            )
        else:
            # 可达函数 / 方法
            result = detect_timeout_in_node(
                node=scope.node,
                scope_name=scope_name,
                code=code,
                graph=graph
            )

        if result:
            return result

    return CodeAnalyzeResult()


def static_analyze_code(code: str) -> Optional[CodeAnalyzeResult]:
    tree = parse_code_to_ast(code)
    graph = build_scope_graph(tree)
    reachable = compute_reachable_scopes(graph)
    print(f"graph={graph}")
    print(f"reachable={reachable}")
    return detect_timeout_patterns(graph, reachable, code)

# 定义异步方法
async def static_analyze_code_async(code: str) -> Optional[CodeAnalyzeResult]:
    return static_analyze_code(code)