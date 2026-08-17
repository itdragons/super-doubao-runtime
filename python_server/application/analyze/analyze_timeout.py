import ast
from application.logger import logger
from enum import Enum

from typing import Dict, List, Set, Tuple, Optional, Any
from pydantic import BaseModel
import time
import asyncio


class StrEnum(str, Enum):
    """字符串枚举基类，成员值即为字符串本身"""
    pass


# 超时原因枚举
class TimeoutReason(StrEnum):
    wait_input = "wait_input"
    infinite_loop = "infinite_loop"


EXIT_NODE_TYPES = (ast.Break, ast.Return, ast.Raise)
YIELD_NODE_TYPES = (ast.Yield, ast.YieldFrom, ast.Await)


class CodeAnalyzeResult(BaseModel):
    error_type: str | None = None
    function: str | None = None
    lineno: int | None = None
    col_offset: int | None = None
    snippet: str | None = None
    desc: str | None = None

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


# ------------ 静态布尔求值（保守） ------------
def eval_static_bool(node: ast.AST, env: Dict[str, object]) -> Optional[bool]:
    if isinstance(node, ast.Constant):
        return bool(node.value)
    if isinstance(node, ast.Name):
        if node.id in env:
            return bool(env[node.id])
        return None
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
        val = eval_static_bool(node.operand, env)
        return None if val is None else (not val)
    if isinstance(node, ast.BoolOp):
        vals = [eval_static_bool(v, env) for v in node.values]
        if isinstance(node.op, ast.And):
            if all(v is True for v in vals):
                return True
            if any(v is False for v in vals):
                return False
            return None
        if isinstance(node.op, ast.Or):
            if any(v is True for v in vals):
                return True
            if all(v is False for v in vals):
                return False
            return None
    if isinstance(node, ast.Compare):
        if len(node.ops) == 1 and len(node.comparators) == 1:
            left_v = None
            right_v = None
            left = node.left
            right = node.comparators[0]
            if isinstance(left, ast.Constant):
                left_v = left.value
            elif isinstance(left, ast.Name) and left.id in env:
                left_v = env[left.id]
            if isinstance(right, ast.Constant):
                right_v = right.value
            elif isinstance(right, ast.Name) and right.id in env:
                right_v = env[right.id]
            if left_v is not None and right_v is not None:
                op = node.ops[0]
                try:
                    if isinstance(op, ast.Eq):
                        return left_v == right_v
                    if isinstance(op, ast.NotEq):
                        return left_v != right_v
                    if isinstance(op, ast.Lt):
                        return left_v < right_v
                    if isinstance(op, ast.LtE):
                        return left_v <= right_v
                    if isinstance(op, ast.Gt):
                        return left_v > right_v
                    if isinstance(op, ast.GtE):
                        return left_v >= right_v
                except Exception:
                    return None
    return None


# ------------ 是否有退出方式 ------------
def has_exit(while_node: ast.While) -> bool:
    for inner in ast.walk(while_node):
        if isinstance(inner, EXIT_NODE_TYPES):
            return True
        if isinstance(inner, YIELD_NODE_TYPES):
            return True
    return False


def add_parent_info(tree: ast.AST):
    for node in ast.walk(tree):
        for child in ast.iter_child_nodes(node):
            setattr(child, "parent", node)


def get_function_defs(tree: ast.AST) -> Dict[str, ast.FunctionDef]:
    return {n.name: n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}


# ----------------- get_method_defs: 类方法映射 key="Class.method"
def get_method_defs(tree: ast.AST) -> Dict[str, ast.FunctionDef]:
    method_map: Dict[str, ast.FunctionDef] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef):
            class_name = node.name
            for item in node.body:
                if isinstance(item, ast.FunctionDef):
                    key = f"{class_name}.{item.name}"
                    setattr(item, "class_name", class_name)
                    method_map[key] = item
    return method_map


# ------------ 支持 method（跳过 self 参数）
def extract_call_arg_env(call: ast.Call, func_def: ast.FunctionDef, is_method: bool = False) -> Dict[str, object]:
    env: Dict[str, object] = {}
    param_names = [p.arg for p in func_def.args.args]
    # 如果是实例方法，跳过第一个参数（通常是 self）
    if is_method and len(param_names) > 0:
        param_names = param_names[1:]
    for i, a in enumerate(call.args):
        if i < len(param_names) and isinstance(a, ast.Constant):
            env[param_names[i]] = a.value
    for kw in call.keywords:
        if isinstance(kw.value, ast.Constant) and kw.arg in param_names:
            env[kw.arg] = kw.value.value
    return env


