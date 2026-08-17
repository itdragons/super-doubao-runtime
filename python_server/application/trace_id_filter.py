import contextvars
import logging

trace_id_var = contextvars.ContextVar("trace_id", default="unknown")
tool_use_id_var = contextvars.ContextVar("tool_use_id", default="unknown")

def set_trace_id(trace_id: str):
    trace_id_var.set(trace_id)

def get_trace_id() -> str:
    return trace_id_var.get()

def set_tool_use_id(tool_use_id: str):
    tool_use_id_var.set(tool_use_id)

def get_tool_use_id() -> str:
    return tool_use_id_var.get()


class TraceIdFilter(logging.Filter):
    def filter(self, record):
        record.tool_use_id = get_tool_use_id()
        record.trace_id = get_trace_id()
        return True
# __all__ = ["TraceIdFilter", "set_trace_id", "get_trace_id", "set_tool_use_id", "get_tool_use_id"]
