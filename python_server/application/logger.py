import logging
import sys

from application.trace_id_filter import TraceIdFilter, get_trace_id, get_tool_use_id

logger = logging.getLogger(__name__)
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)


def set_log_level(level):
    r"""Set the logging level for super-doubao-runtime.

    Args:
        level (Union[str, int]): The logging level to set. This can be a string
            (e.g., 'INFO') or a logging level constant (e.g., logging.INFO,
            logging.DEBUG).
            See https://docs.python.org/3/library/logging.html#levels

    Raises:
        ValueError: If the provided level is not a valid logging level.
    """
    if isinstance(level, str):
        valid_levels = ['NOTSET', 'DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL']
        if level.upper() not in valid_levels:
            raise ValueError(
                f"Invalid logging level."
                f" Choose from: {', '.join(valid_levels)}"
            )
        level = level.upper()
    elif not isinstance(level, int):
        raise ValueError(
            "Logging level must be an option from the logging module."
        )

    class LoggerFormatter(logging.Formatter):
        def format(self, record):
            record.trace_id = get_trace_id()
            record.tool_use_id = get_tool_use_id()
            return super().format(record)

    console = logging.StreamHandler(sys.stdout)  # 定义console handler
    console.setLevel(logging.INFO)  # 定义该handler级别
    formatter = LoggerFormatter('%(asctime)s [%(trace_id)s] [tool_use_id=%(tool_use_id)s] %(filename)s : '
                                  '%(levelname)s %(message)s')  # 定义该handler格式
    console.setFormatter(formatter)
    # Create an instance
    logger.addHandler(console)
    logger.addFilter(TraceIdFilter())
    logger.propagate = False

    logger.setLevel(level)
    logger.info(f"Logging level set to: {logging.getLevelName(level)}")