def has_local_input_shadow(func_node: ast.FunctionDef) -> bool:
    for n in ast.walk(func_node):
        if isinstance(n, ast.FunctionDef) and n.name == "input":
            return True
        if isinstance(n, ast.Assign):
            for t in n.targets:
                if isinstance(t, ast.Name) and t.id == "input":
                    return True
        if isinstance(n, ast.arguments):
            for arg in n.args:
                if arg.arg == "input":
                    return True
    return False


# ------------ collect_definite_calls_and_while_and_input 扩展支持 Attribute 和 instances
def collect_definite_calls_and_while_and_input(
        stmts: List[ast.stmt],
        module_env: Dict[str, object],
        local_env: Dict[str, object],
        func_defs: Dict[str, ast.FunctionDef],
        method_defs: Dict[str, ast.FunctionDef],
        instances: Dict[str, str],
        current_class: Optional[str] = None,
) -> Tuple[List[Tuple[str, Dict[str, object]]], List[ast.While], List[ast.Call]]:
    """
    扩展后的收集函数：
      - 支持 ast.Attribute 调用的静态解析（若能解析到 Class.method 则加入 definite_calls）
      - 支持 self.method()（通过 current_class 参数解析）
      - instances: 模块级变量 -> 类名 映射，用于解析 a = A(); a.method()
    """
    definite_calls_list: List[Tuple[str, Dict[str, object]]] = []
    while_nodes: List[ast.While] = []
    definite_input_calls: List[ast.Call] = []

    def process(stmt_list: List[ast.stmt], lenv: Dict[str, object]):
        for s in stmt_list:
            # 遍历所有节点查找input()调用
            for node in ast.walk(s):
                if isinstance(node, ast.Call):
                    # input 检测
                    if isinstance(node.func, ast.Name) and node.func.id == "input":
                        definite_input_calls.append(node)
                        logger.info(f"Detected input call at line {node.lineno}")
                    if isinstance(node.func, ast.Attribute) and node.func.attr == "input":
                        definite_input_calls.append(node)
                        logger.info(f"Detected input attribute call at line {node.lineno}")

            # if isinstance(s, ast.Assign) and isinstance(s.value, ast.Call):
            #     call = s.value
            #     # 检测赋值语句中的 input() 调用
            #     if isinstance(call.func, ast.Name) and call.func.id == "input":
            #         logger.info(f"[INPUT_DETECT] Found input() in assignment at line {call.lineno}, col {call.col_offset}")
            #         definite_input_calls.append(call)
            #     if isinstance(call.func, ast.Attribute) and call.func.attr == "input":
            #         logger.info(f"[INPUT_DETECT] Found attribute input call in assignment at line {call.lineno}")
            #         definite_input_calls.append(call)

            if isinstance(s, ast.Assign):
                if len(s.targets) == 1 and isinstance(s.targets[0], ast.Name):
                    tgt = s.targets[0].id
                    val = s.value
                    # propagate simple constants
                    if isinstance(val, ast.Constant):
                        lenv[tgt] = val.value
                    # track instances: a = A()
                    if isinstance(val, ast.Call) and isinstance(val.func, ast.Name):
                        class_name = val.func.id
                        instances[tgt] = class_name
                    elif isinstance(val, ast.Name) and val.id in lenv:
                        lenv[tgt] = lenv[val.id]
                continue

            if isinstance(s, ast.Expr) and isinstance(s.value, ast.Call):
                call = s.value
                # input 检测
                if isinstance(call.func, ast.Name) and call.func.id == "input":
                    logger.info(f"[INPUT_DETECT] Found input() call at line {call.lineno}, col {call.col_offset}")
                    definite_input_calls.append(call)
                if isinstance(call.func, ast.Attribute) and call.func.attr == "input":
                    logger.info(
                        f"[INPUT_DETECT] Found attribute input call at line {call.lineno}, col {call.col_offset}")
                    definite_input_calls.append(call)

                # case1: simple function call foo()
                if isinstance(call.func, ast.Name):
                    func_name = call.func.id
                    arg_env: Dict[str, object] = {}
                    if func_name in func_defs:
                        arg_env = extract_call_arg_env(call, func_defs[func_name], is_method=False)
                    definite_calls_list.append((func_name, arg_env))
                    continue

                # case2: attribute call obj.method()
                if isinstance(call.func, ast.Attribute):
                    attr = call.func
                    # obj.method() where obj is a Name
                    if isinstance(attr.value, ast.Name):
                        obj_name = attr.value.id
                        method_name = attr.attr

                        # 2a: self.method() inside a class method -> map to current_class.method
                        if obj_name == "self" and current_class is not None:
                            key = f"{current_class}.{method_name}"
                            if key in method_defs:
                                method_def = method_defs[key]
                                arg_env = extract_call_arg_env(call, method_def, is_method=True)
                                definite_calls_list.append((key, arg_env))
                                continue

                        # 2b: instance var a.method() where 'a' is in instances mapping
                        if obj_name in instances:
                            class_name = instances[obj_name]
                            key = f"{class_name}.{method_name}"
                            if key in method_defs:
                                method_def = method_defs[key]
                                arg_env = extract_call_arg_env(call, method_def, is_method=True)
                                definite_calls_list.append((key, arg_env))
                                continue

                    # 其它 attribute 调用（无法解析） -> skip conservatively
                continue

            if isinstance(s, ast.If):
                cond_val = eval_static_bool(s.test, {**module_env, **lenv})
                if cond_val is True:
                    process(s.body, dict(lenv))
                elif cond_val is False:
                    process(s.orelse, dict(lenv))
                continue

            if isinstance(s, ast.While):
                cond_val = eval_static_bool(s.test, {**module_env, **lenv})
                if cond_val is True:
                    while_nodes.append(s)
                    process(s.body, dict(lenv))
                continue

            if isinstance(s, ast.Return):
                return
            continue

    process(stmts, dict(local_env))
    return definite_calls_list, while_nodes, definite_input_calls


