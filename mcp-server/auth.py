from fastapi import Header, HTTPException, Depends
import os
from typing import Optional, Callable


def _load_keys() -> dict:
    """Parse `MCP_API_KEYS` env var as comma-separated `key:role` pairs.

    Example: MCP_API_KEYS="adminkey:admin,userkey:reader"
    """
    raw = os.getenv("MCP_API_KEYS", "")
    mapping = {}
    for part in [p.strip() for p in raw.split(",") if p.strip()]:
        if ":" in part:
            k, r = part.split(":", 1)
            mapping[k] = r
    # fallback single-key env var
    if not mapping and os.getenv("MCP_API_KEY"):
        mapping[os.getenv("MCP_API_KEY")] = os.getenv("MCP_API_ROLE", "admin")
    return mapping


def get_role_for_key(x_api_key: Optional[str]) -> Optional[str]:
    if not x_api_key:
        return None
    keys = _load_keys()
    return keys.get(x_api_key)


def require_role(required: str) -> Callable:
    def _dep(x_api_key: Optional[str] = Header(None)):
        if os.getenv("MCP_REQUIRE_AUTH") != "1":
            return True
        role = get_role_for_key(x_api_key)
        if role is None:
            raise HTTPException(status_code=401, detail="Invalid API key")
        # simple role hierarchy: admin > reader
        if required == "reader" and role in ("reader", "admin"):
            return True
        if required == "admin" and role == "admin":
            return True
        raise HTTPException(status_code=403, detail="insufficient role")

    return _dep

