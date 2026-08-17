from enum import IntEnum

class ErrorCode(IntEnum):
    """错误码枚举"""
    SUCCESS = 0, "成功"
    TIMEOUT = 41100, "code execute timeout"
    ANALYZE_TIMEOUT = 41101, "code will execute timeout"
    UNKNOWN_ERROR = 41200, "unknown error"
    CANCEL_ERROR = 41201, "code execute canceled"


    def __new__(cls, value, description):
        obj = int.__new__(cls, value)
        obj._value_ = value
        obj.description = description
        return obj

