import base64
from application.logger import logger
from Crypto.Signature import pkcs1_15
from Crypto.Hash import SHA256
from Crypto.PublicKey import RSA


def verify_signature_with_base64_public_key(base64_public_key, message, signature):
    """
    使用Base64编码的公钥验证RSA签名

    :param base64_public_key: Base64编码的公钥
    :param message: 签名上下文
    :param signature: 待验证的签名 (Base64编码)
    :return: 验签结果 (True/False)
    """
    try:
        # 解码Base64公钥
        public_key_bytes = base64.b64decode(base64_public_key)
        public_key = RSA.import_key(public_key_bytes)
        signature_bytes = base64.b64decode(signature)
        h = SHA256.new(message.encode())
        
        # 验证签名
        pkcs1_15.new(public_key).verify(h, signature_bytes)
        return True
    except Exception as e:
        logger.warning(f"验签失败: {e}")
        return False