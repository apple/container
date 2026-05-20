from fastapi import Header, HTTPException
import os


def verify_api_key(x_api_key: str = Header(None)):
    expected = os.getenv("MCP_API_KEY", "dev-key")
    if x_api_key != expected:
        raise HTTPException(status_code=401, detail="Invalid API key")