# 定义异步方法
async def static_analyze_code_async(code: str) -> Optional[CodeAnalyzeResult]:
    return static_analyze_code(code)


def static_analyze_code(code: str) -> Optional[CodeAnalyzeResult]:
    logger.info(f"enter static_analyze_code.")

    try:
        tree = ast.parse(code)
        logger.info(f"[AST_DEBUG] Top-level nodes: {[type(n).__name__ for n in tree.body]}")
    except Exception as e:
        logger.error(f"Code parse error: {e}")
        return None

    add_parent_info(tree)
    module_env: Dict[str, object] = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0],
                                                                                  ast.Name) and isinstance(node.value,
                                                                                                           ast.Constant):
            module_env[node.targets[0].id] = node.value.value

    # ----------------- 构建 method_defs 与 instances 映射
    method_defs = get_method_defs(tree)  # class methods map key="Class.method"
    definite_calls_list: List[Tuple[str, Dict[str, object]]] = []
    while_nodes: List[ast.While] = []
    definite_input_calls: List[ast.Call] = []
    local_env: Dict[str, object] = {}
    instances: Dict[str, str] = {}
    # 初步扫描模块级简单实例化 a = A()
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.value, ast.Call) and isinstance(
                node.value.func, ast.Name):
            cls_name = node.value.func.id
            # 若 cls_name 在代码中定义为类，记录之
            if any(isinstance(n, ast.ClassDef) and n.name == cls_name for n in ast.walk(tree)):
                tgt = node.targets[0]
                if isinstance(tgt, ast.Name):
                    instances[tgt.id] = cls_name
                    logger.info(f"[INSTANCE_COLLECT] Collected instance: {tgt.id} -> {cls_name}")

    func_defs = get_function_defs(tree)
    logger.info(f"[FUNC_DEFS] Found functions: {list(func_defs.keys())}")
    initial_calls: List[Tuple[str, Dict[str, object]]] = []
    module_definite_input_calls: List[ast.Call] = []

    # 扫描模块体：对 __main__ 特殊处理：先收集 __main__ 块内的实例赋值，再收集该块内的调用
    for node in tree.body:
        # 顶层直接的调用/assign（保留你原来的逻辑）
        if ((isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)) or
                ((isinstance(node, ast.Assign)) and isinstance(node.value, ast.Call))):
            call = node.value
            if isinstance(call.func, ast.Name) and call.func.id == "input":
                module_definite_input_calls.append(call)
            if isinstance(call.func, ast.Attribute) and call.func.attr == "input":
                module_definite_input_calls.append(call)

            # 检测顶层赋值语句中的input调用，如：a = input()
            if isinstance(node, ast.Assign) and isinstance(node.value, ast.Call):
                call = node.value
                if isinstance(call.func, ast.Name) and call.func.id == "input":
                    module_definite_input_calls.append(call)
                if isinstance(call.func, ast.Attribute) and call.func.attr == "input":
                    module_definite_input_calls.append(call)

            if isinstance(call.func, ast.Name):
                fname = call.func.id
                argenv = {}
                if fname in func_defs:
                    argenv = extract_call_arg_env(call, func_defs[fname], is_method=False)
                initial_calls.append((fname, argenv))

            if isinstance(call.func, ast.Attribute):
                attr = call.func
                if isinstance(attr.value, ast.Name):
                    obj_name = attr.value.id
                    method_name = attr.attr
                    if obj_name in instances:
                        class_name = instances[obj_name]
                        key = f"{class_name}.{method_name}"
                        if key in method_defs:
                            argenv = extract_call_arg_env(call, method_defs[key], is_method=True)
                            initial_calls.append((key, argenv))
                    if isinstance(attr.value, ast.Name) and attr.value.id in [k.split(".")[0] for k in
                                                                              method_defs.keys()]:
                        class_name = attr.value.id
                        key = f"{class_name}.{method_name}"
                        if key in method_defs:
                            argenv = extract_call_arg_env(call, method_defs[key], is_method=True)
                            initial_calls.append((key, argenv))

        # 处理 if __name__ == "__main__"：先收集 __main__ 中的简单实例赋值，再收集调用
        if isinstance(node, ast.If):
            cond_val = eval_static_bool(node.test, {"__name__": "__main__"})
            if cond_val is True:
                # 1) 先收集 __main__ 块内的简单实例化 a = A()
                for sub in node.body:
                    if isinstance(sub, ast.Assign) and len(sub.targets) == 1 and isinstance(sub.value,
                                                                                            ast.Call) and isinstance(
                        sub.value.func, ast.Name):
                        cls_name = sub.value.func.id
                        if any(isinstance(n, ast.ClassDef) and n.name == cls_name for n in ast.walk(tree)):
                            tgt = sub.targets[0]
                            if isinstance(tgt, ast.Name):
                                instances[tgt.id] = cls_name
                                logger.info(
                                    f"[INSTANCE_COLLECT] main block. Collected instance: {tgt.id} -> {cls_name}")
                # 2) 再扫描 __main__ 块内的调用（与模块顶层扫描逻辑一致）
                for sub in node.body:
                    if isinstance(sub, ast.Expr) and isinstance(sub.value, ast.Call):
                        call = sub.value
                        if isinstance(call.func, ast.Name) and call.func.id == "input":
                            module_definite_input_calls.append(call)
                        if isinstance(call.func, ast.Attribute) and call.func.attr == "input":
                            module_definite_input_calls.append(call)

                        if isinstance(call.func, ast.Name):
                            fname = call.func.id
                            argenv = {}
                            if fname in func_defs:
                                argenv = extract_call_arg_env(call, func_defs[fname], is_method=False)
                            initial_calls.append((fname, argenv))
                        if isinstance(call.func, ast.Attribute):
                            attr = call.func
                            if isinstance(attr.value, ast.Name):
                                obj_name = attr.value.id
                                method_name = attr.attr
                                if obj_name in instances:
                                    class_name = instances[obj_name]
                                    key = f"{class_name}.{method_name}"
                                    if key in method_defs:
                                        argenv = extract_call_arg_env(call, method_defs[key], is_method=True)
                                        initial_calls.append((key, argenv))

                    if isinstance(sub, ast.Assign) and isinstance(sub.value, ast.Call):
                        call = sub.value
                        if isinstance(call.func, ast.Name) and call.func.id == "input":
                            module_definite_input_calls.append(call)
                        if isinstance(call.func, ast.Attribute) and call.func.attr == "input":
                            module_definite_input_calls.append(call)

                logger.info("[MAIN_BLOCK] Processing __main__ block...")
                # 新增：分析__main__块内的循环结构
                main_definite_calls, main_while_nodes, main_input_calls = collect_definite_calls_and_while_and_input(
                    node.body, module_env, local_env, func_defs, method_defs, instances
                )
                logger.info(
                    f"[MAIN_BLOCK] collect_definite_calls_and_while_and_input result main_definite_calls: {main_definite_calls}")
                logger.info(
                    f"[MAIN_BLOCK] collect_definite_calls_and_while_and_input result main_while_nodes: {main_while_nodes}")
                logger.info(
                    f"[MAIN_BLOCK] collect_definite_calls_and_while_and_input result main_input_calls: {main_input_calls}")
                definite_calls_list.extend(main_definite_calls)
                while_nodes.extend(main_while_nodes)
                definite_input_calls.extend(main_input_calls)

                # 将__main__块中检测到的函数调用添加到initial_calls中，用于BFS遍历
                for func_name, arg_env in main_definite_calls:
                    initial_calls.append((func_name, arg_env))
                    logger.info(f"[MAIN_PROCESS] Added main call {func_name} to initial_calls")

    logger.info(f"[INITIAL_CALLS] Initial calls collected: {initial_calls}")
    # BFS over reachable functions (支持 method key "Class.method")
    reachable: Set[Tuple[str, Tuple[Tuple[str, object], ...]]] = set()
    stack: List[Tuple[str, Dict[str, object]]] = list(initial_calls)

    while stack:
        fn, argenv = stack.pop()
        logger.info(f"[BFS_TRAVERSE] Processing function: {fn}, args: {argenv}")
        key = (fn, tuple(sorted(argenv.items())))
        if key in reachable:
            continue
        reachable.add(key)

        # determine whether fn is method key or function name
        if "." in fn:
            # method key
            if fn not in method_defs:
                continue
            fnode = method_defs[fn]
            current_class = getattr(fnode, "class_name", None)
        else:
            if fn not in func_defs:
                continue
            fnode = func_defs[fn]
            current_class = None

        # prepare local env with param propagation (note: extract_call_arg_env used earlier)
        local_env: Dict[str, object] = {}
        for pname in [p.arg for p in fnode.args.args]:
            if pname in argenv:
                local_env[pname] = argenv[pname]

        # collect definite calls/whiles/inputs, pass method_defs and instances and current_class
        func_calls, func_whiles, func_inputs = collect_definite_calls_and_while_and_input(
            fnode.body, module_env, local_env, func_defs, method_defs, instances, current_class
        )
        logger.info(
            f"[BFS_FUNC_BLOCK] collect_definite_calls_and_while_and_input result func_definite_calls: {func_calls}")
        logger.info(
            f"[BFS_FUNC_BLOCK] collect_definite_calls_and_while_and_input result func_while_nodes: {func_whiles}")
        logger.info(
            f"[BFS_FUNC_BLOCK] collect_definite_calls_and_while_and_input result func_input_calls: {func_inputs}")
        # 合并到全局列表
        definite_calls_list.extend(func_calls)
        while_nodes.extend(func_whiles)
        definite_input_calls.extend(func_inputs)

        for called_name, called_argenv in definite_calls_list:
            # called_name could be "Class.method" or "func"
            stack.append((called_name, called_argenv))

    logger.info(
        f"[ANALYSIS_SUMMARY] Detected input calls: {len(definite_input_calls) + len(module_definite_input_calls)}")
    logger.info(f"[ANALYSIS_SUMMARY] Reachable functions processed: {len(reachable)}")

    # inspect reachable functions for issues (处理 reachable key 可能包含 method keys)
    for fn_key in list(reachable):
        fn_name = fn_key[0]
        frozen_argenv = dict(fn_key[1])
        # select fnode from method_defs or func_defs
        if "." in fn_name:
            if fn_name not in method_defs:
                continue
            fnode = method_defs[fn_name]
            current_class = getattr(fnode, "class_name", None)
        else:
            if fn_name not in func_defs:
                continue
            fnode = func_defs[fn_name]
            current_class = None

        local_env: Dict[str, object] = {}
        for pname in [p.arg for p in fnode.args.args]:
            if pname in frozen_argenv:
                local_env[pname] = frozen_argenv[pname]

        func_calls, func_whiles, func_inputs = collect_definite_calls_and_while_and_input(
            fnode.body, module_env, local_env, func_defs, method_defs, instances, current_class
        )
        logger.info(
            f"[reachable FUNC_BLOCK] collect_definite_calls_and_while_and_input result func_definite_calls: {func_calls}")
        logger.info(
            f"[reachable FUNC_BLOCK] collect_definite_calls_and_while_and_input result func_while_nodes: {func_whiles}")
        logger.info(
            f"[reachable FUNC_BLOCK] collect_definite_calls_and_while_and_input result func_input_calls: {func_inputs}")
        # 合并到全局列表
        definite_calls_list.extend(func_calls)
        while_nodes.extend(func_whiles)
        definite_input_calls.extend(func_inputs)

        logger.info(f"Function {fn_name} input calls: {len(definite_input_calls)}")
        shadow_local = has_local_input_shadow(fnode)
        for call_node in definite_input_calls:
            if not shadow_local:
                snippet = ast.get_source_segment(code, call_node)
                logger.info("end static_analyze_code. Detected input call.")
                return CodeAnalyzeResult(
                    error_type=TimeoutReason.wait_input,
                    function=fn_name,
                    lineno=getattr(call_node, "lineno", None),
                    col_offset=getattr(call_node, "col_offset", None),
                    snippet=snippet,
                )

        for wn in while_nodes:
            if isinstance(wn.test, ast.Constant) and wn.test.value is True:
                if not has_exit(wn):
                    snippet = ast.get_source_segment(code, wn)
                    logger.info("end static_analyze_code. Detected infinite while True loop without exit conditions.")
                    return CodeAnalyzeResult(
                        error_type=TimeoutReason.infinite_loop,
                        function=fn_name,
                        lineno=getattr(wn, "lineno", None),
                        col_offset=getattr(wn, "col_offset", None),
                        snippet=snippet,
                    )

    # 新增：全局死循环检查（放在所有函数处理完成后）
    for wn in while_nodes:
        # 检查无条件True循环
        if isinstance(wn.test, ast.Constant) and wn.test.value is True:
            if not has_exit(wn):
                snippet = ast.get_source_segment(code, wn)
                logger.info("end static_analyze_code. Detected infinite while True loop without exit conditions.")
                return CodeAnalyzeResult(
                    error_type=TimeoutReason.infinite_loop,
                    function="<module>",  # 模块级循环无函数名
                    lineno=wn.lineno,
                    col_offset=wn.col_offset,
                    snippet=snippet
                )

    # module-level input
    module_shadowed = False
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            logger.info(f"[MODULE_ASSIGN] Found assignment: {ast.unparse(node)}")
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == "input":
                    module_shadowed = True
        if isinstance(node, ast.FunctionDef) and node.name == "input":
            module_shadowed = True
    if not module_shadowed:
        all_input_calls = module_definite_input_calls + definite_input_calls
        for call in all_input_calls:
            snippet = ast.get_source_segment(code, call)
            logger.info("end static_analyze_code. Detected input call.")
            return CodeAnalyzeResult(
                error_type=TimeoutReason.wait_input,
                function="<module>",
                lineno=getattr(call, "lineno", None),
                col_offset=getattr(call, "col_offset", None),
                snippet=snippet,
            )

    # module-level while True
    for node in tree.body:
        if isinstance(node, ast.While):
            if isinstance(node.test, ast.Constant) and node.test.value is True:
                if not has_exit(node):
                    snippet = ast.get_source_segment(code, node)
                    logger.info("end static_analyze_code. Detected infinite while True loop without exit conditions.")
                    return CodeAnalyzeResult(
                        error_type=TimeoutReason.infinite_loop,
                        function="<module>",
                        lineno=getattr(node, "lineno", None),
                        col_offset=getattr(node, "col_offset", None),
                        snippet=snippet,
                    )

    logger.info("end static_analyze_code. No timeout reason detected.")
    return None
